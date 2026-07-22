<h1 align="center">
  <img src="assets/logo.png" alt="pg_disorder" width="440">
</h1>

`pg_disorder` is a tiny PostgreSQL shared library that, when enabled, injects `ORDER BY random()` into every eligible top-level `SELECT` that has no `ORDER BY`.

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
   ALTER DATABASE <database-name> SET pg_disorder.enabled = on;
   ALTER DATABASE <database-name> SET pg_disorder.seed = 42;
   ```

## Configuration

| GUC | Type | Default | Meaning |
|-----|------|---------|---------|
| `pg_disorder.enabled` | bool | `off` | Master switch. |
| `pg_disorder.seed` | int | `0` | Reproducibility seed. `0` picks a random seed once per session and logs it. Any non-zero value is used as-is. |
| `pg_disorder.force_serial` | bool | `on` | Plans shuffled queries serially. `random()` is only parallel-restricted, so a parallel plan sorts rows in worker-arrival order and the same seed yields a different permutation on every run. Turning this off restores parallelism and gives up reproducibility. |

## Reproducing a failure

The run's seed is written to the server log:

```
LOG:  pg_disorder 0.1.0: session seed = 168799893 (replay with SET pg_disorder.seed = 168799893)
```

Replay that exact ordering by pinning the seed:

```sql
SET pg_disorder.seed = 168799893;
```

Every statement derives its own seed from `pg_disorder.seed` and its query text, so replaying just the statement that failed reproduces its row order — you do not have to replay the whole session in the same order.

A permutation is a function of the seed, the query text as submitted, and the plan. Reformatting the query changes it, and so does anything that changes the plan or the order rows reach the sort, such as a `VACUUM` or fresh statistics.

## What gets shuffled

Only a top-level `SELECT` with no `ORDER BY`.

### Not shuffled yet

These shapes are currently passed through untouched:

- `GROUP BY`, grouping sets, and aggregates
- `DISTINCT` and `DISTINCT ON`
- `UNION`, `INTERSECT`, `EXCEPT`
- window functions

## Testing

```sh
# pg_regress (deterministic invariants) + TAP (shuffle & reproducibility)
make installcheck
```

## License

[PostgreSQL License](LICENSE).
