use strict;
use warnings;
use Cwd qw(getcwd);
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $builddir = getcwd();

my $node = PostgreSQL::Test::Cluster->new('pg_disorder');
$node->init;
$node->append_conf('postgresql.conf', qq{
dynamic_library_path = '$builddir:\$libdir'
session_preload_libraries = 'pg_disorder'
});
$node->start;

sub ids
{
	my ($sql) = @_;
	my $out = $node->safe_psql('postgres', $sql);
	$out =~ s/\n/,/g;
	return $out;
}

$node->safe_psql('postgres', q{
	CREATE TABLE t (id int);
	INSERT INTO t SELECT generate_series(1, 30);
});
my $insertion = join(',', 1 .. 30);

is($node->safe_psql('postgres', 'SHOW pg_disorder.mode'),
	'off', 'loaded via session_preload_libraries; GUC present, default off');

is(ids('SELECT id FROM t'), $insertion,
	'off: unordered SELECT keeps insertion order');

my $enable = q{SET pg_disorder.mode = 'shuffle'; SET pg_disorder.seed = 42;};
my $shuffled = ids("$enable SELECT id FROM t");
isnt($shuffled, $insertion,
	'shuffle: unordered SELECT is shuffled off insertion order');

is(ids("$enable SELECT id FROM t"), $shuffled,
	'same seed reproduces the same permutation across sessions');

isnt(ids(q{SET pg_disorder.mode='shuffle'; SET pg_disorder.seed=777; SELECT id FROM t}),
	$shuffled, 'a different seed produces a different permutation');

is(ids("$enable SELECT id FROM t ORDER BY id"), $insertion,
	'explicit ORDER BY is never perturbed');

is($node->safe_psql('postgres', "$enable SELECT count(*) FROM t"),
	'30', 'shuffling preserves the row count');

# reverse mode: deterministic, no seed, exact reversal of insertion order.
my $reverse = q{SET pg_disorder.mode = 'reverse';};
my $reversed = join(',', reverse 1 .. 30);

is(ids("$reverse SELECT id FROM t"), $reversed,
	'reverse: unordered SELECT is returned in reversed insertion order');

is(ids("$reverse SELECT id FROM t"), ids("$reverse SELECT id FROM t"),
	'reverse is reproducible across sessions with no seed');

is(ids("$reverse SELECT id FROM t ORDER BY id"), $insertion,
	'reverse: explicit ORDER BY is never perturbed');

is($node->safe_psql('postgres', "$reverse SELECT count(*) FROM t"),
	'30', 'reverse preserves the row count');

$node->stop;
done_testing();
