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

-- DO and CALL reach the executor through ProcessUtility rather than
-- ExecutorRun, so their bodies must still be recognised as nested and left
-- unperturbed.  The second SELECT is the important one: eligibility is decided
-- at plan time and cached, so a body perturbed here would leave a poisoned plan
-- behind and keep returning the wrong row from ordinary nested calls too.
CREATE FUNCTION pg_disorder_first_id() RETURNS int AS $$
DECLARE v int;
BEGIN SELECT id INTO v FROM t LIMIT 1; RETURN v; END;
$$ LANGUAGE plpgsql;
DO $$ BEGIN RAISE NOTICE 'do block sees %', pg_disorder_first_id(); END $$;
SELECT pg_disorder_first_id() AS after_do_block;

CREATE PROCEDURE pg_disorder_scan_proc() AS $$
DECLARE c bigint := 0; r record;
BEGIN
  FOR r IN SELECT id FROM t LOOP c := c + 1; END LOOP;
  RAISE NOTICE 'call body scanned % rows, first id %', c, pg_disorder_first_id();
END;
$$ LANGUAGE plpgsql;
CALL pg_disorder_scan_proc();

-- ... while a utility statement that merely carries a query is still perturbed.
-- The read-back is an aggregate, so it is ineligible and reports the temp
-- table's physical order, which is the perturbed order the CTAS wrote: 20..1.
CREATE TEMP TABLE reverse_ctas AS SELECT id FROM t;
SELECT (array_agg(id))[1:3] AS ctas_wrote_reversed FROM reverse_ctas;

SELECT id FROM t LIMIT 5;
SELECT id FROM t FOR SHARE LIMIT 5;
SELECT * FROM (SELECT id FROM t FOR UPDATE) s LIMIT 5;
WITH locked AS (SELECT id FROM t FOR UPDATE) SELECT * FROM locked LIMIT 5;
SELECT id FROM (SELECT id FROM t) plain LIMIT 5;

CREATE FUNCTION pg_disorder_sql_exec_arg() RETURNS int LANGUAGE sql AS $$
  SELECT id FROM t LIMIT 1;
$$;
PREPARE pg_disorder_param(int) AS SELECT $1 AS v;
EXECUTE pg_disorder_param(pg_disorder_sql_exec_arg());
CREATE TEMP TABLE pg_disorder_ctas_exec AS
       EXECUTE pg_disorder_param(pg_disorder_sql_exec_arg());
SELECT v AS ctas_execute_param FROM pg_disorder_ctas_exec;
SELECT pg_disorder_sql_exec_arg() AS execute_param_left_no_poisoned_plan;
DEALLOCATE pg_disorder_param;
DROP FUNCTION pg_disorder_sql_exec_arg();

PREPARE pg_disorder_noparam AS SELECT id FROM t;
EXECUTE pg_disorder_noparam;
DEALLOCATE pg_disorder_noparam;

BEGIN;
DECLARE pg_disorder_cur CURSOR FOR SELECT id FROM t;
FETCH 3 FROM pg_disorder_cur;
COMMIT;
COPY (SELECT id FROM t LIMIT 3) TO stdout;

CREATE TEMP TABLE reverse_insert_select (id int);
INSERT INTO reverse_insert_select SELECT id FROM t;
SELECT (array_agg(id))[1:3] AS insert_select_kept_order FROM reverse_insert_select;

DO $$ BEGIN EXECUTE 'CREATE TEMP TABLE reverse_ctas_in_do AS SELECT id FROM t'; END $$;
SELECT (array_agg(id))[1:3] AS ctas_in_do_not_perturbed FROM reverse_ctas_in_do;

CREATE TABLE pg_disorder_trigger_log (v int);
CREATE FUNCTION pg_disorder_log_first_id() RETURNS trigger AS $$
DECLARE v int;
BEGIN
  SELECT id INTO v FROM t LIMIT 1;
  INSERT INTO pg_disorder_trigger_log VALUES (v);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TABLE pg_disorder_copy_target (x int);
CREATE TRIGGER pg_disorder_copy_trg BEFORE INSERT ON pg_disorder_copy_target
       FOR EACH ROW EXECUTE FUNCTION pg_disorder_log_first_id();
COPY pg_disorder_copy_target FROM stdin;
1
\.
SELECT v AS trigger_under_copy FROM pg_disorder_trigger_log;

TRUNCATE pg_disorder_trigger_log;
INSERT INTO pg_disorder_copy_target VALUES (2);
SELECT v AS trigger_under_insert FROM pg_disorder_trigger_log;

CREATE TABLE pg_disorder_deferred (x int);
CREATE CONSTRAINT TRIGGER pg_disorder_deferred_trg AFTER INSERT ON pg_disorder_deferred
       DEFERRABLE INITIALLY DEFERRED
       FOR EACH ROW EXECUTE FUNCTION pg_disorder_log_first_id();
TRUNCATE pg_disorder_trigger_log;
BEGIN;
INSERT INTO pg_disorder_deferred VALUES (1);
COMMIT;
SELECT v AS trigger_deferred_to_commit FROM pg_disorder_trigger_log;

CREATE PROCEDURE pg_disorder_commit_proc() AS $$
BEGIN
  INSERT INTO pg_disorder_deferred VALUES (2);
  COMMIT;
END;
$$ LANGUAGE plpgsql;
CALL pg_disorder_commit_proc();
SELECT count(*) AS committed_inside_procedure FROM pg_disorder_deferred;

CREATE FUNCTION pg_disorder_secdef_first_id() RETURNS int
       SECURITY DEFINER SET work_mem = '4MB' AS $$
DECLARE v int;
BEGIN SELECT id INTO v FROM t LIMIT 1; RETURN v; END;
$$ LANGUAGE plpgsql;
SELECT pg_disorder_secdef_first_id() AS security_definer_body;

CREATE FUNCTION pg_disorder_sql_immutable() RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT id FROM t LIMIT 1;
$$;
CREATE FUNCTION pg_disorder_sql_values() RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT x FROM (VALUES (1), (2), (3)) v(x) LIMIT 1;
$$;
SELECT pg_disorder_sql_immutable() AS sql_body_const_folded,
       pg_disorder_sql_values() AS sql_values_body_const_folded;
SELECT pg_disorder_sql_immutable() AS sql_body_const_folded_again,
       pg_disorder_sql_values() AS sql_values_body_const_folded_again;
DROP FUNCTION pg_disorder_sql_immutable();
DROP FUNCTION pg_disorder_sql_values();

CREATE FUNCTION pg_disorder_sql_first_id() RETURNS int LANGUAGE sql AS $$
  SELECT 1;
  SELECT id FROM t LIMIT 1;
$$;
CREATE TABLE pg_disorder_rewrite (a int);
INSERT INTO pg_disorder_rewrite VALUES (1);
ALTER TABLE pg_disorder_rewrite ADD COLUMN b int DEFAULT pg_disorder_sql_first_id();
SELECT b AS sql_function_under_table_rewrite FROM pg_disorder_rewrite;

CREATE TABLE pg_disorder_sql_default (a int, b int DEFAULT pg_disorder_sql_first_id());
COPY pg_disorder_sql_default (a) FROM stdin;
1
\.
SELECT b AS sql_function_under_copy_default FROM pg_disorder_sql_default;

DROP TABLE pg_disorder_rewrite;
DROP TABLE pg_disorder_sql_default;
DROP FUNCTION pg_disorder_sql_first_id();
DROP TABLE pg_disorder_copy_target;
DROP TABLE pg_disorder_deferred;
DROP TABLE pg_disorder_trigger_log;
DROP PROCEDURE pg_disorder_commit_proc();
DROP PROCEDURE pg_disorder_scan_proc();
DROP FUNCTION pg_disorder_log_first_id();
DROP FUNCTION pg_disorder_secdef_first_id();
DROP FUNCTION pg_disorder_first_id();
DROP FUNCTION pg_disorder_nested_scan();
DROP FUNCTION pg_disorder_simple_expr();
DROP TABLE t;
