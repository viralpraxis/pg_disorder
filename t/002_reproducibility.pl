use strict;
use warnings;
use Cwd qw(getcwd);
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $builddir = getcwd();

my $node = PostgreSQL::Test::Cluster->new('pg_disorder_repro');
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

# Output of the final statement only, for scripts that run several.
sub tail_ids
{
	my ($sql, $n) = @_;
	my @lines = split(/\n/, $node->safe_psql('postgres', $sql));
	return join(',', @lines[ -$n .. -1 ]);
}

$node->safe_psql('postgres', q{
	CREATE TABLE t (id int);
	INSERT INTO t SELECT generate_series(1, 30);
});
my $insertion = join(',', 1 .. 30);

my $enable = q{SET pg_disorder.mode = 'shuffle'; SET pg_disorder.seed = 42;};

# Five executions are enough for the plan cache to switch to a generic plan, so
# the sixth is served from the cache and never reaches the planner hook.
my $prime = q{
	PREPARE q AS SELECT id FROM t;
	EXECUTE q; EXECUTE q; EXECUTE q; EXECUTE q; EXECUTE q;
};

# The session starts on an auto-picked seed, so if the pin were ignored (as it
# is when the seed is only applied at plan time) each run would differ.
my $pin_after_prime = qq{
	SET pg_disorder.mode = 'shuffle';
	$prime
	SET pg_disorder.seed = 42;
	EXECUTE q;
};
my $pinned = tail_ids($pin_after_prime, 30);

isnt($pinned, $insertion,
	'statement served from the plan cache is still shuffled');

is(tail_ids($pin_after_prime, 30), $pinned,
	'pinned seed is honoured by a statement served from the plan cache');

# Changing pg_disorder.mode has to invalidate cached plans, in both
# directions, or the change silently does nothing for the rest of the session.
isnt(tail_ids(qq{
	SET pg_disorder.seed = 42;
	$prime
	SET pg_disorder.mode = 'shuffle';
	EXECUTE q;
}, 30), $insertion, 'enabling after a generic plan is cached takes effect');

is(tail_ids(qq{
	SET pg_disorder.mode = 'shuffle'; SET pg_disorder.seed = 42;
	$prime
	SET pg_disorder.mode = 'off';
	EXECUTE q;
}, 30), $insertion, 'disabling after a generic plan is cached takes effect');

# A statement's permutation must not depend on what the session ran before it,
# otherwise the failing test can only be replayed by replaying the whole suite.
# The seed is derived from the query text, so both scripts have to submit the
# target statement byte for byte identically.
my $target = "SELECT id FROM t;";
my $history = "SELECT id FROM t WHERE id <= 5;\nSELECT id FROM t WHERE id <= 5;\n";

is(tail_ids("$enable\n$history$target", 30), tail_ids("$enable\n$target", 30),
	'a statement replays identically regardless of session history');

# random() is only parallel-restricted, so without pg_disorder.force_serial the
# injected Sort sits above a Gather and takes its input in worker-arrival order.
$node->safe_psql('postgres', q{
	CREATE TABLE big (id int);
	INSERT INTO big SELECT generate_series(1, 5000);
	ANALYZE big;
});

my $parallel = q{
	SET pg_disorder.mode = 'shuffle'; SET pg_disorder.seed = 42;
	SET parallel_setup_cost = 0; SET parallel_tuple_cost = 0;
	SET min_parallel_table_scan_size = 0;
	SET max_parallel_workers_per_gather = 4;
};

like($node->safe_psql('postgres',
		"$parallel SET pg_disorder.force_serial = off;
		 EXPLAIN (COSTS OFF) SELECT id FROM big"),
	qr/Gather/,
	'the shuffled query really would go parallel on its own');

unlike($node->safe_psql('postgres',
		"$parallel EXPLAIN (COSTS OFF) SELECT id FROM big"),
	qr/Gather/,
	'force_serial keeps a shuffled query serial');

is(ids("$parallel SELECT id FROM big"), ids("$parallel SELECT id FROM big"),
	'a pinned seed reproduces across sessions with parallelism available');

$node->stop;
done_testing();
