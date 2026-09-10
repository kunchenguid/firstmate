# AI-Handler scenario seeds

RevoCall-AI-Handler has no real-Postgres test convention: every DB-touching test in `services/ai-handler/tests/` builds an in-memory SQLite engine with `Base.metadata.create_all` plus JSONB and UUID `@compiles` shims.
So a provisioned Postgres here is never for the unit suite.
It is for the paths that genuinely need a real database:

- `scripts/verify_rv2015_breakdown.py`, run as `CONFIG=<ini> PYTHONPATH=. uv run python scripts/verify_rv2015_breakdown.py <organization_id>`.
- The standalone psql scripts in `scripts/sql/`, which the repo itself documents as runnable against any reachable ai-handler database.
- Driving the running `app` service for a live end-to-end session.

Two constraints when adding a fixture here.

`scripts/` is not in the container image, because the `Dockerfile` copies only `src/`, `tests/`, and `assets/`.
A script-based seed therefore runs on the host, or through psql against the published port, never as `docker compose exec app python scripts/...`.

JSONB nulls have two spellings in this schema, and a fixture that ignores the difference asserts nothing.
`scripts/sql/post_call_replay_diagnose.sql` records why: SQLAlchemy's JSONB type defaults to `none_as_null=False`, so a Python `None` persists as the JSON scalar `'null'` rather than SQL NULL, and `summary IS NULL` matches nothing in production.
Use `jsonb_typeof(summary) = 'null'` when a scenario needs the un-summarised shape.

Give every file the same preconditions header as `../revocall/admin-portal-login.sql`.
