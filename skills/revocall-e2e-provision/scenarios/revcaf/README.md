# RevCAF scenario seeds

There are deliberately no SQL fixtures here for anything `tests/integration` covers.

That suite owns its own seeding.
`tests/integration/conftest.py` rebuilds the schema per test with `alembic upgrade head` and provides scenario fixtures such as `seeded`, which creates two organizations and one assistant owned by the first.
A SQL twin of an in-repo pytest fixture drifts from it the moment only one is edited.

For those tests, the provisioning skill's whole job is layer 1 and layer 2 of the seed contract:

1. Bring up `db` under a task-scoped project name.
2. Create a database whose NAME differs from the application's, for example `revcaf_test`.
3. Export it as `TEST_DATABASE_URL`.

The suite then does the rest, and refuses if step 2 was skipped.

Add a file here only for a scenario driven through the running application over HTTP or WebSocket, where no pytest fixture exists to satisfy.
Give it the same preconditions header as `../revocall/admin-portal-login.sql`.
