package MBasic::Env;
use strict;
use warnings;
our $VERSION = '1.0';

# ============================================================================
#  MBasic::Env -- a program unit's runtime variable environment.
#
#  Per the manual, each program unit / sub call has its OWN environment,
#  reset on entry.  An Env holds this unit's variables (and, later, its file
#  channels / DATA pointer / RNG -- added when the executor needs them).
#
#  Variable model:
#    * numeric and string SCALARS, separate namespaces:  a  vs  a$
#    * numeric and string ARRAYS (1-D and 2-D):  a(i), b(i,j), c$(i)
#      (an array and a scalar of the same name may coexist)
#    * special read-only vars (intercepted on read): usr$, dat$, clk$
#      and the niladic builtins cnt / arg$(n) are provided by the run context
#      (command-line args), passed in at construction.
#
#  Naming: keys are the identifier lexemes as written ('a', 'a$', 'x1', 'p$').
#  We keep numeric and string in separate hashes so 'a' and 'a$' never collide.
#
#  Numbers are Perl doubles.  Uninitialized numeric scalar reads as 0;
#  uninitialized string scalar reads as "" (BASIC default-initialization).
# ============================================================================

sub new {
    my ($class, %opt) = @_;
    my $self = bless {
        nscalar => {},     # name  => number
        sscalar => {},     # name$ => string
        narray  => {},     # name  => { dims=>[...], data=>[...] }
        sarray  => {},     # name$ => { dims=>[...], data=>[...] }
        # run context (supplied by the interpreter for specials):
        argv    => $opt{argv} || [],   # command-line args -> arg$()/cnt
        user    => $opt{user},         # usr$   (defaults computed lazily)
        # date/time are computed live on read (dat$/clk$) unless overridden
        _now    => $opt{now},          # optional fixed epoch for deterministic tests
    }, $class;
    return $self;
}

# ---- helpers to classify a name ----
sub _is_string_name { my $n = shift; return substr($n, -1) eq '$'; }

# ---- special read-only variables (bare idents, no parens) ----
#   usr$  -> user id
#   dat$  -> MM/DD/YY
#   clk$  -> HH:MM:SS
#   (cnt and arg$ are handled by the evaluator via the run context.)
sub _special {
    my ($self, $name) = @_;
    if ($name eq 'usr$') {
        return defined $self->{user} ? $self->{user}
             : (getpwuid($<))[0] // $ENV{USER} // $ENV{LOGNAME} // 'user';
    }
    if ($name eq 'dat$' || $name eq 'clk$') {
        my @lt = localtime(defined $self->{_now} ? $self->{_now} : time);
        if ($name eq 'dat$') {
            return sprintf('%02d/%02d/%02d', $lt[4]+1, $lt[3], $lt[5] % 100);
        } else {
            return sprintf('%02d:%02d:%02d', $lt[2], $lt[1], $lt[0]);
        }
    }
    return undef;   # not a special
}
sub is_special { my ($self, $name) = @_; defined $self->_special($name) ? 1 : 0; }

# ---- run-context accessors used by the evaluator for cnt / arg$ ----
sub arg_count { my ($self) = @_; scalar @{$self->{argv}} }
sub arg_at    { my ($self, $n) = @_;                 # 1-based per BASIC arg$(n)
                my $v = $self->{argv}[$n-1]; defined $v ? $v : '' }

# ---- scalar read ----
# get_scalar('a')  -> number (0 if unset)
# get_scalar('a$') -> string ("" if unset), or a special value
sub get_scalar {
    my ($self, $name) = @_;
    if (_is_string_name($name)) {
        if (defined(my $sp = $self->_special($name))) { return $sp; }
        return exists $self->{sscalar}{$name} ? $self->{sscalar}{$name} : '';
    } else {
        return exists $self->{nscalar}{$name} ? $self->{nscalar}{$name} : 0;
    }
}

# ---- scalar write ----
sub set_scalar {
    my ($self, $name, $value) = @_;
    die "Invalid variable \"$name\" (read-only)\n"
        if $self->is_special($name);
    if (_is_string_name($name)) { $self->{sscalar}{$name} = "$value"; }
    else                        { $self->{nscalar}{$name} = $value + 0; }
    return $value;
}

# ---- dim: declare an array with given dimension bounds ----
# dims are the DECLARED upper bounds; BASIC arrays are 0..bound inclusive.
# declare('a', [75]) ; declare('b', [100,6]) ; declare('c$', [100])
sub declare_array {
    my ($self, $name, $bounds) = @_;
    my $store = _is_string_name($name) ? $self->{sarray} : $self->{narray};
    my $size = 1; $size *= ($_+1) for @$bounds;   # 0..bound inclusive
    my $init = _is_string_name($name) ? '' : 0;
    $store->{$name} = { dims => [ @$bounds ], data => [ ($init) x $size ] };
    return;
}

# compute flat index from subscripts (row-major), with bounds checking.
# Arrays used without an explicit dim default to bound 10 in BASIC; we
# auto-create on first access with bound 10 per dimension if not declared.
sub _array_slot {
    my ($self, $name, $subs, $for_write) = @_;
    my $store = _is_string_name($name) ? $self->{sarray} : $self->{narray};
    unless (exists $store->{$name}) {
        # implicit dimension: bound 10 in each subscript position
        $self->declare_array($name, [ (10) x scalar(@$subs) ]);
    }
    my $a = $store->{$name};
    my $dims = $a->{dims};
    die "Wrong number of dimensions for \"$name\"\n"
        if @$subs != @$dims;
    my $flat = 0;
    for my $d (0 .. $#$dims) {
        my $ix = int($subs->[$d]);      # subscripts truncate to integer
        die "Subscript out of bounds ($name subscript $ix, range 0..$dims->[$d])\n"
            if $ix < 0 || $ix > $dims->[$d];
        $flat = $flat * ($dims->[$d] + 1) + $ix;
    }
    return ($a, $flat);
}

# ---- array element read / write ----
sub get_array {
    my ($self, $name, $subs) = @_;
    my ($a, $flat) = $self->_array_slot($name, $subs, 0);
    return $a->{data}[$flat];
}
sub set_array {
    my ($self, $name, $subs, $value) = @_;
    my ($a, $flat) = $self->_array_slot($name, $subs, 1);
    $a->{data}[$flat] = _is_string_name($name) ? "$value" : $value + 0;
    return $value;
}

1;

__END__

=head1 NAME

MBasic::Env - a Multics BASIC variable environment

=head1 DESCRIPTION

Holds one program unit's variables: numeric and string scalars and 1- and
2-dimensional arrays (numeric and string namespaces are separate, so C<a>
and C<a$> are distinct).  Provides the read-only special variables C<usr$>
(user id), C<dat$> (date, C<MM/DD/YY>) and C<clk$> (time, C<HH:MM:SS>).
Uninitialized numeric variables read as 0 and string variables as the empty
string.  Array subscripts truncate to integers and are bounds-checked;
undeclared arrays default to bound 10 per dimension.

=head1 METHODS

=head2 new(%opt)

Constructor.  Options: C<argv> (arrayref, for C<arg$>/C<cnt>), C<user> (for
C<usr$>), C<now> (a fixed epoch time making C<dat$>/C<clk$> deterministic).

=head2 get_scalar($name) / set_scalar($name, $value)

Read/write a scalar.  Writing a special variable dies.

=head2 declare_array($name, \@bounds)

Declare an array with the given upper bounds (0..bound inclusive per dimension).

=head2 get_array($name, \@subs) / set_array($name, \@subs, $value)

Read/write an array element.

=head1 SEE ALSO

L<MBasic> for the overview and architecture.

=head1 AUTHOR

Jim Lippard <lippard@discord.org>

=head1 LICENSE

Copyright (c) 2026 Jim Lippard.  Free software under the BSD 3-Clause License.

=cut
