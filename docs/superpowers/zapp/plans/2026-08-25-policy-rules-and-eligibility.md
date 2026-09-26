# Policy Rules and Eligibility Evaluator — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace zapp's placeholder evaluator with a real eligibility verdict driven by a versioned, SHA-stamped rules file, and record every gate's result to DynamoDB.

**Architecture:** `policy-rules.yaml` is validated at build time and compiled into a bundled TypeScript module, so an invalid rules file fails the deploy rather than the Lambda. Eleven pure gates run over the PR payload plus one GitHub call (`GET /pulls/{n}/files`), producing a per-gate verdict map that is both rendered into the check run and written to a DynamoDB eval record.

**Tech Stack:** Node 22, TypeScript, `node:test` + `tsx`, esbuild, `yaml` (build-time only), AWS SDK v3 (DynamoDB), Terraform, container-image Lambda via `finserv-reusable-gha` CI/CD v2.

**Spec:** [`../specs/2026-08-25-policy-rules-and-eligibility-design.md`](../specs/2026-08-25-policy-rules-and-eligibility-design.md)

**Jira:** [PLAT-1189](https://redventures.atlassian.net/browse/PLAT-1189) (T5), [PLAT-1190](https://redventures.atlassian.net/browse/PLAT-1190) (T6), minimal slices of [PLAT-1188](https://redventures.atlassian.net/browse/PLAT-1188) (T4) and [PLAT-1193](https://redventures.atlassian.net/browse/PLAT-1193) (T9). Epic [PLAT-1184](https://redventures.atlassian.net/browse/PLAT-1184).

**Repo:** `bankrate/zapp`. Branch from `main`: `feat/plat-1190-eligibility-evaluator`.

## Global Constraints

- **Shadow-mode invariant.** `src/checks.ts` is NOT modified. `postShadowCheck` takes no conclusion parameter and remains the only path to the check-runs API. Never add a code path that writes to pull requests, statuses, or merge queues.
- **Check names, exactly:** `merge-policy/eligibility` and `merge-policy/risk`.
- **Gate order is fixed and load-bearing** — `failedGate` is the first failure in this order: `enrolled`, `botAllowlisted`, `ticketLinked`, `conventionalTitle`, `changeClass`, `pathsAllowed`, `size`, `semverCap`, `classificationPermits`, `tierFloor`, `freezeOff`.
- **Evaluate all gates, report the first failure.** Every computable gate is recorded. Gates downstream of an `unclassified` change class record `skipped`, never `fail`.
- **Semver deltas come from the `package.json` patch hunk only** — never the PR title, never the dependabot summary table in the body.
- **Max delta governs a grouped bump.** One major among eleven patches makes the whole PR `dep-major`.
- **Generated files are excluded from BOTH the size gate's file count and its line count.**
- **Bot logins are matched against `pull_request.user.login`** — the value is `dependabot[bot]`, NOT the `app/dependabot` form the `gh` CLI prints.
- **Never log secrets or PR prose.** Per `src/log.ts`: repo, PR number, SHAs, gate names and verdicts are safe. PR title and body content are not, even though the gates read them.
- **Node 22**, ESM (`"type": "module"`), so every relative import carries a `.js` extension even from `.ts` sources.
- **Conventional Commits** — `release.yml` runs semantic-release on merge to `main`.
- **`docs/superpowers/` is gitignored in this repo.** The spec and this plan live in firstmate. Do not add design docs to the zapp repo.
- **`src/generated/rules.ts` is committed and never hand-edited.** CI asserts it has no drift from `policy-rules.yaml`.

---

### Task 0: Capture the three PR fixtures

Every later task's tests read these. Capturing them first means the gates are written against real data instead of imagined data, and it makes the suite reproducible without network access.

**Files:**
- Create: `tests/fixtures/pr-27-payload.json`, `tests/fixtures/pr-27-files.json`
- Create: `tests/fixtures/pr-32-payload.json`, `tests/fixtures/pr-32-files.json`
- Create: `tests/fixtures/pr-37-payload.json`, `tests/fixtures/pr-37-files.json`
- Create: `tests/fixtures/README.md`

**Interfaces:**
- Consumes: nothing
- Produces: JSON fixtures matching GitHub's `pull_request` object and `GET /pulls/{n}/files` response shapes

- [ ] **Step 1: Create the branch**

```bash
cd /Users/scrosby/Projects/github/zapp
git checkout main && git pull
git checkout -b feat/plat-1190-eligibility-evaluator
mkdir -p tests/fixtures
```

- [ ] **Step 2: Capture the pull request objects**

```bash
for n in 27 32 37; do
  gh api repos/bankrate/platform-cicd-v2-demo/pulls/$n \
    > tests/fixtures/pr-$n-payload.json
done
```

- [ ] **Step 3: Capture the changed-file lists**

```bash
for n in 27 32 37; do
  gh api "repos/bankrate/platform-cicd-v2-demo/pulls/$n/files?per_page=100" \
    > tests/fixtures/pr-$n-files.json
done
```

- [ ] **Step 4: Verify the fixtures carry what the gates need**

```bash
for n in 27 32 37; do
  echo "PR $n: author=$(jq -r .user.login tests/fixtures/pr-$n-payload.json) title=$(jq -r .title tests/fixtures/pr-$n-payload.json | cut -c1-45)"
  jq -r '.[] | "  \(.filename) +\(.additions)/-\(.deletions) patch=\(if .patch then "yes" else "NO" end)"' tests/fixtures/pr-$n-files.json
done
```

Expected: PR 27 and 32 show `author=dependabot[bot]` and a `package.json` entry with `patch=yes`; PR 37 shows `author=iscooter` and `PLAT-1233-VALIDATION.md`.

**If `package.json` shows `patch=NO`, stop.** GitHub omits `patch` for files above a size threshold; without it the classifier has nothing to read and the design needs revisiting.

- [ ] **Step 5: Document the fixtures**

Create `tests/fixtures/README.md`:

```markdown
# Test fixtures

Real captured responses from `bankrate/platform-cicd-v2-demo`, used by the
eligibility gate tests so they run against genuine GitHub payloads rather than
hand-written approximations.

| Fixture | Source | Exercises |
|---|---|---|
| `pr-27-*` | PR #27, grouped dependabot bump, 6 packages | The full pass: `dep-minor`, all 11 gates green |
| `pr-32-*` | PR #32, grouped dependabot bump, 11 packages | `dep-major`; fails `classificationPermits` and `tierFloor` |
| `pr-37-*` | PR #37, human-authored, one markdown file | Fails `botAllowlisted`; change class `unclassified` |

`*-payload.json` is the `pull_request` object as it appears inside the webhook
body. `*-files.json` is `GET /repos/{owner}/{repo}/pulls/{n}/files`.

Regenerate with the commands in Task 0 of the implementation plan. Do not
hand-edit: their value is that they are real.
```

- [ ] **Step 6: Commit**

```bash
git add tests/fixtures/
git commit -m "test: capture real PR fixtures for the eligibility gates (PLAT-1190)"
```

---

### Task 1: The rules file, its validator, and the generated module

The build-time half of PLAT-1189. Produces the artifact every later task reads.

**Files:**
- Create: `policy-rules.yaml`
- Create: `scripts/build-rules.mjs`
- Create: `src/generated/rules.ts` (generated, committed)
- Create: `tests/build-rules.test.ts`
- Modify: `package.json` (scripts + `yaml` devDependency)
- Modify: `Dockerfile` (copy the yaml and scripts into the build stage)
- Modify: `.github/workflows/ci.yml` (drift check)

**Interfaces:**
- Consumes: nothing
- Produces:
  - `src/generated/rules.ts` exporting `POLICY: PolicyDocument` and `RULES_SHA: string`
  - `scripts/build-rules.mjs` exporting `validatePolicy(doc): string[]` and `gitBlobSha(contents: string): string` for tests

- [ ] **Step 1: Add the YAML parser as a build-only dependency**

```bash
pnpm add -D yaml
```

It is a devDependency because nothing at runtime parses YAML — the generator does, at build time.

- [ ] **Step 2: Create `policy-rules.yaml`**

```yaml
# Merge-policy rules and repo enrollment. Reviewed as a PR; the file's git blob
# SHA is stamped into every evaluation, so any decision traces to the exact
# rules that produced it.
#
# NOT read at runtime. scripts/build-rules.mjs validates this file and compiles
# it into src/generated/rules.ts at build time, so an invalid file fails the
# deploy rather than the Lambda.
version: 1

rules:
  # Gate 11, checked last. One switch makes every PR a non-candidate.
  freeze: false

  # Matched against pull_request.user.login from the webhook payload.
  # That value is `dependabot[bot]`. The `app/dependabot` form printed by the
  # gh CLI is a rendering, not the login, and would never match.
  bots:
    - login: "dependabot[bot]"
      ticketRequired: false
    - login: "bankrate-security[bot]"
      ticketRequired: false
    - login: "devin-ai-integration[bot]"
      ticketRequired: true

  # Generated content. Excluded from BOTH counts in the size gate: a lockfile's
  # thousand changed lines carry no review burden, and counting them makes every
  # size ceiling meaningless (PR #32 is 22 authored lines and 1,038 generated).
  generatedPaths:
    - "**/pnpm-lock.yaml"
    - "**/package-lock.json"
    - "**/yarn.lock"
    - "**/.terraform.lock.hcl"

  changeClasses:
    lockfile-only:
      semverCap: none
      maxFiles: 0
      maxLines: 0
      allowedPaths: ["**/pnpm-lock.yaml", "**/package-lock.json", "**/yarn.lock"]
      deniedPaths: []
      tierFloor: 1
      classifications: [sandbox, internal-tool, prod-service]

    dep-patch:
      semverCap: patch
      maxFiles: 3
      maxLines: 60
      allowedPaths: ["package.json", "**/package.json", "**/pnpm-lock.yaml", "**/package-lock.json", "**/yarn.lock"]
      deniedPaths: [".github/**", "infrastructure/**", "Dockerfile"]
      tierFloor: 2
      classifications: [sandbox, internal-tool, prod-service]

    dep-minor:
      semverCap: minor
      maxFiles: 3
      maxLines: 60
      allowedPaths: ["package.json", "**/package.json", "**/pnpm-lock.yaml", "**/package-lock.json", "**/yarn.lock"]
      deniedPaths: [".github/**", "infrastructure/**", "Dockerfile"]
      tierFloor: 2
      classifications: [sandbox, internal-tool]

    dep-major:
      semverCap: major
      maxFiles: 3
      maxLines: 60
      allowedPaths: ["package.json", "**/package.json", "**/pnpm-lock.yaml", "**/package-lock.json", "**/yarn.lock"]
      deniedPaths: [".github/**", "infrastructure/**", "Dockerfile"]
      tierFloor: 3
      # Empty on purpose: no repo classification permits a major bump in v1.
      # Defining the class anyway — rather than letting majors fall through to
      # `unclassified` — buys a precise rationale ("major bumps aren't eligible
      # on a sandbox repo") instead of a useless one ("unrecognized change").
      classifications: []

repos:
  - repo: bankrate/platform-cicd-v2-demo
    classification: sandbox
    ciTrustTier: 2
    mode: shadow
    stageEnabled: false
```

- [ ] **Step 3: Write the failing tests**

Create `tests/build-rules.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { validatePolicy, gitBlobSha } from '../scripts/build-rules.mjs';

/** A minimal valid document; each test mutates one field to make it invalid. */
function validDoc(): any {
  return {
    version: 1,
    rules: {
      freeze: false,
      bots: [{ login: 'dependabot[bot]', ticketRequired: false }],
      generatedPaths: ['**/pnpm-lock.yaml'],
      changeClasses: {
        'dep-patch': {
          semverCap: 'patch', maxFiles: 3, maxLines: 60,
          allowedPaths: ['package.json'], deniedPaths: [],
          tierFloor: 2, classifications: ['sandbox'],
        },
      },
    },
    repos: [{
      repo: 'bankrate/platform-cicd-v2-demo', classification: 'sandbox',
      ciTrustTier: 2, mode: 'shadow', stageEnabled: false,
    }],
  };
}

test('a valid document produces no errors', () => {
  assert.deepEqual(validatePolicy(validDoc()), []);
});

test('an unknown semverCap is rejected by name', () => {
  const doc = validDoc();
  doc.rules.changeClasses['dep-patch'].semverCap = 'huge';
  const errors = validatePolicy(doc);
  assert.equal(errors.length, 1);
  assert.match(errors[0], /rules\.changeClasses\.dep-patch\.semverCap/);
});

test('an unknown repo classification is rejected by name', () => {
  const doc = validDoc();
  doc.repos[0].classification = 'wildly-unsafe';
  assert.match(validatePolicy(doc)[0], /repos\[0\]\.classification/);
});

test('a classification a change class references but no repo can hold is rejected', () => {
  const doc = validDoc();
  doc.rules.changeClasses['dep-patch'].classifications = ['nonsense'];
  assert.match(validatePolicy(doc)[0], /rules\.changeClasses\.dep-patch\.classifications/);
});

test('a non-integer ciTrustTier is rejected', () => {
  const doc = validDoc();
  doc.repos[0].ciTrustTier = 2.5;
  assert.match(validatePolicy(doc)[0], /repos\[0\]\.ciTrustTier/);
});

test('a bot entry missing ticketRequired is rejected — the default would be a guess', () => {
  const doc = validDoc();
  delete doc.rules.bots[0].ticketRequired;
  assert.match(validatePolicy(doc)[0], /rules\.bots\[0\]\.ticketRequired/);
});

test('a duplicate repo entry is rejected', () => {
  const doc = validDoc();
  doc.repos.push({ ...doc.repos[0] });
  assert.match(validatePolicy(doc)[0], /duplicate/i);
});

test('an unsupported version is rejected', () => {
  const doc = validDoc();
  doc.version = 2;
  assert.match(validatePolicy(doc)[0], /version/);
});

test('every error is reported, not just the first', () => {
  const doc = validDoc();
  doc.repos[0].classification = 'nope';
  doc.rules.changeClasses['dep-patch'].semverCap = 'nope';
  assert.equal(validatePolicy(doc).length, 2);
});

test('gitBlobSha matches what git itself computes for the real rules file', () => {
  const contents = readFileSync('policy-rules.yaml', 'utf8');
  const fromGit = execFileSync('git', ['hash-object', 'policy-rules.yaml'], { encoding: 'utf8' }).trim();
  assert.equal(gitBlobSha(contents), fromGit);
});

test('the committed generated module carries that same SHA', async () => {
  const { RULES_SHA, POLICY } = await import('../src/generated/rules.js');
  const fromGit = execFileSync('git', ['hash-object', 'policy-rules.yaml'], { encoding: 'utf8' }).trim();
  assert.equal(RULES_SHA, fromGit, 'run `pnpm run build:rules` and commit the result');
  assert.equal(POLICY.repos[0].repo, 'bankrate/platform-cicd-v2-demo');
});
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — `Cannot find module '../scripts/build-rules.mjs'`

- [ ] **Step 5: Write the generator**

Create `scripts/build-rules.mjs`:

```js
#!/usr/bin/env node
// Build-time compiler for policy-rules.yaml.
//
// Parses, validates, and emits src/generated/rules.ts. Runs from `pnpm run
// build`, which the Dockerfile's build stage runs, so an invalid rules file
// fails the image build and therefore the deploy — PLAT-1189's "fails deploy,
// not runtime" criterion, obtained structurally rather than by a runtime check
// somebody could skip.
//
// Nothing parses YAML at runtime; `yaml` is a devDependency for this reason.
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { parse } from 'yaml';

const SEMVER_LEVELS = ['none', 'patch', 'minor', 'major'];
const CLASSIFICATIONS = ['sandbox', 'internal-tool', 'prod-service'];
const MODES = ['shadow', 'off'];

/**
 * Compute a file's git blob SHA from its contents alone.
 *
 * Byte-identical to `git hash-object <file>`. Content-only because the Docker
 * build stage has no .git directory to ask — and it is still literally the
 * file's git SHA, which is what PLAT-1189 asks to be stamped on decisions.
 */
export function gitBlobSha(contents) {
  const body = Buffer.from(contents, 'utf8');
  const header = Buffer.from(`blob ${body.length}\0`, 'utf8');
  return createHash('sha1').update(Buffer.concat([header, body])).digest('hex');
}

const isInt = (v) => typeof v === 'number' && Number.isInteger(v);
const isStrArray = (v) => Array.isArray(v) && v.every((s) => typeof s === 'string');

/**
 * Validate a parsed policy document.
 *
 * Returns EVERY error rather than throwing on the first: someone fixing a rules
 * file should see all of its problems in one build, not discover them one
 * rebuild at a time. Each message names the offending path.
 */
export function validatePolicy(doc) {
  const errors = [];
  const bad = (path, msg) => errors.push(`${path}: ${msg}`);

  if (doc?.version !== 1) bad('version', `must be 1 (got ${JSON.stringify(doc?.version)})`);

  const rules = doc?.rules;
  if (!rules || typeof rules !== 'object') {
    bad('rules', 'must be an object');
    return errors;
  }

  if (typeof rules.freeze !== 'boolean') bad('rules.freeze', 'must be a boolean');
  if (!isStrArray(rules.generatedPaths)) bad('rules.generatedPaths', 'must be an array of strings');

  if (!Array.isArray(rules.bots)) {
    bad('rules.bots', 'must be an array');
  } else {
    rules.bots.forEach((bot, i) => {
      if (typeof bot?.login !== 'string' || !bot.login) bad(`rules.bots[${i}].login`, 'must be a non-empty string');
      // No default: a bot silently exempted from ticket linkage because the
      // field was omitted is exactly the kind of quiet policy drift this
      // validator exists to prevent.
      if (typeof bot?.ticketRequired !== 'boolean') bad(`rules.bots[${i}].ticketRequired`, 'must be a boolean (no default)');
    });
    const logins = rules.bots.map((b) => b?.login);
    if (new Set(logins).size !== logins.length) bad('rules.bots', 'duplicate login');
  }

  const classes = rules.changeClasses;
  if (!classes || typeof classes !== 'object') {
    bad('rules.changeClasses', 'must be an object');
  } else {
    for (const [name, cls] of Object.entries(classes)) {
      const p = `rules.changeClasses.${name}`;
      if (!SEMVER_LEVELS.includes(cls?.semverCap)) bad(`${p}.semverCap`, `must be one of ${SEMVER_LEVELS.join(', ')}`);
      if (!isInt(cls?.maxFiles) || cls.maxFiles < 0) bad(`${p}.maxFiles`, 'must be a non-negative integer');
      if (!isInt(cls?.maxLines) || cls.maxLines < 0) bad(`${p}.maxLines`, 'must be a non-negative integer');
      if (!isStrArray(cls?.allowedPaths)) bad(`${p}.allowedPaths`, 'must be an array of strings');
      if (!isStrArray(cls?.deniedPaths)) bad(`${p}.deniedPaths`, 'must be an array of strings');
      if (!isInt(cls?.tierFloor) || cls.tierFloor < 0) bad(`${p}.tierFloor`, 'must be a non-negative integer');
      if (!Array.isArray(cls?.classifications) || !cls.classifications.every((c) => CLASSIFICATIONS.includes(c))) {
        bad(`${p}.classifications`, `must be an array of ${CLASSIFICATIONS.join(', ')}`);
      }
    }
  }

  if (!Array.isArray(doc?.repos)) {
    bad('repos', 'must be an array');
  } else {
    doc.repos.forEach((r, i) => {
      if (typeof r?.repo !== 'string' || !r.repo.includes('/')) bad(`repos[${i}].repo`, 'must be "owner/name"');
      if (!CLASSIFICATIONS.includes(r?.classification)) bad(`repos[${i}].classification`, `must be one of ${CLASSIFICATIONS.join(', ')}`);
      if (!isInt(r?.ciTrustTier)) bad(`repos[${i}].ciTrustTier`, 'must be an integer');
      if (!MODES.includes(r?.mode)) bad(`repos[${i}].mode`, `must be one of ${MODES.join(', ')}`);
      if (typeof r?.stageEnabled !== 'boolean') bad(`repos[${i}].stageEnabled`, 'must be a boolean');
    });
    const names = doc.repos.map((r) => r?.repo);
    if (new Set(names).size !== names.length) bad('repos', 'duplicate repo entry');
  }

  return errors;
}

/** Read, validate, and emit. Exits non-zero on any validation error. */
function main() {
  const source = 'policy-rules.yaml';
  const contents = readFileSync(source, 'utf8');
  const doc = parse(contents);

  const errors = validatePolicy(doc);
  if (errors.length > 0) {
    console.error(`${source} is invalid:\n` + errors.map((e) => `  - ${e}`).join('\n'));
    process.exit(1);
  }

  const sha = gitBlobSha(contents);
  const out = `// GENERATED by scripts/build-rules.mjs from policy-rules.yaml.
// Do not edit. Run \`pnpm run build:rules\` and commit the result.
import type { PolicyDocument } from '../rules-types.js';

/** Git blob SHA of policy-rules.yaml — stamped into every evaluation. */
export const RULES_SHA = '${sha}';

/** The validated policy document, frozen at module load. */
export const POLICY: PolicyDocument = Object.freeze(${JSON.stringify(doc, null, 2)}) as PolicyDocument;
`;

  mkdirSync('src/generated', { recursive: true });
  writeFileSync('src/generated/rules.ts', out);
  console.log(`wrote src/generated/rules.ts (rulesSha ${sha})`);
}

// Only run when invoked directly, so tests can import the helpers above.
if (process.argv[1] && process.argv[1].endsWith('build-rules.mjs')) main();
```

- [ ] **Step 6: Create the shared types module**

`src/generated/rules.ts` imports its types from a hand-written file so the generated output stays data-only. Create `src/rules-types.ts`:

```ts
// Shape of policy-rules.yaml. Hand-written; scripts/build-rules.mjs validates
// against these same constraints and src/generated/rules.ts is typed by them.

/** Semver distance ceiling a change class permits. */
export type SemverLevel = 'none' | 'patch' | 'minor' | 'major';

/** How much a repository is trusted to absorb automated change. */
export type RepoClassification = 'sandbox' | 'internal-tool' | 'prod-service';

/** An automation account whose pull requests may be evaluated. */
export interface BotEntry {
  /** Matched against `pull_request.user.login`, e.g. `dependabot[bot]`. */
  login: string;
  /** Whether gate 3 requires a Jira key on this bot's pull requests. */
  ticketRequired: boolean;
}

/** The thresholds one kind of change must clear. */
export interface ChangeClass {
  semverCap: SemverLevel;
  /** Ceiling on non-generated files changed. */
  maxFiles: number;
  /** Ceiling on non-generated lines changed. */
  maxLines: number;
  allowedPaths: string[];
  deniedPaths: string[];
  tierFloor: number;
  /** Repo classifications permitted to use this class. Empty = never eligible. */
  classifications: RepoClassification[];
}

export interface Rules {
  freeze: boolean;
  bots: BotEntry[];
  generatedPaths: string[];
  changeClasses: Record<string, ChangeClass>;
}

/** One enrolled repository. The minimal T4 slice — no sync metadata. */
export interface EnrollmentRecord {
  repo: string;
  classification: RepoClassification;
  ciTrustTier: number;
  mode: 'shadow' | 'off';
  stageEnabled: boolean;
}

export interface PolicyDocument {
  version: 1;
  rules: Rules;
  repos: EnrollmentRecord[];
}
```

- [ ] **Step 7: Wire the build**

In `package.json`, add `build:rules` and make `build`, `typecheck` and `test` depend on it:

```json
    "build:rules": "node scripts/build-rules.mjs",
    "typecheck": "pnpm run build:rules && tsc --noEmit",
    "test": "pnpm run build:rules && node --import tsx --test tests/*.test.ts",
    "test:coverage": "pnpm run build:rules && c8 --reporter=lcovonly --reporter=text --include='src/**' node --import tsx --test tests/*.test.ts",
    "build": "pnpm run build:rules && esbuild src/index.ts --bundle --platform=node --target=node22 --minify --sourcemap --outfile=dist/index.js",
```

- [ ] **Step 8: Copy the new inputs into the Docker build stage**

In `Dockerfile`, the build stage currently copies only `tsconfig.json` and `src`. Add the rules file and the scripts directory before `RUN pnpm run build`:

```dockerfile
COPY tsconfig.json ./
COPY policy-rules.yaml ./
COPY scripts ./scripts
COPY src ./src
RUN pnpm run build
```

Without this the image build fails at `build:rules` with `ENOENT: policy-rules.yaml` — which is the mechanism working as designed, just earlier than intended.

- [ ] **Step 9: Add the drift check to CI**

In `.github/workflows/ci.yml`, after `pnpm install --frozen-lockfile` and before `pnpm run typecheck`:

```yaml
      - name: Rules module has no drift from policy-rules.yaml
        run: |
          pnpm run build:rules
          git diff --exit-code src/generated/rules.ts \
            || { echo "::error::src/generated/rules.ts is stale. Run 'pnpm run build:rules' and commit."; exit 1; }
```

The generated module is committed so `typecheck` and `test` work on a fresh clone without a build step; this check is what keeps "committed" from meaning "silently stale."

- [ ] **Step 10: Generate and run the tests**

```bash
pnpm run build:rules
pnpm test
```

Expected: PASS, 11 tests in `tests/build-rules.test.ts`.

- [ ] **Step 11: Prove the deploy gate actually fires**

```bash
sed -i.bak 's/semverCap: patch/semverCap: enormous/' policy-rules.yaml
pnpm run build:rules; echo "exit=$?"
mv policy-rules.yaml.bak policy-rules.yaml
pnpm run build:rules
```

Expected: the first `build:rules` prints `rules.changeClasses.dep-patch.semverCap: must be one of none, patch, minor, major` and `exit=1`. This is PLAT-1189's first acceptance criterion, demonstrated rather than asserted.

- [ ] **Step 12: Commit**

```bash
git add policy-rules.yaml scripts/build-rules.mjs src/rules-types.ts src/generated/rules.ts \
        tests/build-rules.test.ts package.json pnpm-lock.yaml Dockerfile .github/workflows/ci.yml
git commit -m "feat: policy-rules.yaml with build-time validation and SHA stamping (PLAT-1189)"
```

---

### Task 2: Rules accessors and real enrollment

Replaces the `ENROLLED_REPOS` env-var stand-in with the rules file. This is the minimal PLAT-1188 slice.

**Files:**
- Create: `src/rules.ts`
- Modify: `src/enrollment.ts` (body rewritten; `isEnrolled` keeps its name)
- Modify: `tests/enrollment.test.ts` (rewritten for the new source)
- Create: `tests/rules.test.ts`

**Interfaces:**
- Consumes: `POLICY`, `RULES_SHA` from Task 1; types from `src/rules-types.ts`
- Produces:
  - `rules(): Rules`, `rulesSha(): string`
  - `enrollmentFor(repoFullName: string, repos?: readonly EnrollmentRecord[]): EnrollmentRecord | undefined`
  - `isEnrolled(repoFullName: string, repos?: readonly EnrollmentRecord[]): boolean`

Deliberately no `changeClassFor` or `botFor` helpers: `runGates` receives the whole `Rules` object as
an injected parameter so it stays pure and testable, and reads `rules.changeClasses[name]` and
`rules.bots` directly. Accessors would be exported, tested, and never called.

- [ ] **Step 1: Write the failing tests**

Create `tests/rules.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { rules, rulesSha } from '../src/rules.js';

test('exposes the freeze switch, and it is off', () => {
  assert.equal(rules().freeze, false);
});

test('rulesSha is a 40-character hex sha', () => {
  assert.match(rulesSha(), /^[0-9a-f]{40}$/);
});

test('the four change classes are defined', () => {
  assert.deepEqual(
    Object.keys(rules().changeClasses).sort(),
    ['dep-major', 'dep-minor', 'dep-patch', 'lockfile-only'],
  );
});

test('dep-major is defined but permitted by no classification', () => {
  assert.deepEqual(rules().changeClasses['dep-major']!.classifications, []);
});

test('dependabot is allow-listed under its webhook login form', () => {
  const bot = rules().bots.find((b) => b.login === 'dependabot[bot]');
  assert.equal(bot?.ticketRequired, false, 'bot PRs carry no Jira key');
});

test('the gh CLI rendering of that account is NOT what is configured', () => {
  // `gh pr list` prints `app/dependabot`; the webhook payload says
  // `dependabot[bot]`. Configuring the former matches nothing, silently.
  assert.equal(rules().bots.some((b) => b.login === 'app/dependabot'), false);
});

test('lockfiles are declared generated so the size gate ignores them', () => {
  assert.ok(rules().generatedPaths.includes('**/pnpm-lock.yaml'));
});
```

Replace `tests/enrollment.test.ts` entirely:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isEnrolled, enrollmentFor } from '../src/enrollment.js';

const DEMO = 'bankrate/platform-cicd-v2-demo';

test('the demo repo is enrolled', () => {
  assert.equal(isEnrolled(DEMO), true);
});

test('its enrollment record carries the fields gates 9 and 10 read', () => {
  const record = enrollmentFor(DEMO);
  assert.equal(record?.classification, 'sandbox');
  assert.equal(record?.ciTrustTier, 2);
  assert.equal(record?.mode, 'shadow');
});

test('an unlisted repo is not enrolled', () => {
  assert.equal(isEnrolled('bankrate/brcc-api'), false);
  assert.equal(enrollmentFor('bankrate/brcc-api'), undefined);
});

test('matching is exact — a fork does not inherit enrollment', () => {
  assert.equal(isEnrolled(`${DEMO}-fork`), false);
});

test('mode "off" means present but not enrolled', () => {
  const off = [{ repo: 'bankrate/paused', classification: 'sandbox' as const,
                 ciTrustTier: 2, mode: 'off' as const, stageEnabled: false }];
  assert.equal(isEnrolled('bankrate/paused', off), false);
  assert.equal(enrollmentFor('bankrate/paused', off)?.mode, 'off',
    'the record is still retrievable — "paused" and "absent" are different facts');
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — `Cannot find module '../src/rules.js'`

- [ ] **Step 3: Write `src/rules.ts`**

```ts
// Typed accessors over the generated policy document.
//
// Every consumer reads the rules through this seam rather than importing the
// generated module directly, so the generator's output shape can change without
// touching call sites.
import { POLICY, RULES_SHA } from './generated/rules.js';
import type { Rules } from './rules-types.js';

/**
 * The policy half of the document.
 *
 * Returned whole rather than behind per-field accessors: `runGates` takes the
 * entire `Rules` object as an injected parameter so it stays pure, and tests
 * pass a modified copy to exercise a threshold. Accessors would sit between
 * them doing nothing.
 */
export const rules = (): Rules => POLICY.rules;

/** Git blob SHA of policy-rules.yaml, stamped into every evaluation. */
export const rulesSha = (): string => RULES_SHA;
```

- [ ] **Step 4: Rewrite `src/enrollment.ts`**

```ts
// Which repos this service evaluates, and the metadata gates 9 and 10 read.
//
// Reads the `repos` section of policy-rules.yaml. This is the minimal slice of
// PLAT-1188 (T4): enrollment is a reviewed change to a versioned file. T4
// proper adds the DynamoDB table and the automatic PR-to-table sync; neither is
// needed to unblock the gates, so neither is built here.
//
// Replaces the ENROLLED_REPOS environment variable, which is removed from the
// code and the Terraform.
import { POLICY } from './generated/rules.js';
import type { EnrollmentRecord } from './rules-types.js';

/**
 * The enrollment record for a repository, if it has one.
 *
 * Returns the record even when `mode` is `off`: "enrolled but paused" and "not
 * enrolled at all" are different facts, and gate 1 wants to report which.
 *
 * Args:
 *   repoFullName: `owner/repo` from the webhook payload.
 *   repos: The enrollment list (defaults to the policy document's).
 */
export function enrollmentFor(
  repoFullName: string,
  repos: readonly EnrollmentRecord[] = POLICY.repos,
): EnrollmentRecord | undefined {
  return repos.find((record) => record.repo === repoFullName);
}

/**
 * Is this repository enrolled in shadow evaluation?
 *
 * Fails closed: absent from the file, or present with `mode: off`, both mean no.
 * Matching is exact, so `owner/repo-fork` never inherits `owner/repo`.
 */
export function isEnrolled(
  repoFullName: string,
  repos: readonly EnrollmentRecord[] = POLICY.repos,
): boolean {
  const record = enrollmentFor(repoFullName, repos);
  return record !== undefined && record.mode !== 'off';
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `pnpm test && pnpm run typecheck`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add src/rules.ts src/enrollment.ts tests/rules.test.ts tests/enrollment.test.ts
git commit -m "feat: read enrollment from policy-rules.yaml, drop ENROLLED_REPOS (PLAT-1188)"
```

---

### Task 3: Jira key detection

Gate 3's dependency. Ported from `github-pr-jira-check`, which solves exactly this against the same Jira instance.

**Files:**
- Create: `src/jira-key.ts`
- Create: `tests/jira-key.test.ts`

**Interfaces:**
- Consumes: nothing
- Produces: `containsJiraKey(text: string, keys?: string[]): boolean`

- [ ] **Step 1: Write the failing test**

Create `tests/jira-key.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { containsJiraKey, JIRA_PROJECT_KEYS } from '../src/jira-key.js';

test('finds a real project key', () => {
  assert.equal(containsJiraKey('chore: PLAT-1233 zapp webhook validation'), true);
});

test('rejects a token that looks like a key but is not a project', () => {
  assert.equal(containsJiraKey('re-encoded the payload as UTF-8'), false);
  assert.equal(containsJiraKey('hashed with SHA-256'), false);
});

test('a dependabot title has no key', () => {
  assert.equal(containsJiraKey('chore(deps): bump the production-dependencies group'), false);
});

test('matching is anchored on word boundaries', () => {
  assert.equal(containsJiraKey('NOTPLAT-1'), false);
});

test('the committed project list includes PLAT', () => {
  assert.ok(JIRA_PROJECT_KEYS.includes('PLAT'));
});

test('an explicit key list overrides the committed one', () => {
  assert.equal(containsJiraKey('ZZZ-1', ['ZZZ']), true);
  assert.equal(containsJiraKey('PLAT-1', ['ZZZ']), false);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pnpm test`
Expected: FAIL — `Cannot find module '../src/jira-key.js'`

- [ ] **Step 3: Port the implementation**

Create `src/jira-key.ts` by combining `github-pr-jira-check`'s `src/jira.ts` and `src/jira-projects.ts` into one module — they are 12 and 28 lines respectively and are never used apart. Sources:

- `/Users/scrosby/Projects/github/github-pr-jira-check/src/jira.ts`
- `/Users/scrosby/Projects/github/github-pr-jira-check/src/jira-projects.ts`

Copy the `JIRA_PROJECT_KEYS` array verbatim, and the `LENIENT` regex, `escape`, `buildMatcher` and `containsJiraKey` functions verbatim. Drop the `/* c8 ignore */` pragmas — they are artifacts of that repo's coverage configuration and are not used in zapp. Export both `containsJiraKey` and `JIRA_PROJECT_KEYS`.

Keep the comment explaining why the strict hydrated list matters: the lenient fallback matches any `[A-Z]+-[0-9]+` token, including `UTF-8`, which is why the gate relies on the real project list.

zapp has no equivalent of that repo's `scripts/hydrate-jira-projects.mjs` deploy step, so the committed list is the only source. Note that in the module header.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/jira-key.ts tests/jira-key.test.ts
git commit -m "feat: port Jira key detection for the ticket-linkage gate (PLAT-1190)"
```

---

### Task 4: Fetch the pull request's changed files

The only new GitHub call in this whole spec.

**Files:**
- Create: `src/pr-files.ts`
- Create: `tests/pr-files.test.ts`

**Interfaces:**
- Consumes: `githubRequest` from `src/github.ts`
- Produces:
  - `fetchPrFiles(repoFullName: string, prNumber: number, request?: typeof githubRequest): Promise<ChangedFile[]>`
  - `interface ChangedFile { filename: string; status: string; additions: number; deletions: number; patch?: string }`

- [ ] **Step 1: Write the failing test**

Create `tests/pr-files.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fetchPrFiles } from '../src/pr-files.js';

const pr27 = JSON.parse(readFileSync('tests/fixtures/pr-27-files.json', 'utf8'));

function fakeRequest(pages: any[][]) {
  const calls: string[] = [];
  const request = async (path: string) => {
    calls.push(path);
    const page = pages.shift() ?? [];
    return { ok: true, status: 200, json: async () => page };
  };
  return { calls, request: request as any };
}

test('returns the changed files for a pull request', async () => {
  const { request, calls } = fakeRequest([pr27]);
  const files = await fetchPrFiles('bankrate/platform-cicd-v2-demo', 27, request);
  assert.equal(files.length, pr27.length);
  assert.ok(files.some((f) => f.filename === 'package.json'));
  assert.match(calls[0], /^\/repos\/bankrate\/platform-cicd-v2-demo\/pulls\/27\/files\?/);
});

test('the package.json entry carries the patch the classifier reads', async () => {
  const { request } = fakeRequest([pr27]);
  const files = await fetchPrFiles('bankrate/platform-cicd-v2-demo', 27, request);
  const manifest = files.find((f) => f.filename === 'package.json');
  assert.ok(manifest?.patch, 'patch present');
  assert.match(manifest!.patch!, /fastify/);
});

test('follows pagination until a short page', async () => {
  const full = Array.from({ length: 100 }, (_, i) => ({
    filename: `f${i}.ts`, status: 'modified', additions: 1, deletions: 0,
  }));
  const { request, calls } = fakeRequest([full, [{ filename: 'last.ts', status: 'modified', additions: 1, deletions: 0 }]]);
  const files = await fetchPrFiles('o/r', 1, request);
  assert.equal(files.length, 101);
  assert.equal(calls.length, 2);
  assert.match(calls[1], /page=2/);
});

test('stops at the page cap rather than paging forever', async () => {
  const full = Array.from({ length: 100 }, (_, i) => ({
    filename: `f${i}.ts`, status: 'modified', additions: 1, deletions: 0,
  }));
  const { request, calls } = fakeRequest([full, full, full, full, full, full, full, full]);
  await fetchPrFiles('o/r', 1, request);
  assert.ok(calls.length <= 5, `stopped at the cap, made ${calls.length} calls`);
});

test('a failed request throws so the worker retries', async () => {
  const request = (async () => ({ ok: false, status: 502, text: async () => 'Bad Gateway' })) as any;
  await assert.rejects(() => fetchPrFiles('o/r', 1, request), /pulls files GET failed .*502/);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pnpm test`
Expected: FAIL — `Cannot find module '../src/pr-files.js'`

- [ ] **Step 3: Write the implementation**

Create `src/pr-files.ts`:

```ts
// Fetches a pull request's changed files — the only GitHub call the eligibility
// evaluator makes beyond what the webhook payload already carries.
import { githubRequest } from './github.js';

const PER_PAGE = 100;

// A pull request large enough to exceed this is not a candidate under any
// change class we define, so paging further only costs rate limit. The size
// gate will reject it on the files we already have.
const MAX_PAGES = 5;

/** One entry from `GET /repos/{owner}/{repo}/pulls/{number}/files`. */
export interface ChangedFile {
  filename: string;
  /** `added`, `modified`, `removed`, `renamed`, … */
  status: string;
  additions: number;
  deletions: number;
  /**
   * The unified diff hunk. Absent when GitHub judges the file too large —
   * which is why the classifier treats a missing patch as `unclassified`
   * rather than as an empty change.
   */
  patch?: string;
}

/**
 * List a pull request's changed files, following pagination.
 *
 * Args:
 *   repoFullName: `owner/repo`.
 *   prNumber: The pull request number.
 *   request: Injectable GitHub request client.
 * Raises:
 *   Error: On a non-2xx response, so the worker releases its delivery claim
 *     and SQS retries.
 */
export async function fetchPrFiles(
  repoFullName: string,
  prNumber: number,
  request: typeof githubRequest = githubRequest,
): Promise<ChangedFile[]> {
  const files: ChangedFile[] = [];

  for (let page = 1; page <= MAX_PAGES; page++) {
    const res = await request(
      `/repos/${repoFullName}/pulls/${prNumber}/files?per_page=${PER_PAGE}&page=${page}`,
    );
    if (!res.ok) {
      throw new Error(`pulls files GET failed for ${repoFullName}#${prNumber}: ${res.status} ${await res.text()}`);
    }

    const batch = (await res.json()) as ChangedFile[];
    files.push(...batch);
    if (batch.length < PER_PAGE) break;
  }

  return files;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/pr-files.ts tests/pr-files.test.ts
git commit -m "feat: fetch a PR's changed files for classification (PLAT-1190)"
```

---

### Task 5: Glob matching

Its own task because hand-rolled glob matching is a classic source of quiet bugs, and both the classifier and the paths gate depend on being able to trust it.

**Files:**
- Create: `src/glob.ts`
- Create: `tests/glob.test.ts`

**Interfaces:**
- Consumes: nothing
- Produces: `matchesGlob(path: string, pattern: string): boolean`, `matchesAny(path: string, patterns: readonly string[]): boolean`

- [ ] **Step 1: Write the failing test**

Create `tests/glob.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { matchesGlob, matchesAny } from '../src/glob.js';

test('an exact path matches itself', () => {
  assert.equal(matchesGlob('package.json', 'package.json'), true);
  assert.equal(matchesGlob('package.json', 'package-lock.json'), false);
});

test('** matches across directory separators, including zero of them', () => {
  assert.equal(matchesGlob('pnpm-lock.yaml', '**/pnpm-lock.yaml'), true);
  assert.equal(matchesGlob('apps/api/pnpm-lock.yaml', '**/pnpm-lock.yaml'), true);
});

test('a trailing /** matches everything beneath a directory', () => {
  assert.equal(matchesGlob('.github/workflows/ci.yml', '.github/**'), true);
  assert.equal(matchesGlob('infrastructure/terraform/main.tf', 'infrastructure/**'), true);
  assert.equal(matchesGlob('src/index.ts', '.github/**'), false);
});

test('a single * does not cross a directory separator', () => {
  assert.equal(matchesGlob('src/index.ts', 'src/*.ts'), true);
  assert.equal(matchesGlob('src/deep/index.ts', 'src/*.ts'), false);
});

test('regex metacharacters in a pattern are literal', () => {
  assert.equal(matchesGlob('a.b.json', 'a.b.json'), true);
  assert.equal(matchesGlob('axbxjson', 'a.b.json'), false, 'the dot is not a wildcard');
});

test('matchesAny is false for an empty pattern list — fail closed', () => {
  assert.equal(matchesAny('anything.ts', []), false);
});

test('matchesAny is true when any pattern matches', () => {
  assert.equal(matchesAny('pnpm-lock.yaml', ['package.json', '**/pnpm-lock.yaml']), true);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pnpm test`
Expected: FAIL — `Cannot find module '../src/glob.js'`

- [ ] **Step 3: Write the implementation**

Create `src/glob.ts`:

```ts
// Minimal glob matching for the path rules in policy-rules.yaml.
//
// Hand-rolled rather than pulled from npm because only three forms are used —
// exact paths, a `**/` prefix, and a `dir/**` suffix — and a dependency in the
// Lambda bundle for that is not worth it. Kept in its own module with its own
// tests because the alternative, a subtly wrong matcher inlined into the paths
// gate, fails open on exactly the cases that matter.

/** Cache compiled patterns: the same handful are matched on every evaluation. */
const compiled = new Map<string, RegExp>();

function compile(pattern: string): RegExp {
  const cached = compiled.get(pattern);
  if (cached) return cached;

  // `**/` at the start must also match zero directories, so `**/x` matches a
  // bare `x`. Everything else is escaped literally, then the wildcards are
  // substituted back in.
  let source = '';
  let i = 0;
  while (i < pattern.length) {
    if (pattern.startsWith('**/', i)) {
      source += '(?:.*/)?';
      i += 3;
    } else if (pattern.startsWith('/**', i) && i + 3 === pattern.length) {
      source += '/.*';
      i += 3;
    } else if (pattern.startsWith('**', i)) {
      source += '.*';
      i += 2;
    } else if (pattern[i] === '*') {
      source += '[^/]*';
      i += 1;
    } else {
      source += pattern[i]!.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      i += 1;
    }
  }

  const regex = new RegExp(`^${source}$`);
  compiled.set(pattern, regex);
  return regex;
}

/** Does `path` match a single glob `pattern`? */
export function matchesGlob(path: string, pattern: string): boolean {
  return compile(pattern).test(path);
}

/** Does `path` match any of `patterns`? An empty list matches nothing. */
export function matchesAny(path: string, patterns: readonly string[]): boolean {
  return patterns.some((pattern) => matchesGlob(path, pattern));
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test`
Expected: PASS, 7 tests

- [ ] **Step 5: Commit**

```bash
git add src/glob.ts tests/glob.test.ts
git commit -m "feat: minimal glob matcher for policy path rules (PLAT-1190)"
```

---

### Task 6: Change classification

The fiddliest logic in the spec, and the part the real PRs most directly constrain.

**Files:**
- Create: `src/classify.ts`
- Create: `tests/classify.test.ts`

**Interfaces:**
- Consumes: `ChangedFile` (Task 4), `matchesAny` (Task 5), `SemverLevel` (Task 1)
- Produces:
  - `classify(files: ChangedFile[], generatedPaths: readonly string[]): ClassificationResult`
  - `interface ClassificationResult { changeClass: string; maxDelta: SemverLevel; bumps: DependencyBump[]; reason?: string }`
  - `interface DependencyBump { name: string; from: string; to: string; level: SemverLevel }`
  - `deltaLevel(from: string, to: string): SemverLevel | null`

- [ ] **Step 1: Write the failing tests**

Create `tests/classify.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { classify, deltaLevel } from '../src/classify.js';

const GENERATED = ['**/pnpm-lock.yaml', '**/package-lock.json', '**/yarn.lock', '**/.terraform.lock.hcl'];
const files = (n: number) => JSON.parse(readFileSync(`tests/fixtures/pr-${n}-files.json`, 'utf8'));

const manifest = (patch: string) => [
  { filename: 'package.json', status: 'modified', additions: 1, deletions: 1, patch },
  { filename: 'pnpm-lock.yaml', status: 'modified', additions: 50, deletions: 40, patch: '@@ -1 +1 @@\n-a\n+b' },
];

test('deltaLevel reads the level of a version change', () => {
  assert.equal(deltaLevel('1.2.3', '1.2.4'), 'patch');
  assert.equal(deltaLevel('1.2.3', '1.3.0'), 'minor');
  assert.equal(deltaLevel('1.2.3', '2.0.0'), 'major');
  assert.equal(deltaLevel('1.2.3', '1.2.3'), 'none');
});

test('deltaLevel strips range prefixes', () => {
  assert.equal(deltaLevel('^5.11.2', '^5.12.0'), 'minor');
  assert.equal(deltaLevel('~1.0.0', '~1.0.1'), 'patch');
});

test('deltaLevel returns null for a version it cannot parse', () => {
  assert.equal(deltaLevel('workspace:*', 'workspace:*'), null);
  assert.equal(deltaLevel('github:foo/bar#abc', '1.0.0'), null);
});

test('a downgrade is reported at the level that moved', () => {
  assert.equal(deltaLevel('2.0.0', '1.9.9'), 'major');
});

test('PR #27 is dep-minor — max delta governs the group', () => {
  const result = classify(files(27), GENERATED);
  assert.equal(result.changeClass, 'dep-minor');
  assert.equal(result.maxDelta, 'minor');
  // SEVEN, not the six dependabot's own summary table advertises: the table
  // lists the production-dependencies group, but `@types/pg` ^8.20.4 -> ^8.23.1
  // rode along in devDependencies. The file header (+7/-7) is the truth, and
  // this is precisely why the classifier reads the manifest diff and not the
  // bot's prose.
  assert.equal(result.bumps.length, 7);
  assert.ok(result.bumps.some((b) => b.name === 'fastify' && b.level === 'minor'));
  assert.ok(result.bumps.some((b) => b.name === '@types/pg'), 'the untabled bump is caught');
});

test('PR #32 is dep-major — one major among eleven governs', () => {
  const result = classify(files(32), GENERATED);
  assert.equal(result.changeClass, 'dep-major');
  assert.equal(result.maxDelta, 'major');
  assert.equal(result.bumps.length, 11);
  assert.ok(result.bumps.some((b) => b.name === '@semantic-release/changelog' && b.level === 'major'));
});

test('PR #37 is unclassified — it changes no manifest', () => {
  const result = classify(files(37), GENERATED);
  assert.equal(result.changeClass, 'unclassified');
  assert.match(result.reason!, /no package\.json/i);
});

test('only generated files changed is lockfile-only', () => {
  const result = classify(
    [{ filename: 'pnpm-lock.yaml', status: 'modified', additions: 9, deletions: 9, patch: '@@\n-a\n+b' }],
    GENERATED,
  );
  assert.equal(result.changeClass, 'lockfile-only');
  assert.equal(result.maxDelta, 'none');
});

test('a manifest change alongside source is unclassified', () => {
  const result = classify([
    ...manifest('@@ -1 +1 @@\n-    "pg": "8.22.0",\n+    "pg": "8.23.0",'),
    { filename: 'src/index.ts', status: 'modified', additions: 5, deletions: 1, patch: '@@\n+x' },
  ], GENERATED);
  assert.equal(result.changeClass, 'unclassified');
  assert.match(result.reason!, /src\/index\.ts/);
});

test('a non-dependency line in the manifest hunk is unclassified', () => {
  const result = classify(manifest('@@ -1 +1 @@\n-  "version": "1.0.0",\n+  "version": "1.1.0",\n-  "type": "module"\n+  "type": "commonjs"'), GENERATED);
  assert.equal(result.changeClass, 'unclassified');
});

test('an unparseable version makes the whole PR unclassified, never a guess', () => {
  const result = classify(manifest('@@ -1 +1 @@\n-    "internal": "workspace:*",\n+    "internal": "workspace:^",'), GENERATED);
  assert.equal(result.changeClass, 'unclassified');
  assert.match(result.reason!, /workspace/);
});

test('a dependency added but not replaced is unclassified', () => {
  const result = classify(manifest('@@ -1 +1 @@\n+    "brand-new": "1.0.0",'), GENERATED);
  assert.equal(result.changeClass, 'unclassified');
});

test('a manifest with no patch is unclassified, not empty', () => {
  const result = classify(
    [{ filename: 'package.json', status: 'modified', additions: 900, deletions: 900 }],
    GENERATED,
  );
  assert.equal(result.changeClass, 'unclassified');
  assert.match(result.reason!, /patch/i);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — `Cannot find module '../src/classify.js'`

- [ ] **Step 3: Write the implementation**

Create `src/classify.ts`:

```ts
// Classifies a pull request's diff into a change class and a maximum semver
// delta.
//
// Read from the package.json patch hunk ONLY — never the PR title, never the
// dependabot summary table in the body. The epic is explicit that semver
// deltas come from the manifest diff, and a bot-authored body is no more
// trustworthy than a bot-authored title.
//
// MAX DELTA GOVERNS a grouped bump: one major among eleven patches makes the
// whole PR dep-major. That matches how a reviewer reads a grouped PR, it fails
// safe, and it is the only rule under which the demo repo's real PRs classify
// at all — every dependabot PR there is grouped.
import type { ChangedFile } from './pr-files.js';
import type { SemverLevel } from './rules-types.js';
import { matchesAny } from './glob.js';

/** One dependency version change read out of the manifest hunk. */
export interface DependencyBump {
  name: string;
  from: string;
  to: string;
  level: SemverLevel;
}

/** What the diff turned out to be. */
export interface ClassificationResult {
  /** A change class name, or `unclassified`. */
  changeClass: string;
  maxDelta: SemverLevel;
  bumps: DependencyBump[];
  /** Why it is unclassified. Present only when it is. */
  reason?: string;
}

const RANK: Record<SemverLevel, number> = { none: 0, patch: 1, minor: 2, major: 3 };
const LEVEL_FOR_CLASS: Record<string, string> = {
  none: 'lockfile-only', patch: 'dep-patch', minor: 'dep-minor', major: 'dep-major',
};

// Leading range operators (^ ~ >= <= > < =) and whitespace are stripped; what
// must remain is a bare x.y.z.
const VERSION = /^[\^~>=<\s]*(\d+)\.(\d+)\.(\d+)/;

// A dependency line inside a package.json hunk: `+    "name": "version",`
const DEP_LINE = /^([+-])\s*"([^"]+)"\s*:\s*"([^"]+)",?\s*$/;

/**
 * The semver level at which two versions differ.
 *
 * Returns null when either side is not a plain x.y.z — a workspace protocol, a
 * git URL, a tag. Null propagates to `unclassified`; it is never treated as
 * `none`, because "no change" and "we could not tell" are different facts.
 */
export function deltaLevel(from: string, to: string): SemverLevel | null {
  const a = VERSION.exec(from);
  const b = VERSION.exec(to);
  if (!a || !b) return null;
  if (a[1] !== b[1]) return 'major';
  if (a[2] !== b[2]) return 'minor';
  if (a[3] !== b[3]) return 'patch';
  return 'none';
}

const unclassified = (reason: string): ClassificationResult => ({
  changeClass: 'unclassified', maxDelta: 'none', bumps: [], reason,
});

/**
 * Classify a pull request's changed files.
 *
 * Args:
 *   files: The changed files from `fetchPrFiles`.
 *   generatedPaths: Globs for generated content (lockfiles), from the rules.
 */
export function classify(
  files: ChangedFile[],
  generatedPaths: readonly string[],
): ClassificationResult {
  if (files.length === 0) return unclassified('no files changed');

  const authored = files.filter((f) => !matchesAny(f.filename, generatedPaths));

  if (authored.length === 0) {
    return { changeClass: 'lockfile-only', maxDelta: 'none', bumps: [] };
  }

  const manifests = authored.filter((f) => f.filename === 'package.json' || f.filename.endsWith('/package.json'));
  if (manifests.length === 0) {
    return unclassified(`no package.json in the diff (changed: ${authored.map((f) => f.filename).join(', ')})`);
  }

  const other = authored.filter((f) => !manifests.includes(f));
  if (other.length > 0) {
    return unclassified(`changes outside the manifest: ${other.map((f) => f.filename).join(', ')}`);
  }

  const bumps: DependencyBump[] = [];

  for (const manifest of manifests) {
    if (!manifest.patch) {
      return unclassified(`${manifest.filename} has no patch in the API response — too large to classify`);
    }

    const removed = new Map<string, string>();
    const added = new Map<string, string>();

    for (const line of manifest.patch.split('\n')) {
      if (line.startsWith('@@') || line.startsWith(' ') || line === '') continue;
      if (!line.startsWith('+') && !line.startsWith('-')) continue;

      const match = DEP_LINE.exec(line);
      if (!match) {
        return unclassified(`${manifest.filename} changes a non-dependency line: ${line.trim().slice(0, 60)}`);
      }
      (match[1] === '-' ? removed : added).set(match[2]!, match[3]!);
    }

    for (const [name, from] of removed) {
      const to = added.get(name);
      if (to === undefined) return unclassified(`dependency removed without replacement: ${name}`);

      const level = deltaLevel(from, to);
      if (level === null) return unclassified(`unparseable version for ${name}: "${from}" -> "${to}"`);

      bumps.push({ name, from, to, level });
    }

    for (const name of added.keys()) {
      if (!removed.has(name)) return unclassified(`dependency added without a prior version: ${name}`);
    }
  }

  if (bumps.length === 0) return unclassified('manifest changed but no dependency versions moved');

  const maxDelta = bumps.reduce<SemverLevel>(
    (worst, bump) => (RANK[bump.level] > RANK[worst] ? bump.level : worst),
    'none',
  );

  return { changeClass: LEVEL_FOR_CLASS[maxDelta]!, maxDelta, bumps };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test`
Expected: PASS, 14 tests in `tests/classify.test.ts`

If the two fixture-driven tests fail on bump counts, print what the classifier actually saw before changing the assertion — the fixtures are real, so a mismatch means the parser is wrong, not the expectation:

```bash
node --import tsx -e "import {classify} from './src/classify.ts'; import {readFileSync} from 'fs'; console.log(JSON.stringify(classify(JSON.parse(readFileSync('tests/fixtures/pr-27-files.json','utf8')), ['**/pnpm-lock.yaml']), null, 2))"
```

- [ ] **Step 5: Commit**

```bash
git add src/classify.ts tests/classify.test.ts
git commit -m "feat: classify diffs by change class and max semver delta (PLAT-1190)"
```

---

### Task 7: The eleven gates

**Files:**
- Create: `src/gates.ts`
- Create: `tests/gates.test.ts`

**Interfaces:**
- Consumes: `Rules`, `EnrollmentRecord`, `ChangeClass`, `SemverLevel` (Task 1); `containsJiraKey` (Task 3); `ChangedFile` (Task 4); `matchesAny` (Task 5); `ClassificationResult` (Task 6). The `Rules` and `EnrollmentRecord` values arrive as parameters on `GateInput` — this module imports no policy singleton, which is what keeps it pure.
- Produces:
  - `runGates(input: GateInput): EligibilityResult`
  - `GATE_ORDER: readonly GateName[]`
  - `type GateName`, `type GateVerdict = 'pass' | 'fail' | 'unknown' | 'skipped'`
  - `interface GateResult { verdict: GateVerdict; value?: unknown }`
  - `interface EligibilityResult { verdict: 'candidate' | 'not-candidate'; changeClass: string; gates: Record<GateName, GateResult>; failedGate: GateName | null }`
  - `interface GateInput { repoFullName; title; body; authorLogin; files; enrollment; rules; classification }`

- [ ] **Step 1: Write the failing tests**

Create `tests/gates.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runGates, GATE_ORDER } from '../src/gates.js';
import { classify } from '../src/classify.js';
import { rules } from '../src/rules.js';
import { enrollmentFor } from '../src/enrollment.js';
import type { EnrollmentRecord } from '../src/rules-types.js';

const DEMO = 'bankrate/platform-cicd-v2-demo';
const payload = (n: number) => JSON.parse(readFileSync(`tests/fixtures/pr-${n}-payload.json`, 'utf8'));
const files = (n: number) => JSON.parse(readFileSync(`tests/fixtures/pr-${n}-files.json`, 'utf8'));

/** Build gate input from a captured fixture, with optional overrides. */
function fromFixture(n: number, overrides: Partial<Parameters<typeof runGates>[0]> = {}) {
  const pr = payload(n);
  const f = files(n);
  return {
    repoFullName: DEMO,
    title: pr.title,
    body: pr.body ?? '',
    authorLogin: pr.user.login,
    files: f,
    enrollment: enrollmentFor(DEMO),
    rules: rules(),
    classification: classify(f, rules().generatedPaths),
    ...overrides,
  };
}

test('PR #27 is a candidate — all eleven gates pass', () => {
  const result = runGates(fromFixture(27));
  assert.equal(result.verdict, 'candidate');
  assert.equal(result.changeClass, 'dep-minor');
  assert.equal(result.failedGate, null);
  for (const gate of GATE_ORDER) {
    assert.equal(result.gates[gate].verdict, 'pass', `${gate} should pass`);
  }
});

test('PR #32 fails on classification, and tierFloor too', () => {
  const result = runGates(fromFixture(32));
  assert.equal(result.verdict, 'not-candidate');
  assert.equal(result.changeClass, 'dep-major');
  assert.equal(result.failedGate, 'classificationPermits');
  assert.equal(result.gates.classificationPermits.verdict, 'fail');
  assert.equal(result.gates.tierFloor.verdict, 'fail', 'dep-major needs tier 3; the repo is tier 2');
  assert.equal(result.gates.semverCap.verdict, 'pass', 'major is within dep-major cap');
});

test('PR #37 fails first on the bot allowlist', () => {
  const result = runGates(fromFixture(37));
  assert.equal(result.verdict, 'not-candidate');
  assert.equal(result.failedGate, 'botAllowlisted');
  assert.equal(result.gates.botAllowlisted.verdict, 'fail');
});

test('gates downstream of an unclassified change record skipped, not fail', () => {
  const result = runGates(fromFixture(37));
  assert.equal(result.gates.changeClass.verdict, 'fail');
  for (const gate of ['pathsAllowed', 'size', 'semverCap', 'classificationPermits', 'tierFloor'] as const) {
    assert.equal(result.gates[gate].verdict, 'skipped', `${gate} is not computable`);
  }
});

test('every gate is present in the record even after a failure', () => {
  const result = runGates(fromFixture(37));
  assert.equal(Object.keys(result.gates).length, GATE_ORDER.length);
});

test('an unenrolled repo fails gate 1', () => {
  const result = runGates(fromFixture(27, { repoFullName: 'bankrate/other', enrollment: undefined }));
  assert.equal(result.failedGate, 'enrolled');
  assert.equal(result.gates.enrolled.verdict, 'fail');
});

test('mode off fails gate 1 even though the record exists', () => {
  const paused: EnrollmentRecord = { repo: DEMO, classification: 'sandbox', ciTrustTier: 2, mode: 'off', stageEnabled: false };
  const result = runGates(fromFixture(27, { enrollment: paused }));
  assert.equal(result.gates.enrolled.verdict, 'fail');
});

test('a bot with ticketRequired fails gate 3 without a Jira key', () => {
  const strict = { ...rules(), bots: [{ login: 'dependabot[bot]', ticketRequired: true }] };
  const result = runGates(fromFixture(27, { rules: strict }));
  assert.equal(result.gates.ticketLinked.verdict, 'fail');
  assert.equal(result.failedGate, 'ticketLinked');
});

test('a Jira key in the title satisfies gate 3 even when required', () => {
  const strict = { ...rules(), bots: [{ login: 'dependabot[bot]', ticketRequired: true }] };
  const result = runGates(fromFixture(27, { rules: strict, title: 'chore(deps): PLAT-1190 bump things' }));
  assert.equal(result.gates.ticketLinked.verdict, 'pass');
});

test('a non-conventional title fails gate 4', () => {
  const result = runGates(fromFixture(27, { title: 'bumped some stuff' }));
  assert.equal(result.gates.conventionalTitle.verdict, 'fail');
});

test('conventional titles with scope and breaking marker pass gate 4', () => {
  for (const title of ['fix: x', 'feat(api): x', 'chore(deps-dev)!: x']) {
    assert.equal(runGates(fromFixture(27, { title })).gates.conventionalTitle.verdict, 'pass', title);
  }
});

test('a denied path fails gate 6', () => {
  const denied = [...files(27), { filename: '.github/workflows/ci.yml', status: 'modified', additions: 1, deletions: 1, patch: '@@\n+x' }];
  const result = runGates(fromFixture(27, {
    files: denied,
    // Classification is forced so the paths gate is reachable — a real diff
    // like this would be unclassified and the gate would be skipped.
    classification: classify(files(27), rules().generatedPaths),
  }));
  assert.equal(result.gates.pathsAllowed.verdict, 'fail');
});

test('the size gate ignores generated files in both counts', () => {
  const result = runGates(fromFixture(32));
  const value = result.gates.size.value as { files: number; lines: number };
  assert.equal(value.files, 1, 'only package.json counts');
  assert.equal(value.lines, 22, '11 additions + 11 deletions; the 1038 lockfile lines are excluded');
  assert.equal(result.gates.size.verdict, 'pass');
});

test('exceeding maxLines fails gate 7', () => {
  const tight = { ...rules(), changeClasses: { ...rules().changeClasses, 'dep-minor': { ...rules().changeClasses['dep-minor']!, maxLines: 3 } } };
  const result = runGates(fromFixture(27, { rules: tight }));
  assert.equal(result.gates.size.verdict, 'fail');
});

test('a delta above the class cap fails gate 8', () => {
  const capped = { ...rules(), changeClasses: { ...rules().changeClasses, 'dep-minor': { ...rules().changeClasses['dep-minor']!, semverCap: 'patch' as const } } };
  const result = runGates(fromFixture(27, { rules: capped }));
  assert.equal(result.gates.semverCap.verdict, 'fail');
});

test('a tier below the floor fails gate 10', () => {
  const lowTier: EnrollmentRecord = { repo: DEMO, classification: 'sandbox', ciTrustTier: 1, mode: 'shadow', stageEnabled: false };
  const result = runGates(fromFixture(27, { enrollment: lowTier }));
  assert.equal(result.gates.tierFloor.verdict, 'fail');
});

test('the freeze switch fails gate 11 and nothing else', () => {
  const frozen = { ...rules(), freeze: true };
  const result = runGates(fromFixture(27, { rules: frozen }));
  assert.equal(result.verdict, 'not-candidate');
  assert.equal(result.failedGate, 'freezeOff');
  assert.equal(result.gates.enrolled.verdict, 'pass');
});

test('failedGate is the FIRST failure in gate order, not the last', () => {
  const frozen = { ...rules(), freeze: true, bots: [] };
  const result = runGates(fromFixture(27, { rules: frozen }));
  assert.equal(result.failedGate, 'botAllowlisted');
  assert.equal(result.gates.freezeOff.verdict, 'fail', 'still recorded');
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — `Cannot find module '../src/gates.js'`

- [ ] **Step 3: Write the implementation**

Create `src/gates.ts`:

```ts
// The eleven eligibility gates (PLAT-1190).
//
// A pure function: no I/O, no clock, no environment. Everything it needs is in
// GateInput, which is what makes the fixture-driven test suite possible.
//
// EVALUATE ALL, REPORT THE FIRST. The ticket says "any no ends it", which read
// literally yields a record with one gate populated and ten blank — destroying
// the gate-failure breakdown the whole shadow phase exists to produce. So every
// computable gate runs and is recorded, and `failedGate` names the first
// failure in GATE_ORDER. The verdict is identical either way; the dataset is
// not.
import type { ChangedFile } from './pr-files.js';
import type { ClassificationResult } from './classify.js';
import type { ChangeClass, EnrollmentRecord, Rules, SemverLevel } from './rules-types.js';
import { containsJiraKey } from './jira-key.js';
import { matchesAny } from './glob.js';

/**
 * The gates, in the order PLAT-1190 specifies. Order is load-bearing:
 * `failedGate` is the first failure in this sequence, and `freezeOff` is
 * deliberately last.
 */
export const GATE_ORDER = [
  'enrolled',
  'botAllowlisted',
  'ticketLinked',
  'conventionalTitle',
  'changeClass',
  'pathsAllowed',
  'size',
  'semverCap',
  'classificationPermits',
  'tierFloor',
  'freezeOff',
] as const;

export type GateName = (typeof GATE_ORDER)[number];

/**
 * `skipped` is not `fail`: it means the gate could not be computed, usually
 * because the change class is unclassified. Conflating the two would make the
 * shadow report claim rules were violated when they were never evaluated.
 */
export type GateVerdict = 'pass' | 'fail' | 'unknown' | 'skipped';

export interface GateResult {
  verdict: GateVerdict;
  /** What the gate observed — the raw value Phase 1 threshold tuning queries. */
  value?: unknown;
}

export interface EligibilityResult {
  verdict: 'candidate' | 'not-candidate';
  changeClass: string;
  gates: Record<GateName, GateResult>;
  /** First failure in GATE_ORDER, or null when every gate passed. */
  failedGate: GateName | null;
}

export interface GateInput {
  repoFullName: string;
  title: string;
  body: string;
  /** `pull_request.user.login` — e.g. `dependabot[bot]`. */
  authorLogin: string;
  files: ChangedFile[];
  enrollment: EnrollmentRecord | undefined;
  rules: Rules;
  classification: ClassificationResult;
}

const CONVENTIONAL = /^(feat|fix|chore|docs|style|refactor|perf|test|build|ci|revert)(\([^)]*\))?!?: .+/;
const RANK: Record<SemverLevel, number> = { none: 0, patch: 1, minor: 2, major: 3 };

const pass = (value?: unknown): GateResult => ({ verdict: 'pass', value });
const fail = (value?: unknown): GateResult => ({ verdict: 'fail', value });
const skip = (): GateResult => ({ verdict: 'skipped' });
const gate = (ok: boolean, value?: unknown): GateResult => (ok ? pass(value) : fail(value));

/**
 * Run every gate and assemble the verdict.
 *
 * Args:
 *   input: PR metadata, changed files, enrollment record, rules, classification.
 * Returns:
 *   Every gate's verdict and observed value, the change class, and the first
 *   failing gate.
 */
export function runGates(input: GateInput): EligibilityResult {
  const { rules, enrollment, classification } = input;
  const gates = {} as Record<GateName, GateResult>;

  // 1 — enrolled. `mode: off` is a fail, not an absence: paused and unknown are
  // different states and the record says which.
  gates.enrolled = gate(
    enrollment !== undefined && enrollment.mode !== 'off',
    { present: enrollment !== undefined, mode: enrollment?.mode ?? null },
  );

  // 2 — bot allowlist.
  const bot = rules.bots.find((b) => b.login === input.authorLogin);
  gates.botAllowlisted = gate(bot !== undefined, input.authorLogin);

  // 3 — ticket linkage. Bots may be exempted per entry, which is what makes
  // dependabot PRs evaluable at all: they never carry a Jira key.
  const ticketRequired = bot?.ticketRequired ?? true;
  const hasKey = containsJiraKey(`${input.title} ${input.body}`);
  gates.ticketLinked = gate(!ticketRequired || hasKey, { required: ticketRequired, found: hasKey });

  // 4 — conventional title. The squash title feeds semantic-release, so a
  // non-conventional one silently breaks release automation downstream.
  gates.conventionalTitle = gate(CONVENTIONAL.test(input.title));

  // 5 — change class recognised.
  const className = classification.changeClass;
  const cls: ChangeClass | undefined = rules.changeClasses[className];
  const classified = className !== 'unclassified' && cls !== undefined;
  gates.changeClass = gate(classified, { class: className, reason: classification.reason ?? null });

  if (!classified || cls === undefined) {
    // Gates 6-10 all read the class's thresholds. Without a class there is
    // nothing to compare against — skipped, not failed.
    gates.pathsAllowed = skip();
    gates.size = skip();
    gates.semverCap = skip();
    gates.classificationPermits = skip();
    gates.tierFloor = skip();
  } else {
    // 6 — paths. Fail closed: every changed file must match an allow pattern,
    // and none may match a deny pattern.
    const offending = input.files.filter(
      (f) => !matchesAny(f.filename, cls.allowedPaths) || matchesAny(f.filename, cls.deniedPaths),
    );
    gates.pathsAllowed = gate(offending.length === 0, offending.map((f) => f.filename));

    // 7 — size, over authored files only. A lockfile's thousand changed lines
    // carry no review burden; counting them makes every ceiling meaningless.
    const authored = input.files.filter((f) => !matchesAny(f.filename, rules.generatedPaths));
    const fileCount = authored.length;
    const lineCount = authored.reduce((sum, f) => sum + f.additions + f.deletions, 0);
    gates.size = gate(
      fileCount <= cls.maxFiles && lineCount <= cls.maxLines,
      { files: fileCount, lines: lineCount, maxFiles: cls.maxFiles, maxLines: cls.maxLines },
    );

    // 8 — semver cap, from the manifest diff only.
    gates.semverCap = gate(
      RANK[classification.maxDelta] <= RANK[cls.semverCap],
      { delta: classification.maxDelta, cap: cls.semverCap },
    );

    // 9 — classification permits this class. An empty list permits nothing,
    // which is how dep-major is denied everywhere in v1.
    const repoClass = enrollment?.classification;
    gates.classificationPermits = gate(
      repoClass !== undefined && cls.classifications.includes(repoClass),
      { repo: repoClass ?? null, permitted: cls.classifications },
    );

    // 10 — CI-trust tier floor.
    const tier = enrollment?.ciTrustTier;
    gates.tierFloor = gate(
      tier !== undefined && tier >= cls.tierFloor,
      { have: tier ?? null, need: cls.tierFloor },
    );
  }

  // 11 — freeze, last.
  gates.freezeOff = gate(rules.freeze === false, { freeze: rules.freeze });

  const failedGate = GATE_ORDER.find((name) => gates[name].verdict === 'fail') ?? null;

  return {
    verdict: failedGate === null ? 'candidate' : 'not-candidate',
    changeClass: className,
    gates,
    failedGate,
  };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test && pnpm run typecheck`
Expected: PASS, 18 tests in `tests/gates.test.ts`

- [ ] **Step 5: Commit**

```bash
git add src/gates.ts tests/gates.test.ts
git commit -m "feat: the eleven eligibility gates (PLAT-1190)"
```

---

### Task 8: Render the check-run rationale

Its own task because PLAT-1190's readability criterion is a human judgement, and it deserves a review surface separate from the logic that feeds it.

**Files:**
- Create: `src/render.ts`
- Create: `tests/render.test.ts`

**Interfaces:**
- Consumes: `EligibilityResult`, `GATE_ORDER` (Task 7); `ClassificationResult` (Task 6); `CheckOutput` from `src/checks.ts`
- Produces:
  - `renderEligibility(result: EligibilityResult, classification: ClassificationResult): CheckOutput`
  - `renderRiskPlaceholder(): CheckOutput`

- [ ] **Step 1: Write the failing tests**

Create `tests/render.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { renderEligibility, renderRiskPlaceholder } from '../src/render.js';
import { runGates } from '../src/gates.js';
import { classify } from '../src/classify.js';
import { rules } from '../src/rules.js';
import { enrollmentFor } from '../src/enrollment.js';

const DEMO = 'bankrate/platform-cicd-v2-demo';
const payload = (n: number) => JSON.parse(readFileSync(`tests/fixtures/pr-${n}-payload.json`, 'utf8'));
const files = (n: number) => JSON.parse(readFileSync(`tests/fixtures/pr-${n}-files.json`, 'utf8'));

function render(n: number) {
  const pr = payload(n);
  const f = files(n);
  const classification = classify(f, rules().generatedPaths);
  const result = runGates({
    repoFullName: DEMO, title: pr.title, body: pr.body ?? '', authorLogin: pr.user.login,
    files: f, enrollment: enrollmentFor(DEMO), rules: rules(), classification,
  });
  return renderEligibility(result, classification);
}

test('a candidate leads with the good news and names the class', () => {
  const out = render(27);
  assert.match(out.title, /would have been a candidate/i);
  assert.match(out.summary, /dep-minor/);
  assert.match(out.summary, /fastify/, 'names the largest bump concretely');
});

test('a rejection names the failing gate in plain language', () => {
  const out = render(32);
  assert.match(out.title, /not a candidate/i);
  assert.match(out.summary, /major/i);
  assert.match(out.summary, /@semantic-release\/changelog/);
  assert.match(out.summary, /sandbox/);
});

test('a human-authored PR is told plainly why, without jargon', () => {
  const out = render(37);
  assert.match(out.title, /not a candidate/i);
  assert.match(out.summary, /iscooter/);
  assert.match(out.summary, /automation account/i);
});

test('every rendering states it never blocks and links the epic', () => {
  for (const n of [27, 32, 37]) {
    const out = render(n);
    assert.match(out.summary, /never block|does not block|informational/i, `PR ${n}`);
    assert.match(out.summary, /PLAT-1184/, `PR ${n}`);
  }
});

test('every rendering reports the gate tally', () => {
  const out = render(32);
  assert.match(out.summary, /9 of 11/);
});

test('titles stay inside GitHub check-run limits', () => {
  for (const n of [27, 32, 37]) {
    assert.ok(render(n).title.length <= 255, `PR ${n} title length`);
  }
});

test('the risk placeholder scopes itself to risk, not the whole service', () => {
  const out = renderRiskPlaceholder();
  assert.match(out.summary, /risk/i);
  assert.match(out.summary, /PLAT-1191/);
  assert.match(out.summary, /never block/i);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — `Cannot find module '../src/render.js'`

- [ ] **Step 3: Write the implementation**

Create `src/render.ts`:

```ts
// Turns an eligibility result into check-run text.
//
// The audience is an engineer who has never heard of this project and just
// clicked a check on their PR. Every rendering must answer three questions
// without follow-up: what is this, what did it decide, and do I need to do
// anything. PLAT-1190 makes that an acceptance criterion, so it is rendered
// here rather than assembled ad hoc at the call site.
import type { CheckOutput } from './checks.js';
import type { EligibilityResult } from './gates.js';
import { GATE_ORDER } from './gates.js';
import type { ClassificationResult, DependencyBump } from './classify.js';

const EPIC = '[PLAT-1184](https://redventures.atlassian.net/browse/PLAT-1184)';
const NEVER_BLOCKS =
  'This check is informational. It is **not required** and **will never block your pull request**.';

/** The bump that set the PR's class — the one worth naming in the summary. */
function largestBump(classification: ClassificationResult): DependencyBump | undefined {
  return classification.bumps.find((b) => b.level === classification.maxDelta);
}

function tally(result: EligibilityResult): string {
  const passed = GATE_ORDER.filter((name) => result.gates[name].verdict === 'pass').length;
  return `${passed} of ${GATE_ORDER.length}`;
}

function candidateSummary(result: EligibilityResult, classification: ClassificationResult): string {
  const bump = largestBump(classification);
  const count = classification.bumps.length;
  const detail = bump
    ? `${count} dependency ${count === 1 ? 'update' : 'updates'}, largest jump **${bump.level}** (\`${bump.name}\` ${bump.from} → ${bump.to}).`
    : `Change class \`${result.changeClass}\`.`;

  return [
    `**${detail}**`,
    '',
    `All ${GATE_ORDER.length} eligibility gates passed, so an automated merge policy *would have* treated this pull request as a candidate.`,
    '',
    'Nothing was approved and nothing was merged — the service is running in shadow mode, recording what it would have done so the decision can be reviewed before any automation is switched on.',
    '',
    NEVER_BLOCKS,
    '',
    `Tracking: ${EPIC}.`,
  ].join('\n');
}

function rejectionDetail(result: EligibilityResult, classification: ClassificationResult): string {
  const gate = result.failedGate;
  const value = gate ? result.gates[gate].value : undefined;

  switch (gate) {
    case 'enrolled':
      return 'This repository is not enrolled in merge-policy evaluation.';
    case 'botAllowlisted':
      return `This pull request was opened by \`${String(value)}\`, which is not an allow-listed automation account. The merge-policy service only evaluates pull requests opened by automation.`;
    case 'ticketLinked':
      return 'No Jira ticket is referenced in the title or description, and this author is required to link one.';
    case 'conventionalTitle':
      return 'The pull request title is not in Conventional Commits form (e.g. `fix: ...`, `chore(deps): ...`). The squash title feeds release automation, so it has to parse.';
    case 'changeClass': {
      const reason = (value as { reason?: string } | undefined)?.reason;
      return `The changes in this pull request do not match any recognised change class${reason ? ` — ${reason}` : ''}.`;
    }
    case 'pathsAllowed':
      return `Files outside the permitted set for \`${result.changeClass}\` were changed: ${(value as string[]).map((f) => `\`${f}\``).join(', ')}.`;
    case 'size': {
      const v = value as { files: number; lines: number; maxFiles: number; maxLines: number };
      return `This pull request changes ${v.files} file(s) and ${v.lines} line(s), above the ceiling for \`${result.changeClass}\` (${v.maxFiles} files, ${v.maxLines} lines). Generated files such as lockfiles are not counted.`;
    }
    case 'semverCap': {
      const v = value as { delta: string; cap: string };
      return `The largest version jump is **${v.delta}**, above the \`${v.cap}\` ceiling for \`${result.changeClass}\`.`;
    }
    case 'classificationPermits': {
      const bump = largestBump(classification);
      const v = value as { repo: string | null };
      const named = bump ? ` (\`${bump.name}\` ${bump.from} → ${bump.to})` : '';
      return `The largest version jump in this pull request is a **${classification.maxDelta}**${named}. Changes of class \`${result.changeClass}\` are not eligible for automation on a \`${v.repo}\` repository.`;
    }
    case 'tierFloor': {
      const v = value as { have: number | null; need: number };
      return `This repository is at CI-trust tier ${v.have}; \`${result.changeClass}\` requires tier ${v.need} or above.`;
    }
    case 'freezeOff':
      return 'Merge-policy automation is currently frozen org-wide, so nothing is a candidate.';
    default:
      return 'This pull request did not meet the eligibility rules.';
  }
}

/** Render the `merge-policy/eligibility` check body. */
export function renderEligibility(
  result: EligibilityResult,
  classification: ClassificationResult,
): CheckOutput {
  if (result.verdict === 'candidate') {
    return {
      title: `Would have been a candidate — ${result.changeClass}`,
      summary: candidateSummary(result, classification),
    };
  }

  const title = result.failedGate === 'botAllowlisted'
    ? 'Not a candidate — author is not an automation account'
    : `Not a candidate — ${result.changeClass}`;

  return {
    title: title.slice(0, 255),
    summary: [
      `**${rejectionDetail(result, classification)}**`,
      '',
      `Gates passed: ${tally(result)} · First failure: \`${result.failedGate}\``,
      '',
      NEVER_BLOCKS,
      '',
      `Tracking: ${EPIC}.`,
    ].join('\n'),
  };
}

/**
 * Render the `merge-policy/risk` placeholder.
 *
 * Scoped to the risk evaluator specifically — saying the whole service is not
 * connected would now be false, since eligibility is.
 */
export function renderRiskPlaceholder(): CheckOutput {
  return {
    title: 'Risk heuristics — not yet connected',
    summary: [
      'The merge-policy service evaluates two things: whether a pull request is *eligible* for automated merge, and how *risky* the change is.',
      '',
      'Eligibility is live — see the `merge-policy/eligibility` check on this pull request. The risk heuristics are not connected yet ([PLAT-1191](https://redventures.atlassian.net/browse/PLAT-1191)), so there is no risk grade to report.',
      '',
      NEVER_BLOCKS,
      '',
      `Tracking: ${EPIC}.`,
    ].join('\n'),
  };
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test`
Expected: PASS, 7 tests

- [ ] **Step 5: Read the output as a stranger would**

```bash
node --import tsx -e "
import {readFileSync} from 'fs';
import {renderEligibility} from './src/render.ts';
import {runGates} from './src/gates.ts';
import {classify} from './src/classify.ts';
import {rules} from './src/rules.ts';
import {enrollmentFor} from './src/enrollment.ts';
const DEMO='bankrate/platform-cicd-v2-demo';
for (const n of [27,32,37]) {
  const pr=JSON.parse(readFileSync(\`tests/fixtures/pr-\${n}-payload.json\`,'utf8'));
  const f=JSON.parse(readFileSync(\`tests/fixtures/pr-\${n}-files.json\`,'utf8'));
  const c=classify(f,rules().generatedPaths);
  const r=runGates({repoFullName:DEMO,title:pr.title,body:pr.body??'',authorLogin:pr.user.login,files:f,enrollment:enrollmentFor(DEMO),rules:rules(),classification:c});
  const o=renderEligibility(r,c);
  console.log('='.repeat(70)); console.log('PR '+n+': '+o.title); console.log(); console.log(o.summary); console.log();
}"
```

Read all three. If any would leave a stranger asking "so what do I do?", fix the wording now — this is where PLAT-1190's readability criterion is actually met or missed, and no test can judge it for you.

- [ ] **Step 6: Commit**

```bash
git add src/render.ts tests/render.test.ts
git commit -m "feat: plain-language check-run rationale for eligibility verdicts (PLAT-1190)"
```

---

### Task 9: The evaluation ledger

Minimal PLAT-1193: one eval record per evaluation, with every gate's value.

**Files:**
- Create: `src/ledger.ts`
- Create: `tests/ledger.test.ts`

**Interfaces:**
- Consumes: `EligibilityResult` (Task 7), `ClassificationResult` (Task 6), `DynamoSender` from `src/deliveries.ts`
- Produces:
  - `recordEvaluation(record: EvalRecord, send?: DynamoSender): Promise<void>`
  - `interface EvalRecord { repoFullName; prNumber; headSha; rulesSha; mode; eligibility; classification }`

- [ ] **Step 1: Write the failing tests**

Create `tests/ledger.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { recordEvaluation } from '../src/ledger.js';
import { GATE_ORDER } from '../src/gates.js';
import type { EligibilityResult } from '../src/gates.js';

process.env.EVALUATIONS_TABLE = 'zapp-evaluations-test';

function fakeSend(reject?: Error) {
  const calls: any[] = [];
  return { calls, send: async (cmd: any) => { calls.push(cmd); if (reject) throw reject; return {}; } };
}

const eligibility = (): EligibilityResult => ({
  verdict: 'not-candidate',
  changeClass: 'dep-major',
  failedGate: 'classificationPermits',
  gates: Object.fromEntries(GATE_ORDER.map((g) => [g, { verdict: 'pass', value: 1 }])) as any,
});

const record = () => ({
  repoFullName: 'bankrate/platform-cicd-v2-demo',
  prNumber: 32,
  headSha: 'f00d42',
  rulesSha: 'a'.repeat(40),
  mode: 'shadow' as const,
  eligibility: eligibility(),
  classification: { changeClass: 'dep-major', maxDelta: 'major' as const, bumps: [] },
});

test('keys on repo and PR, sorted by evaluation time', async () => {
  const { send, calls } = fakeSend();
  await recordEvaluation(record(), send);
  const item = calls[0].input.Item;
  assert.equal(item.pk.S, 'repo#bankrate/platform-cicd-v2-demo#pr#32');
  assert.match(item.sk.S, /^eval#\d{4}-\d{2}-\d{2}T/);
  assert.equal(calls[0].input.TableName, 'zapp-evaluations-test');
});

test('stamps rulesSha at the top level so the GSI can key on it', async () => {
  const { send, calls } = fakeSend();
  await recordEvaluation(record(), send);
  assert.equal(calls[0].input.Item.rulesSha.S, 'a'.repeat(40));
});

test('carries every gate verdict, not just the failure', async () => {
  const { send, calls } = fakeSend();
  await recordEvaluation(record(), send);
  const stored = JSON.parse(calls[0].input.Item.eligibility.S);
  assert.equal(Object.keys(stored.gates).length, GATE_ORDER.length);
  assert.equal(stored.failedGate, 'classificationPermits');
});

test('records the head sha so a verdict never applies to code it did not see', async () => {
  const { send, calls } = fakeSend();
  await recordEvaluation(record(), send);
  assert.equal(calls[0].input.Item.headSha.S, 'f00d42');
});

test('a write failure throws — the caller decides whether to swallow it', async () => {
  const { send } = fakeSend(new Error('ProvisionedThroughputExceededException'));
  await assert.rejects(() => recordEvaluation(record(), send), /ProvisionedThroughput/);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — `Cannot find module '../src/ledger.js'`

- [ ] **Step 3: Write the implementation**

Create `src/ledger.ts`:

```ts
// The decision ledger: one record per evaluation, carrying a value per gate.
//
// Minimal slice of PLAT-1193 (T9). The point of the shadow phase is the
// dataset, not the check run — "which gate blocks the most pull requests?" and
// "what did we decide under rules SHA X?" are queries over this table.
//
// Scoped short of full T9: no S3 archive, no `outcome#` records, no verdict
// GSI. Those need T9 proper and T11.
//
// This function THROWS on failure. The decision to swallow that lives at the
// call site in evaluate.ts, where it is visible — see the comment there.
import { PutItemCommand } from '@aws-sdk/client-dynamodb';
import { client, type DynamoSender } from './deliveries.js';
import type { EligibilityResult } from './gates.js';
import type { ClassificationResult } from './classify.js';

const defaultSend: DynamoSender = (cmd) => client.send(cmd as never);

/** One evaluation, as written to the ledger. */
export interface EvalRecord {
  repoFullName: string;
  prNumber: number;
  headSha: string;
  rulesSha: string;
  mode: 'shadow';
  eligibility: EligibilityResult;
  classification: ClassificationResult;
}

/**
 * Write one evaluation record.
 *
 * The nested gate map and classification are stored as JSON strings rather than
 * DynamoDB maps: they are read back whole for analysis and never queried by
 * inner attribute, so marshalling every gate into an AttributeValue tree buys
 * nothing. `rulesSha` and `headSha` stay top-level scalars because the GSI and
 * the head-SHA lookups do need them.
 *
 * Raises:
 *   Error: On any DynamoDB failure.
 */
export async function recordEvaluation(
  record: EvalRecord,
  send: DynamoSender = defaultSend,
): Promise<void> {
  await send(new PutItemCommand({
    TableName: process.env.EVALUATIONS_TABLE!,
    Item: {
      pk: { S: `repo#${record.repoFullName}#pr#${record.prNumber}` },
      sk: { S: `eval#${new Date().toISOString()}` },
      repo: { S: record.repoFullName },
      prNumber: { N: String(record.prNumber) },
      headSha: { S: record.headSha },
      rulesSha: { S: record.rulesSha },
      mode: { S: record.mode },
      verdict: { S: record.eligibility.verdict },
      changeClass: { S: record.eligibility.changeClass },
      failedGate: record.eligibility.failedGate
        ? { S: record.eligibility.failedGate }
        : { NULL: true },
      eligibility: { S: JSON.stringify(record.eligibility) },
      classification: { S: JSON.stringify(record.classification) },
    },
  }));
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pnpm test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/ledger.ts tests/ledger.test.ts
git commit -m "feat: write one eval record per evaluation (PLAT-1193)"
```

---

### Task 10: Wire it together

Replaces the placeholder `evaluate()` and threads PR context through the worker.

**Files:**
- Modify: `src/evaluate.ts` (full rewrite)
- Modify: `src/worker.ts` (build the eval context; inject `evaluate`)
- Modify: `src/index.ts` (wire the new dep)
- Modify: `tests/worker.test.ts` (stub the injected `evaluate`)
- Create: `tests/evaluate.test.ts`

**Interfaces:**
- Consumes: everything from Tasks 2–9
- Produces:
  - `evaluate(ctx: EvalContext, deps?: EvaluateDeps): Promise<ShadowVerdict[]>`
  - `interface EvalContext { repoFullName; prNumber; headSha; title; body; authorLogin }`
  - `interface EvaluateDeps { fetchPrFiles; recordEvaluation }`
  - `ELIGIBILITY_CHECK`, `RISK_CHECK`, `ShadowVerdict` unchanged

- [ ] **Step 1: Write the failing tests**

Create `tests/evaluate.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { evaluate, ELIGIBILITY_CHECK, RISK_CHECK } from '../src/evaluate.js';

const DEMO = 'bankrate/platform-cicd-v2-demo';
const payload = (n: number) => JSON.parse(readFileSync(`tests/fixtures/pr-${n}-payload.json`, 'utf8'));
const files = (n: number) => JSON.parse(readFileSync(`tests/fixtures/pr-${n}-files.json`, 'utf8'));

function ctx(n: number, repo = DEMO) {
  const pr = payload(n);
  return { repoFullName: repo, prNumber: pr.number, headSha: pr.head.sha,
           title: pr.title, body: pr.body ?? '', authorLogin: pr.user.login };
}

function deps(n: number, opts: { ledgerFails?: boolean } = {}) {
  const recorded: any[] = [];
  return {
    recorded,
    deps: {
      fetchPrFiles: async () => files(n),
      recordEvaluation: async (r: any) => {
        if (opts.ledgerFails) throw new Error('ProvisionedThroughputExceededException');
        recorded.push(r);
      },
    },
  };
}

test('returns both checks, eligibility first', async () => {
  const { deps: d } = deps(27);
  const verdicts = await evaluate(ctx(27), d as any);
  assert.deepEqual(verdicts.map((v) => v.name), [ELIGIBILITY_CHECK, RISK_CHECK]);
});

test('PR #27 renders as a candidate', async () => {
  const { deps: d } = deps(27);
  const [eligibility] = await evaluate(ctx(27), d as any);
  assert.match(eligibility!.output.title, /would have been a candidate/i);
});

test('PR #32 renders as a rejection naming the class', async () => {
  const { deps: d } = deps(32);
  const [eligibility] = await evaluate(ctx(32), d as any);
  assert.match(eligibility!.output.title, /not a candidate — dep-major/i);
});

test('writes exactly one eval record per evaluation, stamped with rulesSha', async () => {
  const { deps: d, recorded } = deps(27);
  await evaluate(ctx(27), d as any);
  assert.equal(recorded.length, 1);
  assert.match(recorded[0].rulesSha, /^[0-9a-f]{40}$/);
  assert.equal(recorded[0].headSha, payload(27).head.sha);
  assert.equal(recorded[0].eligibility.verdict, 'candidate');
});

test('a ledger failure does not lose the check run', async () => {
  const { deps: d } = deps(27, { ledgerFails: true });
  const verdicts = await evaluate(ctx(27), d as any);
  assert.equal(verdicts.length, 2, 'the checks still post');
});

test('an unenrolled repo is evaluated and rejected without fetching files', async () => {
  let fetched = false;
  const d = {
    fetchPrFiles: async () => { fetched = true; return []; },
    recordEvaluation: async () => {},
  };
  const [eligibility] = await evaluate(ctx(27, 'bankrate/not-enrolled'), d as any);
  assert.equal(fetched, false, 'no GitHub call for a repo we do not evaluate');
  assert.match(eligibility!.output.summary, /not enrolled/i);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pnpm test`
Expected: FAIL — `evaluate` does not accept arguments

- [ ] **Step 3: Rewrite `src/evaluate.ts`**

```ts
// Orchestrates one pull request's shadow evaluation: fetch the diff, classify
// it, run the gates, render both checks, and record the result.
//
// PLAT-1189 (rules), PLAT-1190 (gates), and the minimal PLAT-1193 ledger meet
// here. The risk half is still a placeholder until PLAT-1191.
import type { CheckOutput } from './checks.js';
import { fetchPrFiles } from './pr-files.js';
import { recordEvaluation } from './ledger.js';
import { classify } from './classify.js';
import { runGates } from './gates.js';
import { renderEligibility, renderRiskPlaceholder } from './render.js';
import { rules, rulesSha } from './rules.js';
import { enrollmentFor } from './enrollment.js';
import { log } from './log.js';

export const ELIGIBILITY_CHECK = 'merge-policy/eligibility';
export const RISK_CHECK = 'merge-policy/risk';

/** One check run's name and rendered body. */
export interface ShadowVerdict {
  name: string;
  output: CheckOutput;
}

/** Everything about the pull request the evaluator needs, from the payload. */
export interface EvalContext {
  repoFullName: string;
  prNumber: number;
  headSha: string;
  title: string;
  body: string;
  /** `pull_request.user.login`. */
  authorLogin: string;
}

/** Injectable collaborators (real implementations by default). */
export interface EvaluateDeps {
  fetchPrFiles: typeof fetchPrFiles;
  recordEvaluation: typeof recordEvaluation;
}

const defaultDeps: EvaluateDeps = { fetchPrFiles, recordEvaluation };

/**
 * Evaluate one pull request and produce both shadow check runs.
 *
 * Args:
 *   ctx: Pull request identity and metadata from the webhook payload.
 *   deps: Injected collaborators (defaults to the real ones).
 * Returns:
 *   The two check runs to post, eligibility first.
 * Raises:
 *   Error: If the GitHub files call fails — the worker releases its claim and
 *     SQS retries. A ledger failure does NOT raise; see below.
 */
export async function evaluate(
  ctx: EvalContext,
  deps: EvaluateDeps = defaultDeps,
): Promise<ShadowVerdict[]> {
  const enrollment = enrollmentFor(ctx.repoFullName);
  const policy = rules();

  // Skip the GitHub call entirely for a repo we do not evaluate: gate 1 fails
  // regardless, and an unenrolled repo should cost us nothing.
  const files = enrollment === undefined || enrollment.mode === 'off'
    ? []
    : await deps.fetchPrFiles(ctx.repoFullName, ctx.prNumber);

  const classification = classify(files, policy.generatedPaths);

  const eligibility = runGates({
    repoFullName: ctx.repoFullName,
    title: ctx.title,
    body: ctx.body,
    authorLogin: ctx.authorLogin,
    files,
    enrollment,
    rules: policy,
    classification,
  });

  // Deliberately best-effort, and the ONLY failure in this service handled this
  // way. The check run is what a human sees; losing it because a table write
  // failed would trade the user-visible product for a record we can rebuild by
  // replaying the delivery. Logged loudly so it is never silent.
  try {
    await deps.recordEvaluation({
      repoFullName: ctx.repoFullName,
      prNumber: ctx.prNumber,
      headSha: ctx.headSha,
      rulesSha: rulesSha(),
      mode: 'shadow',
      eligibility,
      classification,
    });
  } catch (err) {
    log('error', 'ledger_write_failed', {
      repo: ctx.repoFullName,
      pr: ctx.prNumber,
      head_sha: ctx.headSha,
      error: err instanceof Error ? err.message : String(err),
    });
  }

  log('info', 'evaluated', {
    repo: ctx.repoFullName,
    pr: ctx.prNumber,
    head_sha: ctx.headSha,
    rules_sha: rulesSha(),
    verdict: eligibility.verdict,
    change_class: eligibility.changeClass,
    failed_gate: eligibility.failedGate,
  });

  return [
    { name: ELIGIBILITY_CHECK, output: renderEligibility(eligibility, classification) },
    { name: RISK_CHECK, output: renderRiskPlaceholder() },
  ];
}
```

- [ ] **Step 4: Thread the context through `src/worker.ts`**

`evaluate` is now injected rather than imported directly, so worker tests stay pure.

Replace the `evaluate` import with a type-only import and add it to `WorkerDeps`:

```ts
import type { evaluate } from './evaluate.js';
```

```ts
export interface WorkerDeps {
  claimDelivery: typeof claimDelivery;
  confirmDelivery: typeof confirmDelivery;
  releaseDelivery: typeof releaseDelivery;
  postShadowCheck: typeof postShadowCheck;
  isEnrolled: typeof isEnrolled;
  evaluate: typeof evaluate;
}
```

Then replace the evaluation block in `handleDelivery` — the `if (!deps.isEnrolled(...))` early return **stays** (it avoids the work entirely for unenrolled repos), and the loop becomes:

```ts
  const verdicts = await deps.evaluate({
    repoFullName,
    prNumber: payload.pull_request?.number,
    headSha,
    title: payload.pull_request?.title ?? '',
    body: payload.pull_request?.body ?? '',
    authorLogin: payload.pull_request?.user?.login ?? '',
  });

  for (const verdict of verdicts) {
    await deps.postShadowCheck(repoFullName, headSha, verdict.name, verdict.output);
  }
```

- [ ] **Step 5: Wire the new dep in `src/index.ts`**

Add `import { evaluate } from './evaluate.js';` and add `evaluate` to the `createWorker({ ... })` call.

- [ ] **Step 6: Update `tests/worker.test.ts`**

The existing `harness()` builds `createWorker({...})`. Add an `evaluate` stub to it, and update the two tests that assert on posted check names:

```ts
    evaluate: async () => ([
      { name: 'merge-policy/eligibility', output: { title: 't', summary: 's' } },
      { name: 'merge-policy/risk', output: { title: 't', summary: 's' } },
    ]),
```

Every existing assertion on `state.posts` continues to hold — the stub returns the same two names in the same order. Add one test:

```ts
test('passes the PR metadata the evaluator needs', async () => {
  const seen: any[] = [];
  const worker = createWorker({
    claimDelivery: async () => true,
    confirmDelivery: async () => {},
    releaseDelivery: async () => {},
    isEnrolled: () => true,
    postShadowCheck: async () => {},
    evaluate: async (ctx: any) => { seen.push(ctx); return []; },
  } as any);
  await worker(sqsEvent(prPayload()));
  assert.equal(seen[0].repoFullName, DEMO);
  assert.equal(seen[0].headSha, 'f00d42');
  assert.equal(seen[0].prNumber, 7);
});
```

`prPayload()` in that file currently emits `pull_request: { number: 7, head: { sha } }`. Extend it to also carry `title`, `body` and `user`:

```ts
function prPayload({ action = 'opened', repo = DEMO, sha = 'f00d42' } = {}) {
  return JSON.stringify({
    action,
    pull_request: {
      number: 7,
      head: { sha },
      title: 'chore(deps): bump things',
      body: '',
      user: { login: 'dependabot[bot]' },
    },
    repository: { full_name: repo },
  });
}
```

- [ ] **Step 7: Run the full suite**

Run: `pnpm test && pnpm run typecheck && pnpm run build`
Expected: PASS, clean typecheck, `dist/index.js` written

- [ ] **Step 8: Commit**

```bash
git add src/evaluate.ts src/worker.ts src/index.ts tests/evaluate.test.ts tests/worker.test.ts
git commit -m "feat: real eligibility verdicts replace the placeholder evaluator (PLAT-1190)"
```

---

### Task 11: Infrastructure

**Files:**
- Modify: `infrastructure/terraform/dynamodb.tf` (add the evaluations table)
- Modify: `infrastructure/terraform/iam.tf` (grant writes)
- Modify: `infrastructure/terraform/main.tf` (env vars: add `EVALUATIONS_TABLE`, remove `ENROLLED_REPOS`)
- Modify: `infrastructure/terraform/vars.tf` (remove `enrolled_repos`)
- Modify: `infrastructure/terraform/outputs.tf` (add the table output)

**Interfaces:**
- Consumes: `EVALUATIONS_TABLE` from Task 9
- Produces: the deployed table and GSI

- [ ] **Step 1: Append the evaluations table to `dynamodb.tf`**

```hcl
# The decision ledger (minimal PLAT-1193). One record per evaluation, carrying
# a verdict and observed value for all eleven gates.
#
# No TTL: this table IS the deliverable of the shadow phase. The delivery-ID
# table above expires its records because they are plumbing; these are evidence.
resource "aws_dynamodb_table" "evaluations" {
  name         = "${local.name}-evaluations"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  attribute {
    name = "rulesSha"
    type = "S"
  }

  # "All evaluations made under rules SHA X" is one query — PLAT-1193's second
  # acceptance criterion, and the thing that makes a rules change auditable.
  global_secondary_index {
    name            = "gsi-rules-sha"
    projection_type = "ALL"

    key_schema {
      attribute_name = "rulesSha"
      key_type       = "HASH"
    }

    key_schema {
      attribute_name = "sk"
      key_type       = "RANGE"
    }
  }

  point_in_time_recovery {
    enabled = var.environment == "prod"
  }
}
```

Note the `key_schema` block form rather than the deprecated `hash_key`/`range_key` GSI attributes — `platform-agent`'s `dynamodb.tf` documents this, confirmed against the provider schema.

- [ ] **Step 2: Grant the write in `iam.tf`**

Add a statement to the existing `data "aws_iam_policy_document" "lambda_ingestion"`:

```hcl
  # PutItem only: the service writes evidence and never reads it back. Analysis
  # queries run from a console or a separate reader, not from this Lambda.
  statement {
    sid       = "WriteEvaluations"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.evaluations.arn]
  }
```

- [ ] **Step 3: Update the env vars in `main.tf`**

In the `module "lambda"` `env_vars` block, **remove** `ENROLLED_REPOS = var.enrolled_repos` and **add**:

```hcl
    EVALUATIONS_TABLE = aws_dynamodb_table.evaluations.name
```

Enrollment now comes from `policy-rules.yaml`, bundled into the image.

- [ ] **Step 4: Remove the dead variable from `vars.tf`**

Delete the entire `variable "enrolled_repos"` block. Leaving it would imply a control that no longer exists.

- [ ] **Step 5: Add the output to `outputs.tf`**

```hcl
output "evaluations_table" {
  value       = aws_dynamodb_table.evaluations.name
  description = "DynamoDB table holding one eval record per evaluation, with a value per gate"
}
```

- [ ] **Step 6: Validate**

```bash
cd infrastructure/terraform && terraform fmt && terraform init -backend=false && terraform validate && cd -
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 7: Confirm nothing still references the removed variable**

```bash
grep -rn 'ENROLLED_REPOS\|enrolled_repos' . --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=dist
```

Expected: no output. Any hit is a leftover that must be removed.

- [ ] **Step 8: Commit**

```bash
git add infrastructure/terraform/
git commit -m "feat: evaluations ledger table, drop the ENROLLED_REPOS variable (PLAT-1193)"
```

---

### Task 12: Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/architecture.md`, `docs/call-flows.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: everything
- Produces: nothing code-facing

- [ ] **Step 1: Update `README.md`**

The Scope section currently describes a service with no decision logic. Replace with what is now true: webhook ingestion (PLAT-1233), policy rules with build-time validation and SHA stamping (PLAT-1189), the eleven eligibility gates (PLAT-1190), enrollment from `policy-rules.yaml` (minimal PLAT-1188), and eval records (minimal PLAT-1193). Still absent: the risk heuristics (PLAT-1191), the required-checks snapshot (PLAT-1192), the full enrollment registry, the full ledger with outcomes.

Add a short "Changing the rules" section: edit `policy-rules.yaml`, run `pnpm run build:rules`, commit both it and `src/generated/rules.ts`, open a PR. Note that CI fails if the generated module is stale.

- [ ] **Step 2: Update `docs/architecture.md` and `docs/call-flows.md`**

Read both first — they were written against the ingestion-only service. Add the evaluation path: worker → `evaluate` → `fetchPrFiles` → `classify` → `runGates` → `render` + `recordEvaluation` → `postShadowCheck`. Note the single extra GitHub call and that unenrolled repos short-circuit before it.

- [ ] **Step 3: Append to `AGENTS.md`**

Following the file's own rule — concise, pointing at authoritative files rather than restating them. At minimum:

- `policy-rules.yaml` is compiled to `src/generated/rules.ts` at build time and never parsed at runtime; that is what makes an invalid rules file fail the deploy. The generated module is committed and CI fails on drift — run `pnpm run build:rules` after editing the YAML.
- `rulesSha` is the file's git blob SHA, computed from bytes (`scripts/build-rules.mjs`), because the Docker build stage has no `.git`.
- Bot logins match `pull_request.user.login`, which is `dependabot[bot]`. The `app/dependabot` form the `gh` CLI prints will never match.
- The size gate excludes `rules.generatedPaths` from both its file and line counts; a dependabot PR is ~22 authored lines and ~1,000 lockfile lines, so counting raw diff lines rejects everything.
- The ledger write in `evaluate.ts` is the one deliberately-swallowed failure in the service; everything else rethrows so SQS retries.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/ AGENTS.md
git commit -m "docs: record the rules pipeline and the eligibility evaluator (PLAT-1190)"
```

---

### Task 13: Deploy to QA and validate live

**Files:** none — verification only.

**Interfaces:**
- Consumes: everything
- Produces: the evidence closing PLAT-1189 and PLAT-1190

- [ ] **Step 1: Open the pull request**

```bash
gh pr create --repo bankrate/zapp --base main --head feat/plat-1190-eligibility-evaluator \
  --title "feat: policy rules and the eligibility evaluator (PLAT-1189, PLAT-1190)" \
  --body "Implements PLAT-1189 and PLAT-1190, plus minimal slices of PLAT-1188 (enrollment from policy-rules.yaml) and PLAT-1193 (eval records). Spec lives in firstmate: docs/superpowers/zapp/specs/2026-08-25-policy-rules-and-eligibility-design.md"
```

Confirm CI passes — including the rules drift check and the Docker build.

- [ ] **Step 2: Merge and cut a QA pre-release**

Merge, then publish a pre-release tag (e.g. `v1.2.0-rc.1`). `deploy-v2.yml` stops after QA verification when the tag contains a hyphen.

- [ ] **Step 3: Confirm the deploy and the new table**

```bash
gh run list --repo bankrate/zapp --workflow deploy.yml --limit 3
AWS_PROFILE=bankrate-qa aws dynamodb describe-table --table-name zapp-evaluations \
  --region us-east-1 --query 'Table.{Status:TableStatus,GSIs:GlobalSecondaryIndexes[].IndexName}'
```

Expected: `ACTIVE`, and `gsi-rules-sha` present.

- [ ] **Step 4: Re-evaluate the three known PRs**

Redeliver each PR's `pull_request` webhook from the App's Advanced tab
(`https://github.com/organizations/bankrate/settings/apps/neutral-planet/advanced`).

**Redelivery replays the original delivery ID, which the dedupe claim will reject as a duplicate.** Instead, force a fresh delivery per PR by closing and reopening it, or by pushing an empty commit:

```bash
gh pr close 37 --repo bankrate/platform-cicd-v2-demo && gh pr reopen 37 --repo bankrate/platform-cicd-v2-demo
```

`reopened` is in the worker's `PR_ACTIONS` set, so this produces a real evaluation with a new delivery ID.

- [ ] **Step 5: Confirm the three verdicts**

```bash
for n in 27 32 37; do
  sha=$(gh api repos/bankrate/platform-cicd-v2-demo/pulls/$n --jq .head.sha)
  echo "===== PR $n ====="
  gh api "repos/bankrate/platform-cicd-v2-demo/commits/$sha/check-runs" \
    --jq '.check_runs[] | select(.name|startswith("merge-policy/")) | "\(.name) [\(.conclusion)] \(.output.title)"'
done
```

Expected:

| PR | `merge-policy/eligibility` title |
|---|---|
| 27 | `Would have been a candidate — dep-minor` |
| 32 | `Not a candidate — dep-major` |
| 37 | `Not a candidate — author is not an automation account` |

All six check runs `neutral`.

- [ ] **Step 6: Read the rendered checks on the PR pages**

Open each PR in a browser. This is where PLAT-1190's readability criterion is actually judged — no test can do it. If a rationale would leave a stranger unsure what happened or whether they need to act, fix `src/render.ts` and redeploy.

- [ ] **Step 7: Confirm the eval records**

```bash
AWS_PROFILE=bankrate-qa aws dynamodb query --region us-east-1 \
  --table-name zapp-evaluations \
  --key-condition-expression 'pk = :pk' \
  --expression-attribute-values '{":pk":{"S":"repo#bankrate/platform-cicd-v2-demo#pr#32"}}' \
  --query 'Items[0].{sk:sk.S,verdict:verdict.S,class:changeClass.S,failed:failedGate.S,rulesSha:rulesSha.S}'
```

Expected: `verdict=not-candidate`, `class=dep-major`, `failed=classificationPermits`, and a 40-char `rulesSha`.

Confirm every gate is present:

```bash
AWS_PROFILE=bankrate-qa aws dynamodb query --region us-east-1 \
  --table-name zapp-evaluations \
  --key-condition-expression 'pk = :pk' \
  --expression-attribute-values '{":pk":{"S":"repo#bankrate/platform-cicd-v2-demo#pr#32"}}' \
  --query 'Items[0].eligibility.S' --output text | jq '.gates | keys | length'
```

Expected: `11`.

- [ ] **Step 8: Prove the rulesSha query works**

```bash
SHA=$(git -C /Users/scrosby/Projects/github/zapp hash-object policy-rules.yaml)
AWS_PROFILE=bankrate-qa aws dynamodb query --region us-east-1 \
  --table-name zapp-evaluations --index-name gsi-rules-sha \
  --key-condition-expression 'rulesSha = :s' \
  --expression-attribute-values "{\":s\":{\"S\":\"$SHA\"}}" \
  --query 'length(Items)'
```

Expected: at least 3. **This is PLAT-1193's "all evals under rules SHA X is a single query" criterion**, and it also proves the deployed `rulesSha` matches the committed file.

- [ ] **Step 9: Confirm the checks are still on no required-checks configuration**

```bash
gh api repos/bankrate/platform-cicd-v2-demo/branches/main/protection --jq '.required_status_checks.contexts'
gh api repos/bankrate/platform-cicd-v2-demo/rulesets --jq '.[] | {name, enforcement}'
```

Expected: only the three `Cycode:` contexts. This repo's required checks live in **classic branch protection**; its ruleset is `disabled`, so checking rulesets alone would be vacuous.

- [ ] **Step 10: Record the evidence**

Post the outputs of Steps 5, 7, 8 and 9 on the zapp PR or on PLAT-1190. These are the acceptance criteria; a claim without its output is not evidence.

Update PLAT-1189 and PLAT-1190 to Done. Note on PLAT-1188 and PLAT-1193 which slices this work delivered and which remain — the enrollment table and PR-sync for T4, and the S3 archive, `outcome#` records and verdict GSI for T9.

---

## Post-implementation

- **Spec B — PLAT-1191, the six risk heuristics.** Depends on the rules file this plan builds. `renderRiskPlaceholder()` and the `RISK_CHECK` verdict slot are the seams it fills.
- **PLAT-1192 (T8), the required-checks snapshot** — still unrouted; `KNOWN_UNROUTED` in `worker.ts` names the events it will need.
- **Enrolling more repos** is now a one-line PR against `policy-rules.yaml`. Worth doing once the verdicts read well, since the epic's exit criteria need ≥ 5 repos and ≥ 200 evaluations.
- **The SNS alerts topic still has no subscribers** — carried over from PLAT-1233. Both alarms are visible in CloudWatch and page nobody.
