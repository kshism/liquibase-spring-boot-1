#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use Time::HiRes qw(time);
use IO::Handle;
use bytes;
use POSIX qw(strftime);

# Fixed extractor with split; avoids creating an empty trailing chunk
# Usage example:
#   perl p5.pl --key accounts --in large_10k.json --split-lines 100 --ndjson --split-prefix /tmp/10k_

my $infile;
my $outfile;
my $key = 'accounts';
my $ndjson = 0;
my $buffer = 4 * 1024 * 1024; # 4 MB
my $verbose = 0;

# split options
my $split_lines = 0;
my $split_prefix = undef;

GetOptions(
    "in=s"          => \$infile,
    "out=s"         => \$outfile,
    "key=s"         => \$key,
    "ndjson!"       => \$ndjson,
    "buffer=i"      => \$buffer,
    "verbose!"      => \$verbose,
    "split-lines=i" => \$split_lines,
    "split-prefix=s"=> \$split_prefix,
) or die "Bad options\n";

# validate inputs:
die "Specify --in\n" unless defined $infile;
if ($split_lines) {
    die "--split-prefix is required when --split-lines is used\n" unless defined $split_prefix;
    if (defined $outfile && $outfile eq '-') {
        die "Cannot split output to stdout ('--out -'); provide a split-prefix and allow script to create files.\n";
    }
} else {
    die "Specify --out\n" unless defined $outfile;
}

# normalize key: empty string => treat as top-level array
$key = undef if defined $key && $key eq '';

# open input
my $IN;
if ($infile eq '-') {
    binmode(STDIN);
    $IN = *STDIN;
} else {
    open $IN, '<:raw', $infile or die "open $infile: $!";
}

# If not splitting, open the single output file/handle
my $OUT;
if (!$split_lines) {
    if ($outfile eq '-') {
        binmode(STDOUT);
        $OUT = *STDOUT;
    } else {
        open $OUT, '>:raw', $outfile or die "open $outfile: $!";
        $OUT->autoflush(0);
    }
}

# helpers
sub now { return time() }
sub commify { local $_ = shift; 1 while s/^(-?\d+)(\d{3})/$1,$2/; $_ }

# -------------------------
# low-level string extractor
# -------------------------
sub extract_string {
    my ($s, $pos) = @_;
    my $len = length($s);
    return (undef, -1) if $pos >= $len || substr($s, $pos, 1) ne '"';
    my $i = $pos + 1;
    my $esc = 0;
    while ($i < $len) {
        my $c = substr($s, $i, 1);
        if ($esc) { $esc = 0; }
        else {
            if ($c eq '\\') { $esc = 1; }
            elsif ($c eq '"') {
                my $token = substr($s, $pos+1, $i - ($pos+1));
                return ($token, $i+1);
            }
        }
        $i++;
    }
    return (undef, -1);
}

# -------------------------
# find the accounts array
# -------------------------
sub find_key_array {
    my ($s, $key) = @_;
    my $i = 0;
    my $len = length($s);
    while ($i < $len) {
        my $c = substr($s, $i, 1);
        if ($c eq '"') {
            my ($token, $next) = extract_string($s, $i);
            if ($next == -1) { return (0, substr($s, $i)); }
            if (defined $key && $token eq $key) {
                my $j = $next;
                while ($j < $len && substr($s, $j, 1) =~ /\s/) { $j++ }
                return (0, substr($s, $i)) if $j >= $len;
                return (0, substr($s, $i)) if substr($s, $j, 1) ne ':';
                $j++;
                while ($j < $len && substr($s, $j, 1) =~ /\s/) { $j++ }
                if ($j < $len && substr($s, $j, 1) eq '[') {
                    return (1, substr($s, $j+1));
                } else {
                    return (0, substr($s, $i));
                }
            }
            $i = $next;
            next;
        } else { $i++ }
    }
    my $keep = (defined $key ? length($key) * 4 + 32 : 64);
    if ($len > $keep) { return (0, substr($s, -$keep)); }
    else { return (0, $s); }
}

sub find_top_array {
    my ($s) = @_;
    my $i = 0;
    my $len = length($s);
    while ($i < $len) {
        my $c = substr($s, $i, 1);
        if ($c eq '"') {
            my ($tok, $next) = extract_string($s, $i);
            return (0, substr($s, $i)) if $next == -1;
            $i = $next;
            next;
        } elsif ($c =~ /\s/) { $i++; next; }
        elsif ($c eq '[') { return (1, substr($s, $i+1)); }
        else { last; }
    }
    my $keep = 64;
    my $len_keep = length($s);
    if ($len_keep > $keep) { return (0, substr($s, -$keep)); }
    else { return (0, $s); }
}

# -------------------------
# element-extraction streamer (robust)
# -------------------------
sub stream_array_elements {
    my ($fh_in, $first_chunk, $callback) = @_;

    my $buf = defined $first_chunk ? $first_chunk : '';
    my $pos = 0;

    my $element_start;
    my $in_string = 0;
    my $esc = 0;
    my $depth = 0;

    my $refill = sub {
        if (defined $element_start) {
            my $tail = substr($buf, $element_start);
            $buf = $tail;
            $pos = length($buf);
            $element_start = 0;
        } else {
            $buf = '';
            $pos = 0;
        }
        my $r = sysread($fh_in, my $chunk, $buffer);
        die "sysread failed: $!" unless defined $r;
        return 0 if $r == 0;
        $buf .= $chunk;
        return length($chunk);
    };

    my $ensure_data = sub {
        if ($pos >= length($buf)) {
            my $got = $refill->();
            return 0 unless $got;
        }
        return 1;
    };

    while (1) {
        last unless $ensure_data->();
        my $c = substr($buf, $pos, 1);

        if (!defined $element_start) {
            if ($c =~ /\s/ || $c eq ',') { $pos++; next; }
            if ($c eq ']') {
                my $remain = ($pos + 1 <= length($buf)) ? substr($buf, $pos+1) : '';
                return $remain;
            }
            $element_start = $pos;
            $in_string = 0; $esc = 0; $depth = 0;
            if ($c eq '{' || $c eq '[') { $depth = 1; $pos++; next; }
            if ($c eq '"') { $in_string = 1; $pos++; next; }
            $pos++; next;
        }

        if ($in_string) {
            die "EOF while inside string of element starting at $element_start\n" unless $ensure_data->();
            my $ch = substr($buf, $pos, 1);
            if ($esc) { $esc = 0; $pos++; next; }
            if ($ch eq '\\') { $esc = 1; $pos++; next; }
            if ($ch eq '"') {
                $in_string = 0; $pos++;
                if ($depth == 0) {
                    my $elem_end = $pos;
                    if (defined $element_start && $elem_end <= length($buf)) {
                        my $elem = substr($buf, $element_start, $elem_end - $element_start);
                        $callback->($elem) if defined $elem;
                    }
                    $element_start = undef;
                }
                next;
            }
            $pos++; next;
        } elsif ($depth > 0) {
            die "EOF while inside nested structure of element starting at $element_start\n" unless $ensure_data->();
            my $ch = substr($buf, $pos, 1);
            if ($ch eq '"') { $in_string = 1; $esc = 0; $pos++; next; }
            if ($ch eq '{' || $ch eq '[') { $depth++; $pos++; next; }
            if ($ch eq '}' || $ch eq ']') {
                $depth--; $pos++;
                if ($depth == 0) {
                    my $elem_end = $pos;
                    if (defined $element_start && $elem_end <= length($buf)) {
                        my $elem = substr($buf, $element_start, $elem_end - $element_start);
                        $callback->($elem) if defined $elem;
                    }
                    $element_start = undef;
                }
                next;
            }
            $pos++; next;
        } else {
            unless ($ensure_data->()) {
                if (defined $element_start && $pos > $element_start) {
                    my $elem = substr($buf, $element_start, $pos - $element_start);
                    $elem =~ s/\s+$//s if defined $elem;
                    $callback->($elem) if defined $elem && length($elem) > 0;
                    $element_start = undef;
                } else {
                    die "EOF while reading primitive element\n";
                }
                last;
            }
            my $ch = substr($buf, $pos, 1);
            if ($ch eq ',' || $ch eq ']') {
                my $elem_end = $pos;
                if (defined $element_start && $elem_end <= length($buf)) {
                    my $elem = $elem_end > $element_start ? substr($buf, $element_start, $elem_end - $element_start) : '';
                    $elem =~ s/\s+$//s if defined $elem;
                    $callback->($elem) if defined $elem && length($elem) > 0;
                }
                $element_start = undef;
                next;
            } else {
                $pos++; next;
            }
        }
    }

    if (defined $element_start) {
        die "EOF while reading array element\n";
    }
    return '';
}

# -------------------------
# chunk helpers
# -------------------------
sub pad_index { return sprintf("%05d", shift) }

sub open_chunk_handle {
    my ($prefix, $index, $is_ndjson) = @_;
    my $suffix_ext = $is_ndjson ? ".ndjson" : ".json";
    my $fname = $prefix . "_" . pad_index($index) . $suffix_ext;
    open my $fh, '>:raw', $fname or die "open chunk file $fname: $!";
    $fh->autoflush(0);
    return ($fh, $fname);
}

# -------------------------
# MAIN: locate array start
# -------------------------
my $partial = '';
my $bytes_read = 0;
my $t0 = now();
my $last_report = $t0;

my $found = 0;
my $array_initial_tail = '';

while (1) {
    my $r = sysread($IN, my $chunk, $buffer);
    die "sysread failed: $!" unless defined $r;
    $bytes_read += $r if $r;
    my $chunk_to_process;
    if ($r == 0) {
        $chunk_to_process = $partial;
        $partial = '';
        die "Reached EOF but did not find target array (key='$key')\n" unless $found;
        last;
    } else {
        $chunk_to_process = ($partial || '') . $chunk;
        $partial = '';
    }

    if (!$found) {
        if (defined $key) {
            my ($status, $tail) = find_key_array($chunk_to_process, $key);
            if ($status == 1) { $found = 1; $array_initial_tail = $tail // ''; last; }
            $partial = $tail;
        } else {
            my ($status, $tail) = find_top_array($chunk_to_process);
            if ($status == 1) { $found = 1; $array_initial_tail = $tail // ''; last; }
            $partial = $tail;
        }
    } else { last }

    if ($verbose) {
        my $now = now();
        if ($now - $last_report >= 1.0) {
            warn sprintf("scanned %s bytes so far\n", commify($bytes_read));
            $last_report = $now;
        }
    }
}

die "Target array not found\n" unless $found;

# -------------------------
# output chunking state (LAZY creation)
# -------------------------
my $chunk_index = 1;
my $records_in_chunk = 0;
my $current_fh;      # undef until first write in a chunk
my $current_fname;
my $current_chunk_created = 0; # track whether file was actually created (for cleanup)

sub start_new_chunk_if_needed {
    my ($start_idx) = @_;
    return if defined $current_fh; # already open
    if ($split_lines) {
        my ($fh, $fname) = open_chunk_handle($split_prefix, $start_idx, $ndjson);
        $current_fh = $fh;
        $current_fname = $fname;
        $records_in_chunk = 0;
        $current_chunk_created = 1;
        if (!$ndjson) { syswrite($current_fh, '[') or die "write failed: $!"; }
    } else {
        $current_fh = $OUT;
        $current_fname = $outfile;
        $records_in_chunk = 0;
        # for single-file raw mode, ensure opening '[' written once
        if (!$ndjson && !$current_chunk_created) {
            syswrite($current_fh, '[') or die "write failed: $!";
            $current_chunk_created = 1;
        }
    }
}

sub close_current_chunk {
    return unless defined $current_fh;
    # if raw-array, write closing bracket only if any element was written OR if we intend to produce an empty array
    if (!$ndjson) {
        syswrite($current_fh, ']') or die "write failed: $!";
    }
    if ($split_lines) {
        close $current_fh;
        # if chunk file was created but had zero records, remove it
        if ($current_chunk_created && $records_in_chunk == 0) {
            unlink $current_fname;
        }
    } else {
        # single output: keep open until end; but if we wrote nothing and it's raw-array, we still keep file with empty array '[]'
        # do not close here; closing done at end
    }
    $current_fh = undef;
    $current_fname = undef;
    $current_chunk_created = 0;
}

# No eager start; chunk will be opened lazily on first write
my $processed = 0;
my $start_time = time();
my $last_progress_time = $start_time;

my $write_element = sub {
    my ($elem) = @_;
    return unless defined $elem;

    # ensure chunk exists
    start_new_chunk_if_needed($chunk_index);

    if ($ndjson) {
        syswrite($current_fh, $elem . "\n") or die "write failed: $!";
        $records_in_chunk++;
        $processed++;
    } else {
        if ($records_in_chunk == 0) {
            syswrite($current_fh, $elem) or die "write failed: $!";
        } else {
            syswrite($current_fh, ',' . $elem) or die "write failed: $!";
        }
        $records_in_chunk++;
        $processed++;
    }

    # if chunk reached limit, close it but DO NOT eagerly open next chunk
    if ($split_lines && $split_lines > 0 && $records_in_chunk >= $split_lines) {
        close_current_chunk();
        $chunk_index++;
        $records_in_chunk = 0;
        # current_fh is undef now; next write will lazily open the next chunk
    }

    if ($verbose) {
        my $now = time();
        if ($now - $last_progress_time >= 1.0) {
            my $elapsed = $now - $start_time;
            my $rate = $processed / ($elapsed || 1);
            warn sprintf("processed %s elements; last chunk %s records; bytes_read %s; rate %.2f el/s\n",
                commify($processed), commify($records_in_chunk), commify($bytes_read), $rate);
            $last_progress_time = $now;
        }
    }
};

# iterate elements
my $remainder_after = stream_array_elements($IN, $array_initial_tail, $write_element);

# finish: close final chunk(s)
# if single-file raw mode, ensure closing bracket is written and file closed
if (!$split_lines) {
    if ($current_chunk_created && !$ndjson) {
        syswrite($current_fh, ']') or die "write failed: $!";
    }
    if (defined $current_fh && $current_fh != $OUT) { close $current_fh; }
    # close single OUT if it is a real file
    if (defined $OUT && fileno($OUT) && $OUT != *STDOUT) { close $OUT; }
} else {
    # split mode: if current chunk exists and has zero records, it will be closed and removed by close_current_chunk
    close_current_chunk();
}

my $elapsed = time() - $start_time;
printf STDERR "Done. total elements: %d; elapsed: %.2fs; rate: %.2f el/s; bytes_read: %s\n",
    $processed, $elapsed, ($processed / ($elapsed || 1)), commify($bytes_read) if $verbose;

# close input
close $IN unless $infile eq '-';

exit 0;
