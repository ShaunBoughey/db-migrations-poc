# Flyway Migration POC — Testing Guide (Windows)

A local Docker Compose setup that exercises Flyway against a Postgres DB with pre-existing "legacy" schema. Master and client scripts share a **single history table**; ordering is enforced by the version numbers themselves (master scripts get a `.1` suffix, client scripts get a `.2` suffix, so within any logical release master always sorts before client).

## What this POC proves

- Flyway can be introduced against a DB that already contains objects, without touching them (baseline).
- Master scripts always run before client scripts within a release — enforced by Flyway's version sort, not shell chaining.
- A single `flyway_schema_history` table holds the full audit trail.
- Strict version ordering is enforced — a script with a version below the current schema version causes validation to fail.
- Transactional DDL on Postgres rolls back a bad migration cleanly.
- Re-running with no script changes is a no-op.

## Prerequisites

- **Windows 10/11** with **Docker Desktop** running.
- **PowerShell** (commands below assume PowerShell 5 or 7).
- A local clone of this repo. All commands below are run from the **repo root** — open a PowerShell there with `cd <your-clone-path>`.
- Port `5432` free on the host.

Verify Docker is up:

```powershell
docker version
docker compose version
```

## Repository layout

```
<repo-root>\
├── docker-compose.yml
├── Dockerfile
├── legacy\
│   └── 00_legacy_schema.sql    # Pre-Flyway objects (simulates existing GCP schema)
└── scripts\
    ├── master\
    │   ├── master_2026.1.1.sql
    │   ├── master_2026.2.1.sql
    │   └── master_2026.5.1.sql
    └── client\
        ├── client_2026.1.1.sql
        ├── client_2026.3.1.sql
        └── client_2026.5.1.sql
```

Devs author scripts with simple names (`master_X.Y.Z.sql` / `client_X.Y.Z.sql`). The Dockerfile transforms them at build time:

| Dev writes | Physical name in image | Version | Description in history |
|---|---|---|---|
| `master_2026.1.1.sql` | `V2026.1.1.1__master_2026.1.1.sql` | `2026.1.1.1` | `master 2026.1.1` |
| `client_2026.1.1.sql` | `V2026.1.1.2__client_2026.1.1.sql` | `2026.1.1.2` | `client 2026.1.1` |

The `.1` / `.2` suffix on the physical version is invisible to devs — they write `master_2026.1.1.sql` and, when inspecting the history table, see a `description` column that clearly says `master 2026.1.1` / `client 2026.1.1` next to the physical version.

## Quick start

From the repo root in PowerShell:

```powershell
docker compose up --build migrator
```

On first run this will:

1. Spin up Postgres 15 and load `legacy\00_legacy_schema.sql` into it.
2. Build the migrator image, renaming the 6 sample scripts with team suffixes.
3. Run a single `flyway info migrate` — baselines `flyway_schema_history` at `2026.0.0`, then applies all pending scripts in strict version order.
4. Exit 0.

Inspect the result:

```powershell
docker compose exec db psql -U user -d poc_db -c "\dt" `
  -c "SELECT installed_rank, version, description, type, success FROM flyway_schema_history ORDER BY installed_rank;" `
  -c "SELECT * FROM legacy_accounts;"
```

You should see:

- 7 tables: the 4 Flyway-managed (`m_users`, `m_orders`, `c_profile`, `c_prefs`), 2 legacy (`legacy_accounts`, `legacy_settings`), 1 history (`flyway_schema_history`).
- The history table begins with a `BASELINE` row at `2026.0.0`, then 6 `SQL` rows with descriptions like `master 2026.1.1`, `client 2026.1.1`, `master 2026.2.1` etc. Note how `2026.1.1.1` (master) sorts before `2026.1.1.2` (client) — master-before-client is intrinsic to the version order.
- `legacy_accounts` still contains its 2 seed rows — **Flyway did not touch it.**

## Connecting from pgAdmin / DBeaver / psql

The DB is exposed on `localhost:5432`:

- **Host:** `localhost`
- **Port:** `5432`
- **Database:** `poc_db`
- **User:** `user`
- **Password:** `password`

## Step by step of the migrations

Run each step, inspect the output before continuing. Allowing you to see how this is working under the hood.

### Step 1 — Clean slate

```powershell
docker compose down -v
```

Wipes the `pgdata` volume so the next `up` re-loads the legacy schema.

### Step 2 — Build and inspect the image

```powershell
docker compose build migrator
docker compose run --rm --entrypoint sh migrator -c "ls -la /flyway/sql"
```

Expect 6 files named like `V2026.1.1.1__master_2026.1.1.sql`, `V2026.1.1.2__client_2026.1.1.sql`, etc. All in one directory.

### Step 3 — Start Postgres alone and load legacy schema

```powershell
docker compose up -d db
docker compose exec db psql -U user -d poc_db -c "\dt" -c "SELECT * FROM legacy_accounts;"
```

Expect `legacy_accounts` and `legacy_settings` to exist with seed data. **No Flyway history table yet.**

### Step 4 — Dry-run (see what Flyway would do)

```powershell
docker compose run --rm migrator info
```

Expect a table of 6 `Pending` migrations, in version order, with descriptions: `master 2026.1.1`, `client 2026.1.1`, `master 2026.2.1`, `client 2026.3.1`, `master 2026.5.1`, `client 2026.5.1`.

### Step 5 — First migrate

```powershell
docker compose up --build migrator
```

Watch the output. Flyway baselines at `2026.0.0`, then applies the 6 scripts in strict version order. Exit 0.

Inspect:

```powershell
docker compose exec db psql -U user -d poc_db -c "\dt" `
  -c "SELECT installed_rank, version, description, type FROM flyway_schema_history ORDER BY installed_rank;"
```

### Step 6 — Idempotency check

```powershell
docker compose up --build migrator
```

Expect `Schema "public" is up to date. No migration necessary.` Exit 0.

### Step 7 — Incremental upgrade (valid, strictly higher version)

Only add scripts **above** the current max (`2026.5.1`). Create a `2026.6.1` master script:

```powershell
Set-Content -Path .\scripts\master\master_2026.6.1.sql `
  -Value 'ALTER TABLE m_users ADD COLUMN created_at timestamptz DEFAULT now();' -Encoding ascii
docker compose up --build migrator
```

Expect Flyway applies one new script: `V2026.6.1.1__master_2026.6.1.sql` (description `master 2026.6.1`).

Inspect:

```powershell
docker compose exec db psql -U user -d poc_db -c "\d m_users" `
  -c "SELECT installed_rank, version, description FROM flyway_schema_history ORDER BY installed_rank;"
```

`m_users` should now have a `created_at` column.

### Step 8 — Prove strict mode blocks a gap-filler

Drop a script with a version **below** the current max — simulates a developer submitting a late script:

```powershell
Set-Content -Path .\scripts\client\client_2026.4.1.sql `
  -Value 'CREATE TABLE c_audit (id serial PRIMARY KEY);' -Encoding ascii
docker compose up --build migrator
```

Expect Flyway to **fail validation**:

```
ERROR: Validate failed: Migrations have failed validation
Detected resolved migration not applied to database: 2026.4.1.2.
```

Exit 1. This is the **production safety net** — gap-fillers are rejected.

Clean up:

```powershell
Remove-Item .\scripts\client\client_2026.4.1.sql
```

### Step 9 — Prove a broken script halts the run (nothing after it applies)

```powershell
Set-Content -Path .\scripts\master\master_2026.7.1.sql `
  -Value 'SELECT this_is_invalid_sql;' -Encoding ascii
Set-Content -Path .\scripts\client\client_2026.7.1.sql `
  -Value 'CREATE TABLE c_should_never_exist (id serial PRIMARY KEY);' -Encoding ascii
docker compose up --build migrator
```

Expect `V2026.7.1.1__master_2026.7.1.sql` to fail (Postgres error `42703`), Flyway aborts. The client script `V2026.7.1.2__client_2026.7.1.sql` is never reached — Flyway processes in version order, and a failure halts all subsequent work. The failing master statement is rolled back in its transaction, so the DB is in its last-good state. Table `c_should_never_exist` does NOT exist.

Verify client didn't run:

```powershell
docker compose exec db psql -U user -d poc_db -c "\dt c_should_never_exist"
```

Expect "Did not find any relation named..."

Clean up:

```powershell
Remove-Item .\scripts\master\master_2026.7.1.sql
Remove-Item .\scripts\client\client_2026.7.1.sql
```

On Postgres, a failed migration is rolled back transactionally and leaves **no row** in the history table, so no `repair` is needed. Re-run to confirm recovery:

```powershell
docker compose up --build migrator
```

Should be a no-op.

### Step 10 — Full teardown

```powershell
docker compose down -v
```

Wipes containers, network, and the `pgdata` volume. Next `up` starts from a virgin DB + legacy schema reload.

## Gotchas / troubleshooting

### Failed migration recovery

On Postgres (transactional DDL), a failed migration rolls back cleanly and leaves no row behind — just fix the SQL and re-run. `flyway repair` is only needed for edge cases like checksum mismatches (someone edited an already-applied file), aborted migrator processes, or non-transactional DDL operations. Run as:

```powershell
docker compose run --rm migrator repair
```

For the POC, the nuclear option is always `docker compose down -v`.

### Schema version displayed in history table seems out of order

`installed_rank` is the **chronological order** of application, not the version order. The UI tool (pgAdmin, DBeaver) may sort by `version` and hide this. Always sort by `installed_rank` to see the real timeline.

### Why do versions look like `2026.1.1.1`?

The last digit is a team suffix applied by the Dockerfile: `.1` for master, `.2` for client. It gives each team its own unique version so both can share one history table, and guarantees master sorts before client within each logical release (`2026.1.1`). Devs don't write it — the build adds it.

To make the history table immediately readable, the Dockerfile also puts the logical release into the Flyway **description**: a row with version `2026.2.1.1` has description `master 2026.2.1`, and version `2026.3.1.2` has description `client 2026.3.1`. No mental math needed.

## Key configuration items

See `docker-compose.yml` for the full set. Highlights:

| Env var | Value | Why |
|---|---|---|
| `FLYWAY_BASELINE_ON_MIGRATE` | `true` | First run against a non-empty DB writes a BASELINE row instead of erroring. **Flip to `false` in production after initial cutover.** |
| `FLYWAY_BASELINE_VERSION` | `2026.0.0` | Anything ≤ this version is considered "already in place" and won't be applied. All our scripts start at `2026.1.1.1`. |
| `FLYWAY_OUT_OF_ORDER` | `false` | Strict ordering. A late-arriving script below the current max causes validation to fail — this is what we want. |
| `FLYWAY_LOCATIONS` | `filesystem:/flyway/sql` | Where Flyway looks for migration scripts inside the image. |

## Cloud Run / production notes

The built image is self-contained. To deploy as a Cloud Run Job:

- **Container image** — your Artifact Registry URL for this image.
- **Environment** — same env vars as `docker-compose.yml`, with `FLYWAY_PASSWORD` sourced from Secret Manager.
- **No command override, no args** — the image's default `CMD` is `["info", "migrate"]`.
- Exit 0 → Cloud Run marks execution succeeded; non-zero → failed.

Ordering is guaranteed by the version numbers themselves, so there is no single point where a future pipeline change can break master-before-client.

## What this does NOT cover

- **Undo/rollback** — Flyway Community doesn't support `undo` (Teams edition only). Rollback is via a forward migration.
- **Repeatable (`R__`) migrations** — out of scope.
- **4-segment patch releases that arrive after their parent** — e.g. release `2026.5.1.1` added after `2026.5.1` is already deployed would be blocked by strict mode (since `2026.5.1.1.1` < `2026.5.1.2`). Mitigate by rolling the patch forward (release as `2026.5.2`), or briefly flipping `outOfOrder=true` for that one deploy.
