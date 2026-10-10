use strict; use warnings;
use FindBin; use lib "$FindBin::Bin/../lib";
use Test::More;
use MBasic::Program; use MBasic::Linker; use MBasic::Executor;

# Exhausted terminal input must END a program, not become an endless supply of
# empty lines.  `linput` used to do the latter ($line = '' unless defined),
# so any program with a command loop span forever once stdin was closed --
# Explore at 99% CPU, printing "? " without bound, after something as ordinary
# as `explore < script` or a `..cat` that swallowed the rest of stdin.
#
# The distinction that matters: an EMPTY LINE is real input and must still be
# delivered; only exhaustion (undef from the input hook) ends the run.

# Run with a bounded output sink, so a program that spins fails loudly here
# instead of hanging the test suite.
sub run_bounded {
    my ($lines, @answers) = @_;
    my $prog = MBasic::Program->load_lines($lines, '(test)');
    MBasic::Linker->link_program($prog);
    my ($out, $writes) = ('', 0);
    my $err = '';
    my $ok = eval {
        MBasic::Executor->run_program($prog,
            out   => sub {
                die "SPUN: still writing after 5000 writes with no input left\n"
                    if ++$writes > 5000;
                $out .= $_[0];
            },
            input => sub { @answers ? shift @answers : undef });
        1;
    };
    $err = $@ unless $ok;
    return ($out, $err);
}

# ---- linput: exhausted input ends the run (it used to spin) ----
{
    my ($out, $err) = run_bounded(['10 linput a$', '20 goto 10']);
    unlike($err, qr/SPUN/, 'linput at end of input does not spin');
    like($err, qr/^Not enough input, add more \(line 10\)/,
         'linput at end of input reports the authentic condition');
}

# ---- the same loop with answers available consumes them, then ends ----
{
    my ($out, $err) = run_bounded(['10 linput a$', '20 print a$', '30 goto 10'],
                                  'north', 'get lamp');
    is($out, "? north\n? get lamp\n? ", 'linput reads every answer supplied');
    like($err, qr/Not enough input/, 'and ends once they are exhausted');
}

# ---- an EMPTY line is still real input, not end of input ----
{
    my ($out, $err) = run_bounded(['10 linput a$', '20 print "[" & a$ & "]"',
                                   '30 end'], '');
    is($err, '', 'an empty answer is not mistaken for end of input');
    is($out, "? []\n", 'the empty line is assigned as the empty string');
}

# ---- a loop fed empty lines keeps running (so the fix is about EOF only) ----
{
    my ($out, $err) = run_bounded(['10 linput a$', '20 if a$ = "q" then 40',
                                   '30 goto 10', '40 print "done"', '50 end'],
                                  '', '', '', 'q');
    is($err, '', 'empty lines do not end the loop');
    like($out, qr/done\n\z/, 'the loop ends on its own sentinel instead');
}

# ---- input (as distinct from linput) was already correct; keep it that way ----
{
    my ($out, $err) = run_bounded(['10 input a$', '20 goto 10']);
    unlike($err, qr/SPUN/, 'input at end of input does not spin');
    like($err, qr/^Not enough input, add more \(line 10\)/,
         'input at end of input still reports the same condition');
}

# ---- reading from a real closed STDIN (no input hook) also ends ----
SKIP: {
    skip 'cannot reopen STDIN', 2 unless open my $devnull, '<', '/dev/null';
    my $prog = MBasic::Program->load_lines(['10 linput a$', '20 goto 10'], '(t)');
    MBasic::Linker->link_program($prog);
    my $writes = 0;
    my $ok = eval {
        local *STDIN = $devnull;
        MBasic::Executor->run_program($prog, out => sub {
            die "SPUN\n" if ++$writes > 5000;
        });
        1;
    };
    my $err = $ok ? '' : $@;
    unlike($err, qr/SPUN/, 'default STDIN reader does not spin at EOF either');
    like($err, qr/Not enough input/, 'and reports the same condition');
}

done_testing;
