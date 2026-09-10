-- Scenario: admin-portal-login (repo: RevoCall, database: admin)
--
-- Preconditions:
--   layers   schema (golang-migrate on `admin`), baseline (seed_user_management,
--            seed_tiers, seed_superadmin <email> <password>)
--   services postgres
--   target   the `admin` database
--   variable -v email=<the address seed_superadmin was given>
--
-- What this adds and why it is not already in the repo.
-- `admin/frontend/e2e/auth.setup.ts` signs in and then asserts a SELECTED
-- ORGANIZATION, reading it from the auth store. The committed seed chain cannot
-- produce one: `cmd/seed_superadmin` inserts user_role_organization with
-- organization_id = NULL, a global SUPERADMIN bound to no organization.
-- `deploy/SLOTS.md` records the same gap from the operations side, noting that
-- the superadmin organization and its ORGADMIN binding come from a staging
-- manifest and do not carry over per slot. This file is that missing step, and
-- nothing more: it never creates the user, because the password is argon2id and
-- hashing belongs in `cmd/seed_superadmin`, not in SQL.
--
-- Rows use the repo's own ZZ-<SCENARIO>-<Entity> namespace so they are
-- recognizable, deletable by prefix, and safe in a shared database. Every insert
-- is ON CONFLICT-guarded, so re-provisioning the scenario is a no-op.

\set ON_ERROR_STOP on

-- A missing variable must ABORT, not warn. psql's \quit takes no exit code, so
-- the refusal is raised as a real error instead: with ON_ERROR_STOP on, that is
-- what makes the process exit non-zero rather than reporting success.
\if :{?email}
\else
DO $$ BEGIN
  RAISE EXCEPTION 'admin-portal-login: -v email=<address seed_superadmin created> is required';
END $$;
\endif

BEGIN;

-- Bridge the psql variable into the session so the DO blocks below can read it.
-- A DO block's body is a string literal to psql, so a `:'email'` inside one is
-- never substituted; set_config is the seam that works for both.
SELECT set_config('admin_portal_login.email', :'email', false);

-- 1. The named user must already exist. Checked BEFORE any insert, because a
--    typo in the email would otherwise leave the organization created, no
--    binding made, and the run reporting success.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM users WHERE email = current_setting('admin_portal_login.email')) THEN
    RAISE EXCEPTION 'admin-portal-login: no user with email %; run seed_superadmin first',
      current_setting('admin_portal_login.email');
  END IF;
END $$;

-- 2. A tier for the scenario organization. `organization.tier_id` is NOT NULL.
INSERT INTO tier (id, name, description)
VALUES (gen_random_uuid(), 'ZZ-AdminPortalLogin-Tier', 'admin-portal-login scenario')
ON CONFLICT (name) DO UPDATE SET description = EXCLUDED.description;

-- 3. The organization the portal will select. billing_model defaults to
--    'legacy', which the organization_billing_model_check constraint accepts.
INSERT INTO organization (id, name, tier_id)
SELECT '019400a0-1111-7000-8000-000000000001', 'ZZ-AdminPortalLogin-Org', t.id
FROM tier t
WHERE t.name = 'ZZ-AdminPortalLogin-Tier'
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name;

-- 4. Bind that user to that organization as ORGADMIN. The role id is the fixed
--    constant from admin/backend/internal/seed/roles/roles.go, so this never
--    depends on a name lookup. uro_user_role_org_unique is a partial unique
--    index over (user_id, role_id, organization_id) WHERE organization_id IS
--    NOT NULL, which is the conflict target below.
INSERT INTO user_role_organization (user_id, role_id, organization_id)
SELECT u.id, '019400a0-0000-7000-8000-000000000001', '019400a0-1111-7000-8000-000000000001'
FROM users u
WHERE u.email = current_setting('admin_portal_login.email')
ON CONFLICT (user_id, role_id, organization_id) WHERE organization_id IS NOT NULL
DO NOTHING;

-- 5. Prove THIS user now resolves an organization, rather than proving only
--    that some binding exists: a leftover binding from an earlier run of this
--    scenario would satisfy the weaker check for any email at all.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM user_role_organization uro
    JOIN users u ON u.id = uro.user_id
    WHERE u.email = current_setting('admin_portal_login.email')
      AND uro.role_id = '019400a0-0000-7000-8000-000000000001'
      AND uro.organization_id = '019400a0-1111-7000-8000-000000000001'
      AND uro.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'admin-portal-login: % still resolves no organization',
      current_setting('admin_portal_login.email');
  END IF;
END $$;

COMMIT;
