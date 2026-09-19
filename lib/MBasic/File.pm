package MBasic::File;
use strict;
use warnings;
our $VERSION = '1.1';

# ============================================================================
#  MBasic::File -- one terminal-format file channel (#1..#4).
#
#  Terminal-format files are the only kind Explore uses: a sequence of lines
#  of ASCII text.  We hold the file's lines in memory (loaded on open), serve
#  reads from a cursor, and flush writes back to disk.
#
#  Model / semantics (from AM82-01 + verified Multics behaviors):
#    open(path):   load the file's lines if it exists; if absent, start empty.
#                  LAZY -- a missing file does NOT error on open; it simply
#                  reads as immediately at-end (verified: `file` on a
#                  nonexistent file makes `if end` true, no error).
#    input fields: fields are delimited by COMMA or NEWLINE; the cursor
#                  advances past the delimiter.  Reads span lines as needed.
#    linput:       returns the rest of the current line (a whole line), cursor
#                  moves to the start of the next line.
#    print:        the FIRST print sets the pointer to END (append).  We model
#                  print as appending a line to the buffer (BASIC print #n
#                  writes a line of output; a trailing ';' would suppress the
#                  newline, but Explore's print #n statements each emit one
#                  logical line -- see note).  Writes flush to disk.
#    scratch:      erase all content, cursor to beginning.
#    reset:        cursor to beginning (re-read).
#    at_end:       true when the cursor is past the last datum.
#
#  NOTE on print #n and ';':  a print list builds one output line; a trailing
#  ';' suppresses the newline so the NEXT print continues the same line.  We
#  track a pending (unterminated) output line and only commit it as a buffer
#  line when a newline is produced (print with no trailing ';', or an explicit
#  break).  For Explore's usage each print #n produces a complete comma-joined
#  line, so this is straightforward.
# ============================================================================

sub new {
    my ($class, %o) = @_;
    bless {
        path    => $o{path},
        lines   => [],        # the file content, one string per line
        line    => 0,         # cursor: current line index (0-based)
        col     => 0,         # cursor: character offset within lines[line]
        dirty   => 0,         # needs flush?
        pending => undef,     # partial output line not yet committed (print ;)
        wrote   => 0,         # has any print happened (append semantics)?
    }, $class;
}

# open a file on this channel: load its content (lazy -- missing is empty).
sub open_path {
    my ($class, $path) = @_;
    my $self = $class->new(path => $path);
    if (defined $path && -f $path) {
        open my $fh, '<', $path or do { return $self; };  # unreadable -> empty
        local $/ = "\n";   # never inherit a caller's alternate record separator
        my @l = <$fh>; close $fh;
        chomp @l;
        $self->{lines} = \@l;
    }
    return $self;   # cursor at beginning; if no lines, at_end is immediately true
}

# ---- read position helpers ----
sub at_end {
    my ($self) = @_;
    return 1 if $self->{line} > $#{$self->{lines}};
    # at last line but past its end, with no more lines -> end
    if ($self->{line} == $#{$self->{lines}}
        && $self->{col} >= length($self->{lines}[$self->{line}])) {
        return 1;
    }
    return 0;
}

# reset cursor to the beginning (reset #n)
sub reset_pointer {
    my ($self) = @_;
    $self->{line} = 0; $self->{col} = 0;
    return;
}

# scratch: erase content
sub scratch {
    my ($self) = @_;
    $self->{lines} = []; $self->{line}=0; $self->{col}=0;
    $self->{pending} = undef; $self->{dirty} = 1;
    $self->_flush;
    return;
}

# ---- reading ----
# linput: return the remainder of the current line; advance to next line start.
sub linput {
    my ($self) = @_;
    die "End-of-file ($self->{path})\n" if $self->at_end;
    my $cur = $self->{lines}[$self->{line}] // '';
    my $val = substr($cur, $self->{col});
    $self->{line}++; $self->{col} = 0;
    return $val;
}

# input one field: gather characters up to the next comma or end-of-line,
# then advance past that delimiter.  A field may be numeric or string; the
# caller (executor) coerces per the target variable's type.
sub input_field {
    my ($self) = @_;
    die "Not enough input, add more ($self->{path})\n" if $self->at_end;
    # if cursor is at end of the current line, move to next line
    while ($self->{line} <= $#{$self->{lines}}
           && $self->{col} >= length($self->{lines}[$self->{line}])) {
        $self->{line}++; $self->{col} = 0;
        die "Not enough input, add more ($self->{path})\n"
            if $self->{line} > $#{$self->{lines}};
    }
    my $cur = $self->{lines}[$self->{line}];
    my $comma = index($cur, ',', $self->{col});
    my $field;
    if ($comma < 0) {
        # rest of line is the field; advance to next line
        $field = substr($cur, $self->{col});
        $self->{line}++; $self->{col} = 0;
    } else {
        $field = substr($cur, $self->{col}, $comma - $self->{col});
        $self->{col} = $comma + 1;   # past the comma
    }
    # trim surrounding blanks for numeric-ish fields (caller decides coercion);
    # for strings, Multics allows quoted fields -- strip surrounding quotes.
    $field =~ s/^\s+//; $field =~ s/\s+$//;
    if ($field =~ /^"(.*)"$/) { $field = $1; $field =~ s/""/"/g; }
    return $field;
}

# ---- writing ----
# print a rendered chunk to the file's current output line; if $newline,
# terminate the line (commit it to the buffer).  First write triggers append
# semantics: the pointer is at end, so we append new lines to {lines}.
#
# NOTE on Multics vs Unix visibility:  On Multics, print writes into the
# single-level-store segment but the segment's BIT-COUNT (recorded length)
# lags until close (or an adjust_bit_count/abc call), so an EXTERNAL process
# reading mid-run sees "zero length" or stale data -- which is exactly why the
# game uses the "reopen the channel" trick or `abc` before other players read
# a shared file.  On Unix a file's length follows its bytes immediately, so we
# flush eagerly here: cross-process reads see writes at once (the behavior the
# game's abc/trick machinery was straining to achieve on Multics), and `abc`
# becomes a harmless no-op.  Same-program reads are served from {lines}.
sub print_chunk {
    my ($self, $text, $newline) = @_;
    $self->{wrote} = 1;
    $self->{pending} = '' unless defined $self->{pending};
    $self->{pending} .= $text;
    if ($newline) {
        push @{$self->{lines}}, $self->{pending};
        $self->{pending} = undef;
    }
    $self->{dirty} = 1;
    $self->_flush;              # eager flush (Unix cross-process visibility)
    return;
}

# flush buffered content to disk (called on scratch, close, and after writes).
#
# Written atomically via a temp file + rename, which (a) never leaves a
# truncated/half-written file if the process dies or the disk fills mid-write,
# and (b) replaces a planted SYMLINK at the target with a real file instead of
# clobbering whatever the link points at.  Write failures raise an authentic
# BASIC error rather than silently losing data.
#
# NOTE: this does NOT provide multi-writer locking.  The whole-file rewrite
# model means concurrent writers can still lose updates; coordinating that is
# the embedder's responsibility (Explore's helpers use advisory locking around
# their shared files).  What is fixed here is data-destruction: partial writes,
# symlink clobbering, and silent write errors.
sub _flush {
    my ($self) = @_;
    return unless defined $self->{path};
    my $path = $self->{path};
    my $tmp  = "$path.mbtmp.$$";
    open my $fh, '>', $tmp
        or die "Cannot write into file ($path): $!\n";
    my $ok = eval {
        print $fh map { "$_\n" } @{$self->{lines}};
        # a pending (unterminated) partial line is written without a newline
        print $fh $self->{pending} if defined $self->{pending};
        close $fh or die "close: $!\n";
        1;
    };
    unless ($ok) {
        my $err = $@ || 'write error';
        close $fh;
        unlink $tmp;
        die "Cannot write into file ($path): $err\n";
    }
    unless (rename $tmp, $path) {
        my $err = $!;
        unlink $tmp;
        die "Cannot write into file ($path): $err\n";
    }
    $self->{dirty} = 0;
    return;
}

sub close {
    my ($self) = @_;
    # Only flush channels that were actually written to; a read-only channel
    # must never rewrite (and thus never touch mtime or risk clobbering) its
    # file just because it is being closed.  A pending (unterminated) partial
    # line is flushed as-is by _flush, without forcing a spurious newline.
    $self->_flush if $self->{wrote};
    return;
}

1;

__END__

=head1 NAME

MBasic::File - a Multics BASIC terminal-format file channel

=head1 DESCRIPTION

One terminal-format file channel.  Loads a file's lines on open (a missing
file is not an error -- it simply reads as immediately at-end, matching
Multics), serves sequential field and line reads, and appends writes.
Writes are flushed eagerly so that other processes see them immediately;
this is the behavior the Multics game works to achieve with its
adjust-bit-count and channel-reopen tricks, and on Unix it is automatic.

=head1 METHODS

=head2 open_path($path)

Class method.  Open a channel on a file, loading its content.

=head2 input_field / linput / print_chunk($text, $newline) / scratch / reset_pointer / at_end / close

Field read, whole-line read, buffered write, erase, rewind, end-of-file test,
and flush-and-close, respectively.

=head1 SEE ALSO

L<MBasic> for the overview and architecture.

=head1 AUTHOR

Jim Lippard <lippard@discord.org>

=head1 LICENSE

Copyright (c) 2026 Jim Lippard.  Free software under the BSD 3-Clause License.

=cut
