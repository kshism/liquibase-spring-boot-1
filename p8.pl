#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use Time::HiRes qw(time);
use IO::Handle;
use bytes;
use POSIX qw(sysconf _SC_NPROCESSORS_ONLN);
use Fcntl qw(:DEFAULT :flock);
use threads;
use threads::shared;
use Thread::Queue;

# parallel-extract.pl
# Usage examples (same as before), plus:
#   --workers N      number of worker threads to spawn (default: CPU count or 4)
#
# Important: parallel mode is enabled when --ndjson is set. For raw JSON array output
# the script will run single-threaded to maintain correct commas/brackets.

my $infile;
my $outfile;
my $key = 'accounts';
my $ndjson = 0;
my $buffer = 4 * 1024 * 1024;    # 4 MB
my $verbose = 0;
my $split_lines = 0;
my $split_prefix;
my $workers = 0;

GetOptions(
    "in=s"          => \$infile,
    "out=s"         => \$outfile,
    "key=s"         => \$key,
    "ndjson!"       => \$ndjson,
    "buffer=i"      => \$buffer,
    "verbose!"      => \$verbose,
    "split-lines=i" => \$split_lines,
    "split-prefix=s"=> \$split_prefix,
    "workers=i"     => \$workers,
) or die "Bad options\n";

die "Specify --in\n" unless defined $infile;
if ($split_lines) {
    die "--split-prefix is required when --split-lines is used\n" unless defined $split_prefix;
    if (defined $outfile && $outfile eq '-') {
        die "Cannot split output to stdout ('--out -'); provide a split-prefix and allow script to create files.\n";
    }
} else {
    die "Specify --out\n" unless defined $outfile;
}

# normalize key: empty string => top-level array
$key = undef if defined $key && $key eq '';

# open input
my $IN;
if ($infile eq '-') {
    binmode(STDIN);
    $IN = *STDIN;
} else {
    open $IN, '<:raw', $infile or die "open $infile: $!";
}

# open single output if not splitting and not using threaded NDJSON
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

# Determine worker count
if (!$workers) {
    my $n = eval { sysconf(_SC_NPROCESSORS_ONLN) } || 0;
    $workers = $n > 0 ? $n : 4;
}
# don't spawn more workers than logical: at least 1
$workers = 1 if $workers < 1;

# If user didn't ask ndjson, we won't run parallel writer (too tricky for array commas)
my $parallel_ok = $ndjson ? 1 : 0;

# Thread::Queue: queue of hashrefs { seq => N, elem => TEXT }
my $q = Thread::Queue->new();

# shared sequence counter (assigned by parser)
my $seq :shared = 0;

# shared processed count (updated by workers)
my $processed :shared = 0;

# bookkeeping for created chunks (main process will collect info after workers finish)
my @chunks_info :shared; # won't be heavily used; workers will produce files / we can scan

# helpers
sub now { time() }
sub commify { local $_ = shift; 1 while s/^(-?\d+)(\d{3})/$1,$2/; $_ }

# -------------------------
# low-level JSON parsing helpers (same robust streaming parser)
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

sub find_key_array {
    my ($s, $key) = @_;
    my $i = 0; my $len = length($s);
    while ($i < $len) {
        my $c = substr($s, $i, 1);
        if ($c eq '"') {
            my ($token, $next) = extract_string($s, $i);
            if ($next == -1) { return (0, substr($s, $i)); }
            if (defined $key && $token eq $key) {
                my $j = $next;
                while ($j < $len && substr($s,$j,1) =~ /\s/) { $j++ }
                return (0, substr($s,$i)) if $j >= $len;
                return (0, substr($s,$i)) if substr($s,$j,1) ne ':';
                $j++;
                while ($j < $len && substr($s,$j,1) =~ /\s/) { $j++ }
                if ($j < $len && substr($s,$j,1) eq '[') {
                    return (1, substr($s, $j+1));
                } else {
                    return (0, substr($s,$i));
                }
            }
            $i = $next; next;
        } else { $i++ }
    }
    my $keep = defined $key ? length($key)*4 + 32 : 64;
    return (0, length($s) > $keep ? substr($s, -$keep) : $s);
}

sub find_top_array {
    my ($s) = @_;
    my $i = 0; my $len = length($s);
    while ($i < $len) {
        my $c = substr($s,$i,1);
        if ($c eq '"') {
            my ($tok,$next) = extract_string($s,$i);
            return (0, substr($s,$i)) if $next == -1;
            $i = $next; next;
        } elsif ($c =~ /\s/) { $i++; next; }
        elsif ($c eq '[') { return (1, substr($s,$i+1)); }
        else { last; }
    }
    my $keep = 64;
    return (0, length($s) > $keep ? substr($s,-$keep) : $s);
}

# stream_array_elements copied and simplified: on element found -> call callback($elem_text)
sub stream_array_elements {
    my ($fh_in, $first_chunk, $callback, $bufsize) = @_;
    my $buf = defined $first_chunk ? $first_chunk : '';
    my $pos = 0;
    my $element_start;
    my $in_string = 0; my $esc = 0; my $depth = 0;

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
        my $r = sysread($fh_in, my $chunk, $bufsize);
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
        my $c = substr($buf,$pos,1);
        if (!defined $element_start) {
            if ($c =~ /\s/ || $c eq ',') { $pos++; next; }
            if ($c eq ']') {
                my $remain = ($pos+1 <= length($buf)) ? substr($buf,$pos+1) : '';
                return $remain;
            }
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
                    $elem =~ s/\s+$//s if defined $elem;
                    $callback->($elem) if defined $elem && length($elem) > 0;
                    $element_start = undef;
                } else { die "EOF reading primitive element\n"; }
                last;
            }
            my $ch = substr($buf,$pos,1);
            if ($ch eq ',' || $ch eq ']') {
                my $elem = substr($buf,$element_start, $pos - $element_start);
                $elem =~ s/\s+$//s if defined $elem;
                $callback->($elem) if defined $elem && length($elem) > 0;
                $element_start = undef;
                next;
            } else {
                $pos++; next;
            }
        }
    }
    die "EOF while reading array element\n" if defined $element_start;
    return '';
}

# -------------------------
# worker thread: pop items and write NDJSON lines to files in parallel
# -------------------------
sub worker_main {
    my ($id, $qref, $split_lines_local, $split_prefix_local, $ndjson_local) = @_;
    my %local_fhs;   # cache filehandles per chunkname for this worker
    while (1) {
        my $item = $qref->dequeue();
        last unless defined $item;                 # undef sentinel => exit
        my ($seq_num, $elem_text) = @{$item}{qw(seq elem)};
        # compute chunk index (1-based)
        my $chunk_idx = $split_lines_local ? int(($seq_num - 1) / $split_lines_local) + 1 : 1;
        my $fname;
        if ($split_lines_local) {
            $fname = $split_prefix_local . "_" . sprintf("%05d", $chunk_idx) . ($ndjson_local ? ".ndjson" : ".json");
        } else {
            $fname = $outfile;
        }

        # ensure fh cached
        my $fh = $local_fhs{$fname};
        unless ($fh) {
            # open in append mode; worker will keep fh until thread exits
            sysopen(my $newfh, $fname, O_WRONLY | O_APPEND | O_CREAT) or die "sysopen $fname: $!";
            binmode($newfh);
            $local_fhs{$fname} = $newfh;
            $fh = $newfh;
        }

        # write line with exclusive flock for safety
        flock($fh, LOCK_EX) or die "flock LOCK_EX failed: $!";
        syswrite($fh, $elem_text . "\n") or die "write failed: $!";
        flock($fh, LOCK_UN) or die "flock LOCK_UN failed: $!";

        {
            lock($processed);
            $processed++;
        }
    }

    # close local filehandles
    foreach my $h (values %local_fhs) {
        close $h;
    }
    return;
}

# -------------------------
# main: find array start, then parse and push elements to queue
# -------------------------
my $partial = '';
my $bytes_read = 0;
my $t0 = now();
my $last_report = $t0;
my $found = 0;
my $array_initial_tail = '';

# scan input to find array start (either key or top-level)
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
        my ($status, $tail) = defined $key ? find_key_array($chunk_to_process, $key) : find_top_array($chunk_to_process);
        if ($status == 1) {
            $found = 1;
            $array_initial_tail = $tail // '';
            last;
        } else {
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

# Start worker threads if parallel_ok
my @workers;
if ($parallel_ok && $workers > 1) {
    for my $i (1 .. $workers) {
        push @workers, threads->create(\&worker_main, $i, $q, $split_lines, $split_prefix, $ndjson);
    }
} else {
    # if not parallel, we will still use a single worker thread to keep code path uniform
    push @workers, threads->create(\&worker_main, 1, $q, $split_lines, $split_prefix, $ndjson);
}

# Parser callback: assign sequence and enqueue
my $parser_callback = sub {
    my ($elem_text) = @_;
    # assign sequence number
    my $myseq;
    {
        lock($seq);
        $seq++;
        $myseq = $seq;
    }
    # enqueue
    $q->enqueue( { seq => $myseq, elem => $elem_text } );
};

# Run parser and stream elements (single-threaded)
stream_array_elements($IN, $array_initial_tail, $parser_callback, $buffer);

# signal workers to exit: enqueue undef per worker
for (1 .. scalar @workers) { $q->enqueue(undef); }

# join workers
$_->join() for @workers;

my $elapsed = time() - $t0;
my $rate = $elapsed ? ($processed / $elapsed) : 0;
my $mbps = $elapsed ? ($bytes_read / (1024*1024)) / $elapsed : 0;

# Final summary
printf STDERR "Done. total elements: %d; elapsed: %.2fs; rate: %.2f el/s; bytes_read: %s; throughput: %.2f MB/s\n",
    $processed, $elapsed, $rate, commify($bytes_read), $mbps;

if ($split_lines) {
    # list files created with simple stat (non-exhaustive)
    warn "Chunk files (approx):\n";
    # compute expected number of chunks
    my $chunks_expected = $split_lines ? int(($processed + $split_lines - 1)/$split_lines) : 1;
    for my $i (1 .. $chunks_expected) {
        my $fname = $split_prefix . "_" . sprintf("%05d", $i) . ($ndjson ? ".ndjson" : ".json");
        if (-e $fname) {
            my $count_est = 0;
            # estimate by counting lines for ndjson
            if ($ndjson) {
                # fast line count
                if (open my $lf, '<:raw', $fname) {
                    my $lines = 0;
                    $lines++ while <$lf>;
                    close $lf;
                    $count_est = $lines;
                }
            }
            warn sprintf("  %s — %s records\n", $fname, $count_est ? $count_est : "exists");
        } else {
            warn sprintf("  %s — (missing)\n", $fname);
        }
    }
} else {
    warn sprintf("Output file: %s — %d records\n", ($outfile // '-'), $processed);
}

close $IN unless $infile eq '-';
exit 0;
