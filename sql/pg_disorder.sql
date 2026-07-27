LOAD 'pg_disorder';

SHOW pg_disorder.mode;
SHOW pg_disorder.seed;

CREATE TABLE t (id int, name text);
INSERT INTO t SELECT g, 'row' || g FROM generate_series(1, 20) g;

SET pg_disorder.mode = 'shuffle';
SET pg_disorder.seed = 12345;

SELECT string_agg(id::text, ',' ORDER BY id) AS ordered_ids FROM t;
SELECT id FROM t ORDER BY id DESC LIMIT 3;

CREATE TEMP TABLE cap AS SELECT id FROM t;
SELECT array_agg(id ORDER BY id) AS multiset_preserved FROM cap;
SELECT count(*) AS n_rows FROM cap;

SET max_parallel_workers_per_gather = 0;
CREATE TEMP TABLE shuffle_proof AS SELECT id FROM t;
SELECT (SELECT array_agg(id) FROM shuffle_proof)
       IS DISTINCT FROM
       (SELECT array_agg(id ORDER BY id) FROM t) AS shuffle_happened;

CREATE TEMP TABLE cap5 AS SELECT id FROM t LIMIT 5;
SELECT count(*) AS limited FROM cap5;

SELECT DISTINCT id FROM t WHERE id <= 3 ORDER BY id;
SELECT count(*) AS union_rows FROM (SELECT id FROM t UNION SELECT id FROM t) u;
SELECT count(*) AS grouped_rows FROM (SELECT id FROM t GROUP BY id) g;
SELECT count(*) AS total FROM t;
SELECT id FROM t WHERE false;

CREATE TEMP TABLE t_ins (id int);
INSERT INTO t_ins SELECT id FROM t;
SELECT count(*) AS inserted FROM t_ins;

CREATE FUNCTION pg_disorder_simple_expr() RETURNS int AS $$
DECLARE n int := 42;
BEGIN RETURN n; END;
$$ LANGUAGE plpgsql;
SELECT pg_disorder_simple_expr() AS simple_expr;

CREATE FUNCTION pg_disorder_nested_scan() RETURNS bigint AS $$
DECLARE c bigint := 0; r record;
BEGIN
  FOR r IN SELECT id FROM t LOOP c := c + 1; END LOOP;
  RETURN c;
END;
$$ LANGUAGE plpgsql;
SELECT pg_disorder_nested_scan() AS nested_rows;

-- reverse mode is deterministic, so unlike shuffle its exact row order can be
-- asserted.  On a freshly loaded table the physical scan order is the insertion
-- order, so a top-level unordered scan comes back reversed: 20..1.  (This must
-- be a bare top-level SELECT: wrapping it in an aggregate or a subquery would
-- make it ineligible and it would not be perturbed at all.)
SET pg_disorder.mode = 'reverse';
SELECT id FROM t;
-- an explicit ORDER BY is still not perturbed
SELECT id FROM t ORDER BY id LIMIT 3;
-- the row count is preserved
SELECT count(*) AS reverse_total FROM t;
-- an excluded shape still returns the full correct result under reverse
SELECT array_agg(id ORDER BY id) AS grouped_multiset
       FROM (SELECT id FROM t WHERE id <= 5 GROUP BY id) g;

DROP TABLE t;
