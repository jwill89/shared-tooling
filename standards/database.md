# Database

How a project keeps its SQLite database: where it lives, connection settings, migrations, schema and queries.

Every project with a database uses SQLite. Snapshots, daily backups, restores and the database pull are in [deploy-and-ops.md](deploy-and-ops.md); the shared deploy module does them, and its [README](../deploy/pwsh/README.md) has the mechanics. Table and column names are in [naming.md](naming.md).

## Where it lives

- A service's database lives beside its binary, in `/opt/<app>/data`, which its unit lists in `ReadWritePaths`. [review]
- A PHP site's database sits outside its `public/` folder. [review]
- Anything that writes in the live database's folder (migrations, `sqlite3`, scripts, artisan, workers, the backup) runs as the database's own user (`runuser -u <user>`, `User=`), so every file it makes (`-wal`, `-shm`, copies) keeps that owner. The module does this for its snapshots, backups and pulls (`-Owner`). [review]
- The app and its migration tool open the database read-write but never create it, so a missing file (a mis-set data folder) is an error. [review]
- A new local database is an empty file made by hand, then migrated. [review]

## Connections

- modernc.org/sqlite is the one Go SQLite driver (see [packages.md](packages.md)). [review]
- Every connection runs WAL, `foreign_keys=ON`, `busy_timeout=5000` and `synchronous=NORMAL`. [test]
- In Go the pragmas travel in the DSN as `_pragma` parameters, so the driver applies them to every pooled connection. [test]
- A Go app opens two pools on the same file: a write pool of one connection, and a separate read pool. [review]
- Every write begins `IMMEDIATE` (`_txlock=immediate` on the write pool's DSN), so a writer waits out the busy timeout instead of failing. [test]
- Every multi-statement write runs in one transaction. [review]
- No network call is made while a write transaction is open: the outside service is asked before the transaction begins or after it commits. [review]
- On a system SQLite older than 3.46, statistics are refreshed with `PRAGMA analysis_limit=400; ANALYZE`, not `PRAGMA optimize`, which analyses far fewer tables there. [review]

## Migrations

- A Go app migrates with goose: numbered SQL files, and a Go migration only where the change needs logic. [review]
- goose files are numbered in sequence (`00001_`, `00002_`), not by timestamp, so each number fits in `PRAGMA user_version`. [review]
- Each migration also sets `PRAGMA user_version` to its own number, so `user_version` always equals goose's version and shows a schema's version at a glance; a test migrates a fresh database and checks the two agree. [test]
- A Laravel app uses Laravel's own migrations; any other PHP site uses Phinx (TarotGen.io is the model). [review]
- Migrations run in the deploy, never by hand. [review]
- A PHP site's deploy runs them after the pre-migration snapshot, as the database's user. [review]
- A Go service runs them at start, after the stop-time snapshot. [review]
- A failed migration puts the previous code back and prints the snapshot's restore command. [module]
- Migrations are append-only: one that has been merged or has run on production is never edited; add another. [review]
- A migration is idempotent and atomic: a second run changes nothing, and it runs in one transaction. A table rebuild is the one exception to the transaction. [review]
- Only pending migrations run, so a current database runs no migration queries. [review]
- Production never runs a down migration: undoing one means restoring the pre-deploy snapshot, so a migration that can't be undone says so (Phinx's `down()` throws). [review]
- A schema change keeps the old code working on the new schema: add beside, derive in the SELECT, no backfill. [review]
- An additive migration the new code needs runs before that code ships. [review]
- A column or table is dropped only in a release after the code stopped using it. [review]
- Dead tables and indexes, and the env vars only they used, are dropped once nothing references them; schema is made again when a design needs it, not kept just in case. [review]
- Seed rows a fresh database needs go in a migration, written `INSERT OR IGNORE`, so a re-run never overwrites a value changed since (a rotated password). [test]
- Each project commits its schema and has a schema test that fails when the migrations build anything else, so every schema change shows in review. [test]
- The committed schema is generated from the migrations on a throwaway database where the tool allows, and never edited by hand (TarotGen.io's `db/schema.sql` is the model). [review]
- After a migration on production, production's schema is compared object for object with a fresh build of the committed one. [review]

## Rebuilding a table

- A change `ALTER TABLE` can't make (to a CHECK, say) rebuilds the table by SQLite's documented procedure, with foreign keys off, since dropping a parent table with them on deletes its children's rows. [review]
  1. Turn foreign keys off (`PRAGMA foreign_keys=OFF`) outside the migration's transaction. In goose, mark the migration `-- +goose NO TRANSACTION` and run it on the write pool, so the pragma and the rebuild share its one connection.
  2. Begin a transaction.
  3. Create the new table under a new name.
  4. Copy the rows across, and roll back if the new table's row count differs from the old one's.
  5. Drop the old table and rename the new one to its name.
  6. Recreate the table's indexes and triggers.
  7. Run `PRAGMA foreign_key_check`, and roll back if it reports any rows.
  8. Set `PRAGMA user_version`, commit, and turn foreign keys back on.

## Changing production by hand

- A production database change outside the app's migrations (a hand migration, a bulk delete, `sqlite3` by hand) needs the owner's sign-off and never rides a routine deploy. [review]
- It starts with a manual backup, kept under a name the daily job won't prune. [review]
- Afterwards `PRAGMA integrity_check` returns ok and `PRAGMA foreign_key_check` returns nothing. [review]

## Queries

- Go SQL goes through sqlc: no ORM, reflection or query builder. [test]
- A test runs every query, since sqlc doesn't check a WHERE against a view. [test]
- A statement sqlc's SQLite parser can't read (FTS5, `VACUUM INTO`) is the exception, each recorded in `docs/decisions.md`. [review]
- A SELECT names exactly the columns it needs, never `*`. [review]
- Reads are batched into one query and writes into one transaction; an N+1 becomes a join, an index or a cache (see [performance.md](performance.md)). [review]
- A list query is index-backed and single-pass, with `COUNT(*) OVER()` for the total. [review]
- A paged query pages the main table on its index, then fetches related rows for that page only. [review]
- An index used for ordering ends with the ORDER BY's tie-breaker, such as `(created_at, id)`. [review]
- An index that is a prefix of another is dropped. [review]
- Each new index is checked with `EXPLAIN QUERY PLAN`. [review]
- A guard or duplicate check lives inside the write: in the SQL statement (`WHERE`, clamped with `MIN()`), or inside the write transaction that adds the row (insert first, then count), never as a read-then-write in application code. [review]
- A write that must hit a row checks the affected-row count and answers 404 when nothing matched. [test]
- A random id that hits its UNIQUE constraint retries with a fresh one, up to three times, for that constraint only. [test]

## Schema

- Money is an integer in its smallest unit. [review]
- Server time is authoritative: a timer works from server timestamps plus a measured clock offset. [review]
- A value that can be computed (a flag, a standing, an expiry) is computed when read, in the SELECT where possible, and never stored and kept in step. [review]
- Invariants that racing requests could break are enforced in the database and mirrored in the UI: foreign keys, CHECK constraints on enums and non-negative amounts, UNIQUE or partial UNIQUE indexes for one-of rules (`WHERE slug != ''` where `''` means none), and triggers as a backstop. [review]
- A freeze trigger compares `NEW.col IS NOT OLD.col`, since `UPDATE OF` fires whenever a statement names the column. [review]
- Child rows go with their parent through `ON DELETE CASCADE`, or `SET NULL` where the child must outlive it, never through deletes in code. [test]
- A link column with no enforced foreign key is cleared by the store when its target goes. [review]
- History outlives what it records: a record that history references is deactivated, not deleted, and can come back. [review]
- Log and history rows copy the names, prices and rates they show into columns that are never updated, and reference their parents `ON DELETE SET NULL`. [review]
- A write that affects money is audited with who made it. [review]
- A rowid SQLite may reuse never identifies anything that matters: an id in a public, cached address uses `AUTOINCREMENT`, a security check is keyed by the token's hash, and a public file name is random (26 characters from `crypto/rand`). [review]

## Timestamps

SQLite has no date type: whatever a column is declared, a timestamp or a date is stored as text, and text in one fixed RFC 3339 form sorts in time order. So it is stored, indexed, compared and sent in that one form ([README.md](README.md) on following RFCs). The declared type says what the column holds, and tells the Go driver to read a `DATETIME` or `DATE` column as a `time.Time`.

- A timestamp column is declared `DATETIME` and holds RFC 3339 in UTC, to the second: `2026-11-07T09:18:09Z`. [test]
- A date-only column is declared `DATE` and holds an RFC 3339 full-date, `2026-11-07`, which is what SQLite's `date()` writes. [test]
- A missing date or time is `NULL`, never an empty string, which is neither. [test]
- A project uses one precision for every timestamp: seconds, unless it needs sub-second order, and then milliseconds everywhere (`%fZ`, `2026-11-07T09:18:09.401Z`), since mixed precision sorts wrong. Read through Go, a millisecond value loses its trailing zeros (`.400Z` comes back `.4Z`), which is still RFC 3339. [review]
- Every timestamp column has `CHECK (col IS strftime('%Y-%m-%dT%H:%M:%SZ', col))`, which refuses SQLite's space form, an offset, fractional seconds and impossible dates, and every date-only column `CHECK (col IS date(col))`. They use `IS`, not `=`, because a CHECK whose result is NULL passes; a NULL in a nullable column still passes, as it should. [test]
- A column that defaults to now takes `DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))`. [review]
- `CURRENT_TIMESTAMP` and `datetime()` are never used for a stored value or a comparison: they write `2026-11-07 09:18:09`, and a space sorts before `T`, so a bound in that form counts the wrong rows. A bound comes from `strftime` in the column's form, or from the app as an RFC 3339 string. [review]
- Ordering and range queries compare the text, so an index on the column serves them. [review]
- Go writes a timestamp as a string, `t.UTC().Format(time.RFC3339)`, or leaves it to the column default; never as a `time.Time` parameter, which modernc writes in Go's own `String()` form, and which the CHECK refuses. [test]
- Go reads a `DATETIME` column into a `time.Time`, which `encoding/json` writes back in the same RFC 3339 form; read into a `string`, it comes back as the same text. [test]
- Go reads a `DATE` column into the project's `Date` type, never a `string` or a `time.Time`: the driver hands it over as midnight UTC, so a `string` gets `2026-11-07T00:00:00Z` and a `time.Time` is sent as a timestamp. [test]
- The `Date` type is a few lines in each Go project: `Scan` keeps only the day of the driver's `time.Time`, `Value` writes it as `2026-11-07`, `MarshalText` and `UnmarshalText` use `time.DateOnly`, and a huma `Schema` method gives `type: string, format: date`. [test]
- PHP writes the same form in UTC: `gmdate('Y-m-d\TH:i:s\Z')`, or in Laravel a model `$dateFormat` of `Y-m-d\TH:i:s\Z` with the app's zone set to UTC. [review]
- A timestamp leaves the API in the stored form. A reader in any language treats it as UTC. [test]
- An existing table moves in one migration: `UPDATE t SET col = strftime('%Y-%m-%dT%H:%M:%SZ', col)` (or `date(col)` for a date, and `NULL` where it held `''`), then a rebuild to declare the type and add the CHECK, since SQLite can't change either on an existing table (see [Rebuilding a table](#rebuilding-a-table)). [review]

## State in files

- A JSON file of persisted state is written atomically and git-ignored. [review]
- A key in it is never renamed outright: the old key stays as a field, its value moves over on load, then the file is saved. [review]
