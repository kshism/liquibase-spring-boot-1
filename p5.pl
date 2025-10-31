#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use Time::HiRes qw(time);
use IO::Handle;
use bytes;
use POSIX qw(strftime);

# Robust extractor with splitting support (fixed edge cases)
# Usage (examples in conversation):
#   perl p5.pl --key accounts --in large_10k.json --split-lines 1000 --ndjson --split-prefix /tmp/10k_

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
                my $token = substr($s, $pos+1, $i - ($pos+1)); # raw inside
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
# element-extraction streamer: robust, refill-aware
# -------------------------
# Calls $callback->($elem_text) for each element found (raw JSON substring for the element).
# Returns the remainder bytes after the closing ']' (caller may ignore).
sub stream_array_elements {
    my ($fh_in, $first_chunk, $callback) = @_;

    # buffer holds the data we can safely index into; pos is current index
    my $buf = defined $first_chunk ? $first_chunk : '';
    my $pos = 0;

    # state for parsing current element
    my $element_start;   # undefined when not inside an element
    my $in_string = 0;
    my $esc = 0;
    my $depth = 0;       # nesting depth for object/array; depth==0 for primitives

    # helper to refill buffer preserving partial element from $element_start
    sub refill {
        # if element_start defined, keep partial from that point, else keep tail few bytes for boundary safety
        if (defined $element_start) {
            # keep bytes from element_start to end
            my $tail = substr($buf, $element_start);
            $buf = $tail;
            $pos = length($buf); # cause immediate read below
            $element_start = 0;  # normalize to new buffer start
        } else {
            # we are not inside an element; clear buffer
            $buf = '';
            $pos = 0;
        }
        # read next chunk
        my $r = sysread($fh_in, my $chunk, $buffer);
        die "sysread failed: $!" unless defined $r;
        if ($r == 0) {
            return 0; # EOF
        }
        $buf .= $chunk;
        return length($chunk);
    }

    # Ensure there is at least 1 byte in buffer to inspect; if not, refill once.
    sub ensure_data {
        if ($pos >= length($buf)) {
            my $got = refill();
            return 0 unless $got;
        }
        return 1;
    }

    while (1) {
        # ensure there is data before doing substr
        unless (ensure_data()) {
            # EOF reached
            last;
        }

        # fetch char safely
        my $c = substr($buf, $pos, 1);

        # not currently inside an element: look for element start or array close
        if (!defined $element_start) {
            if ($c =~ /\s/ || $c eq ',') { $pos++; next; }
            if ($c eq ']') {
                # found closing bracket: return remainder after ']'
                my $remain = '';
                if ($pos+1 <= length($buf)) { $remain = substr($buf, $pos+1); }
                return $remain;
            }
            # element starts here
            $element_start = $pos;
            $in_string = 0;
            $esc = 0;
            $depth = 0;
            # initialize state based on first char
            if ($c eq '{' || $c eq '[') { $depth = 1; $pos++; next; }
            if ($c eq '"') { $in_string = 1; $pos++; next; }
            # primitive start (number, true, false, null)
            $pos++;
            next;
        }

        # inside element parsing
        if ($in_string) {
            # ensure we have data
            unless (ensure_data()) {
                die "EOF while inside string of element starting at $element_start\n";
            }
            my $ch = substr($buf, $pos, 1);
            if ($esc) { $esc = 0; $pos++; next; }
            if ($ch eq '\\') { $esc = 1; $pos++; next; }
            if ($ch eq '"') {
                $in_string = 0;
                $pos++;
                # if primitive string (depth==0) ends element
                if ($depth == 0) {
                    my $elem_end = $pos;
                    # extract element and callback
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
            # inside nested object/array
            # ensure data
            unless (ensure_data()) {
                die "EOF while inside nested structure of element starting at $element_start\n";
            }
            my $ch = substr($buf, $pos, 1);
            if ($ch eq '"') { $in_string = 1; $esc = 0; $pos++; next; }
            if ($ch eq '{' || $ch eq '[') { $depth++; $pos++; next; }
            if ($ch eq '}' || $ch eq ']') {
                $depth--;
                $pos++;
                if ($depth == 0) {
                    # element finished
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
            # primitive (number/true/false/null) - consume until comma or closing bracket
            # ensure data
            unless (ensure_data()) {
                # EOF reached while reading primitive: accept it (tolerant) if we've read something
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
                # element ends before this char
                my $elem_end = $pos;
                if (defined $element_start && $elem_end <= length($buf)) {
                    my $elem = $elem_end > $element_start ? substr($buf, $element_start, $elem_end - $element_start) : '';
                    $elem =~ s/\s+$//s if defined $elem;
                    $callback->($elem) if defined $elem && length($elem) > 0;
                }
                $element_start = undef;
                # do not advance pos here; outer loop will see comma or ']' and handle it (skip or close)
                next;
            } else {
                $pos++; next;
            }
        }
    }

    # finished reading (EOF)
    if (defined $element_start) {
        die "EOF while reading array element\n";
    }
    return '';
}

# -------------------------
# open chunk file utilities
# -------------------------
sub pad_index {
    my ($i) = @_;
    return sprintf("%05d", $i);
}

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
        if (!$found) {
            die "Reached EOF but did not find target array (key='$key')\n";
        }
        last;
    } else {
        $chunk_to_process = ($partial || '') . $chunk;
        $partial = '';
    }

    if (!$found) {
        if (defined $key) {
            my ($status, $tail) = find_key_array($chunk_to_process, $key);
            if ($status == 1) {
                $found = 1;
                $array_initial_tail = $tail // '';
                last;
            } else {
                $partial = $tail;
            }
        } else {
            my ($status, $tail) = find_top_array($chunk_to_process);
            if ($status == 1) {
                $found = 1;
                $array_initial_tail = $tail // '';
                last;
            } else {
                $partial = $tail;
            }
        }
    } else {
        last;
    }

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
# Dispatch: iterate elements and write to appropriate outputs (single or split)
# -------------------------

# State for output chunking
my $chunk_index = 1;
my $records_in_chunk = 0;
my $current_fh;
my $current_fname;

# function to start a new chunk (opens handle and writes array '[' if raw mode)
sub start_new_chunk {
    my ($start_idx) = @_;
    if ($split_lines) {
        my ($fh, $fname) = open_chunk_handle($split_prefix, $start_idx, $ndjson);
        $current_fh = $fh;
        $current_fname = $fname;
        $records_in_chunk = 0;
        if (!$ndjson) {
            syswrite($current_fh, '[') or die "write failed: $!";
        }
    } else {
        $current_fh = $OUT;
        $current_fname = $outfile;
        if (!$ndjson) {
            syswrite($current_fh, '[') or die "write failed: $!";
        }
        $records_in_chunk = 0;
    }
}

# function to close current chunk
sub close_current_chunk {
    if (!$current_fh) { return; }
    if (!$ndjson) {
        syswrite($current_fh, ']') or die "write failed: $!";
    }
    if ($split_lines) {
        close $current_fh;
    }
    $current_fh = undef;
    $current_fname = undef;
}

# Initialize first chunk
start_new_chunk($chunk_index);

# callback invoked for each element text
my $processed = 0;
my $start_time = time();
my $last_progress_time = $start_time;

my $write_element = sub {
    my ($elem) = @_;
    return unless defined $elem;            # defensive

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

    if ($split_lines && $split_lines > 0 && $records_in_chunk >= $split_lines) {
        close_current_chunk();
        $chunk_index++;
        start_new_chunk($chunk_index);
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

# finish: close last chunk(s)
close_current_chunk();

my $elapsed = time() - $start_time;
printf STDERR "Done. total elements: %d; elapsed: %.2fs; rate: %.2f el/s; bytes_read: %s\n",
    $processed, $elapsed, ($processed / ($elapsed || 1)), commify($bytes_read) if $verbose;

# close handles
close $IN unless $infile eq '-';
if (!$split_lines) {
    close $OUT unless $outfile eq '-';
}

exit 0;
