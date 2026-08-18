<h1 align="center">
  <img src="https://raw.githubusercontent.com/viralpraxis/pg_disorder/main/assets/logo.png" alt="pg_disorder" width="440">
</h1>

`pg_disorder` is a tiny PostgreSQL shared library that, when active, perturbs the row order of every eligible top-level `SELECT` that has no `ORDER BY`, either by reversing it (deterministic) or by applying a seeded pseudorandom permutation (shuffled).

SQL does not specify the order of rows returned by a `SELECT` without an `ORDER BY`.
In practice PostgreSQL usually hands them back in insertion/physical order, so test suites accumulate assumptions like "the first row is the one I inserted first."

> [!WARNING]
> `pg_disorder` is not intended for use in production. Do not load it via the global `shared_preload_libraries` configuration option.

## Prior art

- SQLite ships the [`reverse_unordered_selects`](https://sqlite.org/pragma.html#pragma_reverse_unordered_selects) pragma.
- ClickHouse ships the [`inject_random_order_for_select_without_order_by`](https://clickhouse.com/docs/operations/settings/settings#inject_random_order_for_select_without_order_by) session setting.
- [PostgreSQL mailing list discussion](https://www.postgresql.org/message-id/dac9b505-56d2-c852-805b-e1c902de113e%40BlueTreble.com)

## Installation

All non-EOL PostgreSQL versions are supported.

Build against the *same major version* your server runs.

### From PGXN

With the [PGXN client](https://pgxn.github.io/pgxnclient/):

```sh
pgxn install pg_disorder
```

`pgxn install` builds from source, so it needs the same prerequisites as below. It shells out to `sudo` for the install step, and picks the server to build against from the first `pg_config` on your `PATH`; pass `--pg_config /path/to/pg_config` when you have several major versions installed.

### From source

1. Prerequisites: a C compiler, `make`, and the PostgreSQL server headers:

   ```sh
   # Debian
   $ apt install build-essential postgresql-server-dev-17

   # RHEL / Fedora
   $ dnf install gcc make postgresql17-devel

   # macOS
   $ brew install postgresql@17
   ```

2. Build and install:

   ```sh
   $ make
   $ make install
   ```

### Enable it

Load it for every session on your test database, and turn it on:

```sql
ALTER DATABASE <database-name> SET session_preload_libraries = 'pg_disorder';
ALTER DATABASE <database-name> SET pg_disorder.mode = 'reverse';
```

To check if it is loaded:

```sql
SHOW pg_disorder.version;
```

## Modes

| Mode | Deterministic? | Seed? | Use it for |
|------|----------------|-------|------------|
| `reverse` | yes | no | CI. Reverses the row order, so a test that assumes insertion/physical order fails immediately and reproducibly, with nothing to configure. |
| `shuffle` | no (per session) | yes | Broader exploration. Applies a seeded pseudorandom permutation, sampling a different order in each session. Catches order assumptions that reverse's single flip happens to satisfy. |

`reverse` is the better default: there is no seed to manage, and it is the single permutation most likely to break the common case of a test that assumes rows arrive in insertion order. Use `shuffle` in longer soak runs, where several seeds cover more of the order space.

`reverse` is not a guarantee, though. It reverses the order the *plan* emits, which is usually but not always insertion order. If the plan's natural output is already descending (say it reads a `DESC` index), reversing hands back ascending, which is what an insertion-order assumption wants, and the test passes:

```sql
CREATE INDEX ord_desc ON ord (id DESC);   -- plan emits 10..1
SET pg_disorder.mode = 'reverse';
SELECT id FROM ord;                       -- 1..10, assumption survives
```

Neither mode can prove a test is order-independent; `shuffle` across several seeds is the stronger check.

`shuffle` samples one permutation *per session*, not per execution. A statement's permutation is a function of the seed and the query text, so running the same statement twice in one session returns the same order both times, and a failure is replayable from the seed alone. To sample more of the order space, vary the seed across runs rather than repeating a statement within one.

## Configuration

| GUC | Type | Default | Meaning |
|-----|------|---------|---------|
| `pg_disorder.mode` | enum | `off` | Master switch: `off`, `reverse`, or `shuffle`. |
| `pg_disorder.seed` | int | `0` | Shuffle-only reproducibility seed. `0` picks a random seed once per session and logs it. Any non-zero value is used as-is. Ignored in `reverse` mode. |
| `pg_disorder.force_serial` | bool | `on` | Plans perturbed queries serially. The injected sort key is built on a window function, which is parallel-restricted, so a parallel plan feeds it in worker-arrival order and the same input yields a different row order every run, defeating both a pinned seed and reverse's determinism. Turning this off restores parallelism and gives that up. |
| `pg_disorder.version` | string | `0.1.0` | Read-only; the version of the loaded module. |

## Reproducing a failure

`reverse` mode is deterministic: the same query on the same data and the same plan always returns the same reversed order, with no seed to manage. Anything that changes the plan, such as a `VACUUM` or fresh statistics, can change the order it reverses. The rest of this section applies to `shuffle` mode.

The run's seed is written to the server log:

```
LOG:  pg_disorder 0.1.0: session seed = 168799893 (replay with SET pg_disorder.seed = 168799893)
```

Replay that exact ordering by pinning the seed:

```sql
SET pg_disorder.seed = 168799893;
```

Every statement derives its own seed from `pg_disorder.seed` and its query text, so replaying just the statement that failed reproduces its row order; you do not have to replay the whole session in the same order.

A permutation is a function of the seed, the query text as submitted, and the plan. Reformatting the query changes it, and so does anything that changes the plan or the order rows reach the sort, such as a `VACUUM` or fresh statistics.

"As submitted" is literal. PostgreSQL gives every statement in a single multi-statement message the *whole* message as its query text, so `SELECT 1; SELECT id FROM t` seeds that second statement differently than the same statement sent on its own, as does a stray trailing semicolon. `psql` sends statements one at a time, so an interactive or `-f` replay is faithful; a batch sent as one message (`psql -c "a; b"`, a `PQexec` batch, a driver that pipelines, some migration runners) is not. If a replay comes back with an unexpected order, resubmit the statement exactly as the failing client sent it.

## What gets perturbed

Only a top-level `SELECT` with no `ORDER BY`. This is the same set in both modes.

"Top-level" means the statement you submitted. Queries planned inside a function, procedure, trigger, event trigger or `DO` block are never perturbed, no matter what fired them.

### Not perturbed yet

These shapes are currently passed through untouched, in both `reverse` and `shuffle` modes:

- `GROUP BY`, grouping sets, and aggregates
- `DISTINCT` and `DISTINCT ON`
- `UNION`, `INTERSECT`, `EXCEPT`
- window functions
- `SELECT`s with no `FROM` clause
- `WITH RECURSIVE`. The injected sort is a blocking operator, so it must drain its input before returning a row. A recursive CTE is allowed to be infinite when a `LIMIT` stops it (PostgreSQL's own test suite contains one), and perturbing that turns a query that returns in under a millisecond into one that never returns and fills the disk with temporary files.
- `FOR UPDATE`, `FOR NO KEY UPDATE`, `FOR SHARE`, `FOR KEY SHARE`, wherever they appear in the query, including inside a subquery or CTE. Reordering a locking scan reorders lock acquisition, which can create deadlocks that have nothing to do with the order assumption under test; and because the injected sort is blocking, a `LIMIT` would no longer stop it before it locked every row.
- anything that is not a `SELECT`, including `INSERT ... SELECT`. Note the asymmetry with `CREATE TABLE AS SELECT`, which *is* perturbed: a fixture loaded with `INSERT ... SELECT` keeps its source order, the same fixture loaded with `CREATE TABLE AS` does not.

## Real-world findings

- Ruby on Rails: [bug #58177](https://github.com/rails/rails/pull/58177), [suite flaky tests](https://github.com/rails/rails/pull/58267)
- Django: [suite flaky tests](https://github.com/django/django/pull/21745)
- gitea: [bug #38850](https://github.com/go-gitea/gitea/pull/38850)

## How it works

For the `shuffle` mode, we inject a "resjunk" column with PRNG-double values and add an `ORDER BY` clause for this column to the planner. That hidden column is automatically pruned before being sent to a client

## Testing

```sh
# pg_regress (deterministic invariants + reverse) + TAP (shuffle & reproducibility)
make installcheck
```

## License

[PostgreSQL License](LICENSE).
