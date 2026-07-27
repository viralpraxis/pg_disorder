<h1 align="center">
  <img src="assets/logo.png" alt="pg_disorder" width="440">
</h1>

`pg_disorder` is a tiny PostgreSQL shared library that, when active, perturbs the row order of every eligible top-level `SELECT` that has no `ORDER BY` -- either by reversing it (deterministic) or by injecting `ORDER BY random()` (shuffled).

SQL does not specify the order of rows returned by a `SELECT` without an `ORDER BY`.
In practice PostgreSQL usually hands them back in insertion/physical order, so test suites quietly accumulate assumptions like "the first row is the one I inserted first."

> [!WARNING]
> `pg_disorder` is not intended for use in production. Do not load it via the global `shared_preload_libraries` configuration option.

## Prior art

- SQLite ships the [`reverse_unordered_selects`](https://sqlite.org/pragma.html#pragma_reverse_unordered_selects) pragma.
- ClickHouse ships the [`inject_random_order_for_select_without_order_by`](https://clickhouse.com/docs/operations/settings/settings#inject_random_order_for_select_without_order_by) session setting.

## Installation

All non-EOL PostgreSQL versions are supported.

Build against the *same major version* your server runs.

1. Prerequisites: a C compiler, `make`, and the PostgreSQL server headers:

   ```sh
   # Debian
   sudo apt install build-essential postgresql-server-dev-17

   # RHEL / Fedora
   sudo dnf install gcc make postgresql17-devel

   # macOS
   brew install postgresql@17
   ```

2. Build and install:

   ```sh
   make
   sudo make install
   ```

3. Enable it:

   Load it for every session on your test database, and turn it on:

   ```sql
   ALTER DATABASE <database-name> SET session_preload_libraries = 'pg_disorder';
   ALTER DATABASE <database-name> SET pg_disorder.mode = 'reverse';
   ```

## Modes

| Mode | Deterministic? | Seed? | Use it for |
|------|----------------|-------|------------|
| `reverse` | yes | no | CI. Reverses the row order, so a test that assumes insertion/physical order fails immediately, reproducibly, with nothing to configure. |
| `shuffle` | no (per run) | yes | Broader exploration. Injects `ORDER BY random()`, sampling a different permutation each run -- catches order assumptions reverse's single flip happens to satisfy. |

`reverse` is the better default: it is free of the seed apparatus and can never accidentally pass on the dominant bug, since the reverse of insertion order is never insertion order. Reach for `shuffle` in longer soak runs where you want to sample the whole order space rather than one point in it.

## Configuration

| GUC | Type | Default | Meaning |
|-----|------|---------|---------|
| `pg_disorder.mode` | enum | `off` | Master switch: `off`, `reverse`, or `shuffle`. |
| `pg_disorder.seed` | int | `0` | Shuffle-only reproducibility seed. `0` picks a random seed once per session and logs it. Any non-zero value is used as-is. Ignored in `reverse` mode. |
| `pg_disorder.force_serial` | bool | `on` | Plans perturbed queries serially. The injected sort key is parallel-restricted, so a parallel plan feeds the sort in worker-arrival order and the same input yields a different row order every run -- defeating both a pinned seed and reverse's determinism. Turning this off restores parallelism and gives that up. |
| `pg_disorder.version` | string | `0.1.0` | Read-only; the version of the loaded module. Cannot be set, and is rejected in `postgresql.conf`. |

`SHOW pg_disorder.version` is also the dependable way to confirm the library is really loaded on a connection. `SHOW pg_disorder.mode` is not: on a connection that never loaded the library, PostgreSQL accepts `pg_disorder.mode` as a placeholder, so `SET` reports success and `SHOW` echoes the value back while nothing is being perturbed. The version GUC fails with `unrecognized configuration parameter` in that case instead of quietly agreeing with you.

## Reproducing a failure

`reverse` mode is deterministic -- the same query on the same data always returns the same reversed order, with no seed to manage. The rest of this section applies to `shuffle` mode.

The run's seed is written to the server log:

```
LOG:  pg_disorder 0.1.0: session seed = 168799893 (replay with SET pg_disorder.seed = 168799893)
```

Replay that exact ordering by pinning the seed:

```sql
SET pg_disorder.seed = 168799893;
```

Every statement derives its own seed from `pg_disorder.seed` and its query text, so replaying just the statement that failed reproduces its row order -- you do not have to replay the whole session in the same order.

A permutation is a function of the seed, the query text as submitted, and the plan. Reformatting the query changes it, and so does anything that changes the plan or the order rows reach the sort, such as a `VACUUM` or fresh statistics.

## What gets perturbed

Only a top-level `SELECT` with no `ORDER BY`. This is the same set in both modes.

### Not perturbed yet

These shapes are currently passed through untouched, in both `reverse` and `shuffle` modes:

- `GROUP BY`, grouping sets, and aggregates
- `DISTINCT` and `DISTINCT ON`
- `UNION`, `INTERSECT`, `EXCEPT`
- window functions

## How it works

pg_disorder installs a `planner_hook`. For each eligible query it appends one extra hidden column to the target list -- `random()` in `shuffle` mode, `row_number() OVER ()` in `reverse` mode -- and adds an `ORDER BY` on it: ascending for shuffle, descending for reverse. PostgreSQL then plans and runs the query as usual, so the only change is the row order; the hidden column is dropped before rows are returned. With `force_serial` on, the hook also clears the query's parallel flag, so the sort receives its input in a deterministic order.

## Real-world findings

- [Ruby on Rails](https://github.com/rails/rails): [Bug #58177](https://github.com/rails/rails/pull/58177)

## Testing

```sh
# pg_regress (deterministic invariants + reverse) + TAP (shuffle & reproducibility)
make installcheck
```

## License

[PostgreSQL License](LICENSE).
