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

is($node->safe_psql('postgres', 'SHOW pg_disorder.enabled'),
	'off', 'loaded via session_preload_libraries; GUC present, default off');

is(ids('SELECT id FROM t'), $insertion,
	'disabled: unordered SELECT keeps insertion order');

my $enable = 'SET pg_disorder.enabled = on; SET pg_disorder.seed = 42;';
my $shuffled = ids("$enable SELECT id FROM t");
isnt($shuffled, $insertion,
	'enabled: unordered SELECT is shuffled off insertion order');

is(ids("$enable SELECT id FROM t"), $shuffled,
	'same seed reproduces the same permutation across sessions');

isnt(ids('SET pg_disorder.enabled=on; SET pg_disorder.seed=777; SELECT id FROM t'),
	$shuffled, 'a different seed produces a different permutation');

is(ids("$enable SELECT id FROM t ORDER BY id"), $insertion,
	'explicit ORDER BY is never perturbed');

is($node->safe_psql('postgres', "$enable SELECT count(*) FROM t"),
	'30', 'shuffling preserves the row count');

$node->stop;
done_testing();
