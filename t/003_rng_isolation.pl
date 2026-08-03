use strict;
use warnings;
use Cwd qw(getcwd);
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $builddir = getcwd();

my $node = PostgreSQL::Test::Cluster->new('pg_disorder_rng');
$node->init;
$node->append_conf('postgresql.conf', qq{
dynamic_library_path = '$builddir:\$libdir'
session_preload_libraries = 'pg_disorder'
});
$node->start;

$node->safe_psql('postgres', q{
	CREATE TABLE t (id int);
	INSERT INTO t SELECT generate_series(1, 30);
});

my $shuffle = q{SET pg_disorder.mode = 'shuffle'; SET pg_disorder.seed = 42;};

my @r = split(/\n/, $node->safe_psql('postgres',
	"$shuffle SELECT random(); SELECT random(); SELECT random();"));

is(scalar @r, 3, 'three random() values came back');
isnt($r[0], $r[1],
	'shuffle does not freeze identical random() statements to one value');
isnt($r[1], $r[2],
	'shuffle leaves the session RNG advancing between statements');

is($node->safe_psql('postgres', "$shuffle SELECT setseed(0.5); SELECT random();"),
	$node->safe_psql('postgres', "SELECT setseed(0.5); SELECT random();"),
	'a user setseed() is honoured identically with shuffle on and off');

my $insertion = join("\n", 1 .. 30);
my $shuffled = $node->safe_psql('postgres', "$shuffle SELECT id FROM t");

isnt($shuffled, $insertion, 'shuffle still perturbs the row order');

is($node->safe_psql('postgres', "$shuffle SELECT id FROM t"), $shuffled,
	'shuffle is still reproducible from a pinned seed');

isnt($node->safe_psql('postgres',
		q{SET pg_disorder.mode='shuffle'; SET pg_disorder.seed=777; SELECT id FROM t}),
	$shuffled, 'a different seed still gives a different permutation');

$node->safe_psql('postgres', q{
	CREATE FUNCTION pg_disorder_ev() RETURNS event_trigger AS $$
	DECLARE v int;
	BEGIN
	  SELECT id INTO v FROM t LIMIT 1;
	  RAISE NOTICE 'event trigger first id %', v;
	END;
	$$ LANGUAGE plpgsql;
	CREATE EVENT TRIGGER pg_disorder_evt ON ddl_command_end
	       EXECUTE FUNCTION pg_disorder_ev();
});

my $stderr;
$node->psql('postgres',
	q{SET pg_disorder.mode = 'reverse'; CREATE TABLE evt_probe (x int);},
	stderr => \$stderr);
like($stderr, qr/event trigger first id 1$/m,
	'a plpgsql event trigger body is not perturbed');

$node->safe_psql('postgres', q{
	DROP EVENT TRIGGER pg_disorder_evt;
	DROP FUNCTION pg_disorder_ev();
});

$node->stop;
done_testing();
