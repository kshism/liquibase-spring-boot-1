#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use Time::HiRes qw(time);
use IO::Handle;
use bytes;
use threads;
use threads::shared;
use Thread::Queue;
use File::Spec;
use File::Temp qw(tempdir);
use File::Basename qw(basename);

# parallel_extract_final_fixed.pl
# Same as before but fixes temp filename creation when --split-prefix contains slashes.

my $infile;
my $outfile;
my $key = 'accounts';
my $ndjson = 1;                # NDJSON mode ON by default
my $buffer = 4 * 1024 * 1024;  # 4 MB read buffer
my $verbose = 0;
my $split_lines = 0;
my $split_prefix;
my $workers = 4;               # HARD-CODED WORKER THREAD COUNT
my $tmp_dir;

GetOptions(
    "in=s"          => \$infile,
    "out=s"         => \$outfile,
    "key=s"         => \$key,
    "ndjson!"       => \$ndjson,
    "buffer=i"      => \$buffer,
    "verbose!"      => \$verbose,
    "split-lines=i" => \$split_lines,
    "split-prefix=s"=> \$split_prefix,
    "tmpdir=s"      => \$tmp_dir,
) or die "Bad options\n";

die "Specify --in\n" unless defined $infile;
if ($split_lines) {
    die "--split-prefix is required when --split-lines is used\n" unless defined $split_prefix;
    if (defined $outfile && $outfile eq '-') {
        die "Cannot split output to stdout ('--out -'); use --split-prefix\n";
    }
} else {
    die "Specify --out\n" unless defined $outfile;
}

# open input
open my $IN, '<:raw', $infile or die "open $infile: $!";

# parallel only works for NDJSON in this design
my $parallel_ok = $ndjson ? 1 : 0;

# create temp dir if not supplied
unless (defined $tmp_dir) {
    $tmp_dir = tempdir("parlexXXXX", CLEANUP => 0);
}
unless (-d $tmp_dir) {
    mkdir $tmp_dir or die "mkdir $tmp_dir: $!";
}

# For temp file naming: derive a safe prefix (basename) so we don't embed slashes in tmp filenames.
my $tmp_safe_prefix = defined $split_prefix ? basename($split_prefix) : 'chunk';
# if basename returns empty (weird), fallback
$tmp_safe_prefix = 'chunk' unless defined $tmp_safe_prefix && length $tmp_safe_prefix;

# queue and shared counters
my $q = Thread::Queue->new();
my $seq :shared = 0;
my $processed :shared = 0;
my $bytes_read :shared = 0;

sub now { time() }
sub commify { local $_ = shift; 1 while s/^(-?\d+)(\d{3})/$1,$2/; $_ }

# -------------------------
# JSON helpers
# -------------------------
sub extract_string {
    my ($s, $pos) = @_;
    my $len = length($s);
    return (undef, -1) if $pos >= $len || substr($s,$pos,1) ne '"';
    my $i = $pos + 1; my $esc = 0;
    while ($i < $len) {
        my $c = substr($s,$i,1);
        if ($esc) { $esc = 0; }
        else {
            if ($c eq '\\') { $esc = 1; }
            elsif ($c eq '"') {
                my $tok = substr($s, $pos+1, $i - ($pos+1));
                return ($tok, $i+1);
            }
        }
        $i++;
    }
    return (undef, -1);
}

sub find_key_array {
    my ($s, $key) = @_;
    my $i = 0; my $len = length($s);
    while ($i < $len) {
        my $c = substr($s,$i,1);
        if ($c eq '"') {
            my ($tok,$next) = extract_string($s,$i);
            if ($next == -1) { return (0, substr($s,$i)); }
            if (defined $key && $tok eq $key) {
                my $j = $next;
                while ($j < $len && substr($s,$j,1) =~ /\s/) { $j++ }
                return (0, substr($s,$i)) if $j >= $len;
                return (0, substr($s,$i)) if substr($s,$j,1) ne ':';
                $j++;
                while ($j < $len && substr($s,$j,1) =~ /\s/) { $j++ }
                if ($j < $len && substr($s,$j,1) eq '[') {
                    return (1, substr($s, $j+1));
                } else { return (0, substr($s,$i)); }
            }
            $i = $next; next;
        } else { $i++ }
    }
    my $keep = defined $key ? length($key)*4 + 32 : 64;
    return (0, length($s) > $keep ? substr($s,-$keep) : $s);
}

sub stream_array_elements {
    my ($fh_in, $first_chunk, $callback, $bufsize) = @_;
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
        } else { $buf = ''; $pos = 0; }
        my $r = sysread($fh_in, my $chunk, $bufsize);
        die "sysread failed: $!" unless defined $r;
        return 0 if $r == 0;
        {
            lock($bytes_read);
            $bytes_read += $r;
        }
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
        my $c = substr($buf,$pos,1);
        if (!defined $element_start) {
            if ($c =~ /\s/ || $c eq ',') { $pos++; next; }
            if ($c eq ']') { return ''; }
            $element_start = $pos; $in_string = 0; $esc = 0; $depth = 0;
            if ($c eq '{' || $c eq '[') { $depth = 1; $pos++; next; }
            if ($c eq '"') { $in_string = 1; $pos++; next; }
            $pos++; next;
        }

        if ($in_string) {
            die "EOF while inside string\n" unless $ensure_data->();
            my $ch = substr($buf,$pos,1);
            if ($esc) { $esc = 0; $pos++; next; }
            if ($ch eq '\\') { $esc = 1; $pos++; next; }
            if ($ch eq '"') {
                $in_string = 0; $pos++;
                if ($depth == 0) {
                    my $elem = substr($buf,$element_start, $pos - $element_start);
                    $callback->($elem);
                    $element_start = undef;
                }
                next;
            }
            $pos++; next;
        } elsif ($depth > 0) {
            die "EOF while inside nested structure\n" unless $ensure_data->();
            my $ch = substr($buf,$pos,1);
            if ($ch eq '"') { $in_string = 1; $esc = 0; $pos++; next; }
            if ($ch eq '{' || $ch eq '[') { $depth++; $pos++; next; }
            if ($ch eq '}' || $ch eq ']') {
                $depth--; $pos++;
                if ($depth == 0) {
                    my $elem = substr($buf,$element_start, $pos - $element_start);
                    $callback->($elem);
                    $element_start = undef;
                }
                next;
            }
            $pos++; next;
        } else {
            unless ($ensure_data->()) {
                if (defined $element_start && $pos > $element_start) {
                    my $elem = substr($buf,$element_start, $pos - $element_start);
                    $callback->($elem) if defined $elem && length($elem) > 0;
                    $element_start = undef;
                } else { last; }
                last;
            }
            my $ch = substr($buf,$pos,1);
            if ($ch eq ',' || $ch eq ']') {
                my $elem = substr($buf,$element_start, $pos - $element_start);
                $callback->($elem) if defined $elem && length($elem) > 0;
                $element_start = undef;
                next;
            } else { $pos++; next; }
        }
    }
    return '';
}

# -------------------------
# worker routine: write to per-worker-per-chunk temp files using tmp_safe_prefix
# -------------------------
sub worker_main {
    my ($id, $qref, $split_lines_local, $split_prefix_local, $tmpdir_local, $tmp_prefix_local) = @_;
    my %fh_cache;
    while (1) {
        my $item = $qref->dequeue();
        last unless defined $item;
        my ($seq_num, $elem_text) = @{$item}{qw(seq elem)};
        my $chunk_idx = $split_lines_local ? int(($seq_num - 1) / $split_lines_local) + 1 : 1;

        # Use tmp_prefix_local (safe, basename) for tmp file names so no slashes are embedded.
        my $tmpfname = File::Spec->catfile($tmpdir_local, sprintf("%s_%05d_w%02d.ndtmp", $tmp_prefix_local, $chunk_idx, $id));

        my $fh = $fh_cache{$tmpfname};
        unless ($fh) {
            open my $newfh, '>:raw', $tmpfname or die "open $tmpfname: $!";
            $newfh->autoflush(1);
            $fh_cache{$tmpfname} = $newfh;
            $fh = $newfh;
        }

        syswrite($fh, $elem_text . "\n") or die "write failed: $!";
        {
            lock($processed);
            $processed++;
        }
    }
    for my $h (values %fh_cache) { close $h; }
    return;
}

# -------------------------
# find array start
# -------------------------
my $partial = '';
my $found = 0;
my $array_initial_tail = '';
my $t0 = now();
my $last_report = $t0;

while (1) {
    my $r = sysread($IN, my $chunk, $buffer);
    die "sysread failed: $!" unless defined $r;
    {
        lock($bytes_read);
        $bytes_read += $r if $r;
    }
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
        my ($status, $tail) = find_key_array($chunk_to_process, $key);
        if ($status == 1) { $found = 1; $array_initial_tail = $tail // ''; last; }
        $partial = $tail;
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
# spawn workers
# -------------------------
my @threads;
for my $i (1 .. $workers) {
    push @threads, threads->create(\&worker_main, $i, $q, $split_lines, $split_prefix // 'chunk', $tmp_dir, $tmp_safe_prefix);
}

# -------------------------
# parser callback enqueues elements
# -------------------------
my $parser_callback = sub {
    my ($elem_text) = @_;
    my $myseq;
    {
        lock($seq);
        $seq++;
        $myseq = $seq;
    }
    $q->enqueue({ seq => $myseq, elem => $elem_text });
};

stream_array_elements($IN, $array_initial_tail, $parser_callback, $buffer);

# signal workers to stop
$q->enqueue(undef) for @threads;
$_->join() for @threads;

# -------------------------
# merge temp worker files into final chunk files
# -------------------------
my %chunk_counts;
if ($split_lines) {
    my $chunks_expected = int(($processed + $split_lines - 1) / $split_lines);
    for my $chunk_idx (1 .. $chunks_expected) {
        my $final_fname = $split_prefix . "_" . sprintf("%05d", $chunk_idx) . ".ndjson";
        open my $outfh, '>:raw', $final_fname or die "open $final_fname: $!";
        my $count_in_chunk = 0;
        for my $wid (1 .. $workers) {
            my $tmpfname = File::Spec->catfile($tmp_dir, sprintf("%s_%05d_w%02d.ndtmp", $tmp_safe_prefix, $chunk_idx, $wid));
            next unless -e $tmpfname;
            open my $tfh, '<:raw', $tmpfname or die "open $tmpfname: $!";
            while (my $line = <$tfh>) {
                syswrite($outfh, $line) or die "write failed: $!";
                $count_in_chunk++;
            }
            close $tfh;
            unlink $tmpfname;
        }
        close $outfh;
        $chunk_counts{$final_fname} = $count_in_chunk;
    }
} else {
    # single file NDJSON merge (if ndjson and not split_lines)
    if ($ndjson) {
        open my $outfh, '>:raw', $outfile or die "open $outfile: $!";
        my $count = 0;
        for my $wid (1 .. $workers) {
            my $pattern = File::Spec->catfile($tmp_dir, sprintf("%s_*_w%02d.ndtmp", $tmp_safe_prefix, $wid));
            my @files = glob $pattern;
            for my $tmpf (sort @files) {
                open my $tfh, '<:raw', $tmpf or die "open $tmpf: $!";
                while (my $line = <$tfh>) {
                    syswrite($outfh, $line) or die "write failed: $!";
                    $count++;
                }
                close $tfh;
                unlink $tmpf;
            }
        }
        close $outfh;
        $chunk_counts{$outfile} = $count;
    }
}

# -------------------------
# final summary
# -------------------------
my $elapsed = time() - $t0;
my $rate = $elapsed ? ($processed / $elapsed) : 0;
my $mbps = $elapsed ? ($bytes_read / (1024*1024)) / $elapsed : 0;
printf STDERR "Done. total elements: %d; elapsed: %.2fs; rate: %.2f el/s; throughput: %.2f MB/s; workers: %d\n",
    $processed, $elapsed, $rate, $mbps, $workers;

if ($split_lines) {
    warn "Chunks created:\n";
    for my $chunk (sort keys %chunk_counts) {
        warn sprintf("  %s — %d records\n", $chunk, $chunk_counts{$chunk});
    }
} else {
    warn sprintf("Output file: %s — %d records\n", ($outfile // '-'), $processed);
}

close $IN;
exit 0;
