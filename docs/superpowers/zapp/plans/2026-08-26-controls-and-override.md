# Controls and human override Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give a human two ways to stop this service — an instant freeze at fleet or repository scope, and a `do-not-automerge` label on one pull request — add the two shape checks nothing currently makes (target branch, blocking labels), and start recording commit authorship and merge window where a reader can see them.

**Architecture:** The freeze flag moves out of the build-time rules file into SSM Parameter Store, read fresh on every evaluation at two scopes combined by OR, fail-closed. Two new pure gates land before `freezeOff`, taking the gate count from 15 to 17. Two recorders — commit authorship and merge window — gate nothing but appear on both check runs in a table that says so explicitly.

**Tech Stack:** TypeScript (ESM, `node22` target), Node's built-in test runner via `node --import tsx --test`, `@aws-sdk/client-ssm`, Terraform, AWS Lambda, DynamoDB.

**Spec:** [`../specs/2026-08-26-controls-and-override-design.md`](../specs/2026-08-26-controls-and-override-design.md)

## Before you start

Base is `origin/main` at or after PR #18 (v1.7.0) — Specs D, E and F all landed. Verify:

```bash
git log --oneline -1 && ls src/signals/target-health.ts && grep -c 'GATE_ORDER' src/gates.ts
```

Expected: a commit at or after `a589755`, the file exists, and a non-zero count. If `src/signals/target-health.ts` is missing you are before Spec F and Task 6 will have nothing to render.

## Global Constraints

- **Shadow mode is unchanged.** Both check runs keep `conclusion: 'neutral'`. Nothing here adds a write permission, a merge, an approval, or a required-checks entry.
- **Fail closed on the freeze, in one specific direction.** A failed SSM *call* means frozen. An *absent* parameter means not frozen. These are different and the tests are written to catch them being swapped.
- **Freeze scopes combine as OR, never override.** Global `false` does not release a repo freeze; repo `false` does not release a global one.
- **The freeze flag is never cached.** Not for 60 seconds, not for the life of a warm container. An emergency stop that takes effect "soon" is not one.
- **`rules.freeze` is deleted, not deprecated.** Two switches with the same name in different places is how someone flips the wrong one during an incident.
- **Recorders gate nothing.** `commitAuthorship` and `wouldHaveMergedInWindow` never influence a verdict, a `failedGate`, or a risk grade.
- **The recorded-not-enforced table uses ℹ️ only.** Never ✅ ❌ ⏭️ ❓ — those belong to the gate vocabulary and would read as a verdict.
- **An invalid rules file fails the deploy, not the Lambda.** That includes the new title regex: it is compiled at build time.
- **Gate order is load-bearing.** `freezeOff` stays last, at 17.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/runtime-config.ts` | **New.** One `GetParameters` for both freeze scopes; parse; never cache; unreadable means frozen. |
| `src/commit-authorship.ts` | **New.** Record-only: who authored the commits and whether they are verified. |
| `src/merge-window.ts` | **New.** Pure predicate: is this instant inside the declared window? |
| `src/gates.ts` | Two new gates; `freezeOff` reads `GateInput` rather than `Rules`. |
| `src/pr-context.ts` | `labels`, `baseRef`, `isDraft`, `defaultBranch` on `EvalContext`, from one source per field. |
| `src/evaluate.ts` | Hoist the freeze read; call the two recorders; carry them to the ledger and the renderer. |
| `src/render.ts` | Two new gate cells; the "Recorded, not enforced" table on both checks. |
| `src/ledger.ts` | `commitAuthorship`, `wouldHaveMergedInWindow`. |
| `src/rules-types.ts` | `freeze` removed; `blockingLabels`, `blockingTitlePattern`, `mergeWindow` added; `baseBranches` on the enrolment record. |
| `scripts/build-rules.mjs` | Reject `freeze`; validate the new rules; **compile the title regex at build time**. |
| `infrastructure/terraform/iam.tf` | Scoped `ssm:GetParameters` grant. |
| `infrastructure/terraform/ssm.tf` | **New.** The global parameter, with `ignore_changes` on its value. |

---

## Task 1: The freeze flag, read from SSM

**Files:**
- Create: `src/runtime-config.ts`
- Create: `tests/runtime-config.test.ts`
- Create: `infrastructure/terraform/ssm.tf`
- Modify: `infrastructure/terraform/iam.tf`
- Modify: `infrastructure/terraform/main.tf:187-189` (the comment)
- Modify: `package.json`

**Interfaces:**
- Produces: `FreezeState`, `readFreeze(repoFullName, send?)`, `SsmSender` from `src/runtime-config.ts`.

- [ ] **Step 1: Add the SSM client**

```bash
pnpm add @aws-sdk/client-ssm
```

It joins `@aws-sdk/client-dynamodb`, `@aws-sdk/client-secrets-manager` and `@aws-sdk/client-sqs` as a runtime dependency. Confirm the bundle still builds at the end of this task.

- [ ] **Step 2: Write the failing test**

Create `tests/runtime-config.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFreeze } from '../src/runtime-config.js';

const REPO = 'bankrate/platform-cicd-v2-demo';

/** A fake SSM sender. `values` maps parameter name to stored string. */
function ssm(values: Record<string, string>, opts: { throws?: Error } = {}) {
  const calls: any[] = [];
  return {
    calls,
    send: async (cmd: any) => {
      calls.push(cmd);
      if (opts.throws) throw opts.throws;
      const asked: string[] = cmd.input.Names;
      return {
        Parameters: asked.filter((n) => n in values).map((n) => ({ Name: n, Value: values[n] })),
        InvalidParameters: asked.filter((n) => !(n in values)),
      };
    },
  };
}

test('both parameters absent means not frozen', async () => {
  const { send } = ssm({});
  const state = await readFreeze(REPO, send);
  assert.equal(state.frozen, false);
  assert.equal(state.scope, 'none');
});

test('the global flag freezes everything', async () => {
  const { send } = ssm({ '/zapp/freeze': 'true' });
  const state = await readFreeze(REPO, send);
  assert.equal(state.frozen, true);
  assert.equal(state.scope, 'global');
});

test('a repo flag freezes only that repo', async () => {
  const values = { [`/zapp/freeze/${REPO}`]: 'true' };
  assert.equal((await readFreeze(REPO, ssm(values).send)).frozen, true);
  assert.equal((await readFreeze('bankrate/other', ssm(values).send)).frozen, false);
});

test('global false plus repo true is FROZEN — OR, not override', async () => {
  // The single most invertible assertion in this file. An implementer
  // "fixing precedence" will reach for global-wins; that would let a stale
  // global false silently release a freeze somebody set during an incident.
  const { send } = ssm({ '/zapp/freeze': 'false', [`/zapp/freeze/${REPO}`]: 'true' });
  const state = await readFreeze(REPO, send);
  assert.equal(state.frozen, true);
  assert.equal(state.scope, 'repo');
});

test('global true plus repo false is FROZEN', async () => {
  const { send } = ssm({ '/zapp/freeze': 'true', [`/zapp/freeze/${REPO}`]: 'false' });
  assert.equal((await readFreeze(REPO, send)).frozen, true);
});

test('a failed call means frozen, with the error in the reason', async () => {
  // Fail-closed. If this test is ever "fixed" to expect frozen: false, the
  // brake has been removed.
  const { send } = ssm({}, { throws: new Error('AccessDeniedException') });
  const state = await readFreeze(REPO, send);
  assert.equal(state.frozen, true);
  assert.equal(state.scope, 'error');
  assert.match(state.reason!, /AccessDeniedException/);
});

test('a non-boolean value means frozen, naming the value', async () => {
  const { send } = ssm({ '/zapp/freeze': 'yes please' });
  const state = await readFreeze(REPO, send);
  assert.equal(state.frozen, true);
  assert.equal(state.scope, 'error');
  assert.match(state.reason!, /yes please/);
});

test('values are trimmed and case-insensitive', async () => {
  assert.equal((await readFreeze(REPO, ssm({ '/zapp/freeze': '  TRUE\n' }).send)).frozen, true);
  assert.equal((await readFreeze(REPO, ssm({ '/zapp/freeze': 'False' }).send)).frozen, false);
});

test('one call, naming both scopes', async () => {
  const { send, calls } = ssm({});
  await readFreeze(REPO, send);
  assert.equal(calls.length, 1, 'per-repo scope must not cost a second round trip');
  assert.deepEqual(calls[0].input.Names, ['/zapp/freeze', `/zapp/freeze/${REPO}`]);
});

test('never cached — two evaluations issue two calls', async () => {
  // A cached emergency stop is not an emergency stop.
  const { send, calls } = ssm({});
  await readFreeze(REPO, send);
  await readFreeze(REPO, send);
  assert.equal(calls.length, 2);
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `node --import tsx --test tests/runtime-config.test.ts`
Expected: FAIL — `Cannot find module '../src/runtime-config.js'`

- [ ] **Step 4: Write `src/runtime-config.ts`**

```ts
// Runtime configuration: the freeze flag, and nothing else.
//
// EVERYTHING ELSE IS COMPILE-TIME. policy-rules.yaml compiles into
// src/generated/rules.ts at build time so an invalid rules file fails the
// deploy rather than the Lambda. That is right for gates and thresholds, and
// wrong for exactly one value: an emergency stop that requires a pull request,
// a build and a deploy is not an emergency stop. Chromium's autoroller doctrine
// is stop the roller first, then revert — which only works if stopping is
// instant.
//
// TWO SCOPES, COMBINED BY OR:
//
//   /zapp/freeze                    stops everything
//   /zapp/freeze/{owner}/{repo}     stops one repository
//
// Not "override". Override means one switch can silently undo the other, and a
// stale global `false` releasing a freeze somebody set mid-incident is the
// exact failure this shape exists to prevent. Frozen means anyone who can
// freeze has frozen it.
//
// NOT a repository custom property, though `fetchRepoProperties` already runs
// every evaluation and would make it free. Two reasons: Bankrate's org
// properties are editable by repo actors by default, so the party being stopped
// could unset it; and it would make GitHub a dependency of the brake, when a
// GitHub incident is a plausible reason to want the brake pulled.
import { SSMClient, GetParametersCommand } from '@aws-sdk/client-ssm';

const FREEZE_ROOT = '/zapp/freeze';

/** What the freeze read observed. */
export interface FreezeState {
  frozen: boolean;
  /** Which scope froze it, or how the read failed. */
  scope: 'global' | 'repo' | 'none' | 'error';
  /** Present when frozen by error, or when a value could not be parsed. */
  reason?: string;
}

/** Injectable sender, so tests never touch AWS. */
export type SsmSender = (cmd: GetParametersCommand) => Promise<{
  Parameters?: { Name?: string; Value?: string }[];
  InvalidParameters?: string[];
}>;

// The CLIENT is module-level (connection reuse across warm invocations is
// free and harmless). The VALUE is never held — see readFreeze.
const client = new SSMClient({});
const defaultSend: SsmSender = (cmd) => client.send(cmd as never);

/**
 * Parse a stored flag.
 *
 * Returns null for anything that is not recognisably a boolean. Null means
 * frozen: an unparseable stop is not a released one, and silently reading
 * "yes" or "1" as false would make the brake depend on spelling.
 */
function parseFlag(value: string | undefined): boolean | null {
  const v = (value ?? '').trim().toLowerCase();
  if (v === 'true') return true;
  if (v === 'false') return false;
  return null;
}

/**
 * Read the freeze flags for one repository.
 *
 * NEVER CACHED. Both scopes ride one `GetParameters`, so per-repo scope costs
 * no extra round trip, and `GetParameters` reports found and not-found
 * separately — which is exactly the distinction needed here: not-found is
 * not-frozen, a failed call is frozen.
 *
 * Args:
 *   repoFullName: `owner/repo`.
 *   send: Injected SSM sender.
 * Returns:
 *   Whether automation is frozen, and which scope decided.
 */
export async function readFreeze(
  repoFullName: string,
  send: SsmSender = defaultSend,
): Promise<FreezeState> {
  const globalName = FREEZE_ROOT;
  const repoName = `${FREEZE_ROOT}/${repoFullName}`;

  let found: Record<string, string | undefined>;
  try {
    const res = await send(new GetParametersCommand({ Names: [globalName, repoName] }));
    found = Object.fromEntries((res.Parameters ?? []).map((p) => [p.Name ?? '', p.Value]));
  } catch (err) {
    // The service cannot confirm it is permitted to run, so it behaves as
    // though it is not. In shadow this costs nothing; in later phases it is the
    // only defensible direction for a control whose purpose is stopping things.
    return {
      frozen: true,
      scope: 'error',
      reason: `freeze flag could not be read: ${err instanceof Error ? err.message : String(err)}`,
    };
  }

  for (const [name, raw] of Object.entries(found)) {
    if (parseFlag(raw) === null) {
      return { frozen: true, scope: 'error', reason: `${name} holds \`${raw}\`, which is not true or false` };
    }
  }

  // Absent is not an error: it is the state the service ships in.
  if (parseFlag(found[globalName]) === true) return { frozen: true, scope: 'global' };
  if (parseFlag(found[repoName]) === true) return { frozen: true, scope: 'repo' };

  return { frozen: false, scope: 'none' };
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `node --import tsx --test tests/runtime-config.test.ts`
Expected: PASS, 10 tests.

- [ ] **Step 6: Create `infrastructure/terraform/ssm.tf`**

```hcl
# The fleet-wide freeze flag. Read fresh on every evaluation by
# src/runtime-config.ts; see that file for why this is not a repository custom
# property and why the two scopes combine as OR.
#
# Per-repo flags at /zapp/freeze/{owner}/{repo} are created ad hoc during an
# incident and are deliberately NOT managed here — Terraform is not in the path
# of an emergency stop.
resource "aws_ssm_parameter" "freeze" {
  name        = "/zapp/freeze"
  description = "Fleet-wide merge-policy freeze. true stops every evaluation on the next delivery."
  type        = "String"
  value       = "false"

  # LOAD-BEARING. Without this, the next `terraform apply` silently un-freezes
  # a fleet somebody stopped during an incident — and applies happen on merges
  # to main, which is exactly when people are shipping fixes.
  lifecycle {
    ignore_changes = [value]
  }
}
```

- [ ] **Step 7: Grant the read in `infrastructure/terraform/iam.tf`**

Append:

```hcl
# Scoped to exactly the freeze tree. This deliberately reverses part of the
# `enable_ssm_permissions = false` decision in main.tf — that decision was about
# the BREADTH of the module's default team-wide `/platform/*` grant, not about
# SSM as a service. Two parameters and a prefix is a different thing.
#
# The prefix (not just the two exact names) is required because per-repo flags
# are created during an incident: a grant that has to be widened first is not an
# emergency stop.
data "aws_iam_policy_document" "lambda_freeze" {
  statement {
    sid     = "ReadFreezeFlags"
    actions = ["ssm:GetParameters"]
    resources = [
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/zapp/freeze",
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/zapp/freeze/*",
    ]
  }
}

resource "aws_iam_role_policy" "lambda_freeze" {
  name   = "freeze-read"
  role   = module.lambda.iam_role_name
  policy = data.aws_iam_policy_document.lambda_freeze.json
}
```

- [ ] **Step 8: Correct the stale comment in `infrastructure/terraform/main.tf:187-189`**

Replace:

```hcl
  # Config is read from Secrets Manager only. Disable the module's default
  # (team-wide, /platform/*) SSM parameter read grant — we don't use SSM.
  enable_ssm_permissions = false
```

with:

```hcl
  # Disable the module's default SSM grant, which is team-wide (`/platform/*`)
  # and far broader than anything here needs. The one SSM value this service
  # does read — the freeze flag — is granted explicitly and narrowly in iam.tf.
  enable_ssm_permissions = false
```

The point is that the comment now explains the scoped grant rather than
contradicting it. A future reader finding `enable_ssm_permissions = false`
beside an `ssm:GetParameters` policy needs that sentence.

- [ ] **Step 9: Verify the bundle still builds**

Run: `pnpm run build && ls -la dist/index.js`
Expected: PASS. Note the size; adding the SSM client grows it, which is expected and fine.

- [ ] **Step 10: Commit**

```bash
git add src/runtime-config.ts tests/runtime-config.test.ts package.json pnpm-lock.yaml \
  infrastructure/terraform/ssm.tf infrastructure/terraform/iam.tf infrastructure/terraform/main.tf
git commit -m "feat(controls): read the freeze flag from SSM at fleet and repo scope"
```

---

## Task 2: `freezeOff` reads the runtime flag; `rules.freeze` is deleted

**Files:**
- Modify: `src/gates.ts:68-82,236-237`
- Modify: `src/rules-types.ts`
- Modify: `scripts/build-rules.mjs`
- Modify: `policy-rules.yaml:10-12`
- Modify: `src/evaluate.ts`
- Modify: `src/render.ts` (the `freezeOff` cases)
- Modify: `tests/gates.test.ts`, `tests/build-rules.test.ts`, `tests/evaluate.test.ts`, `tests/render.test.ts`

**Interfaces:**
- Consumes: `FreezeState` from Task 1.
- Produces: `GateInput.freeze: FreezeState`.

- [ ] **Step 1: Write the failing tests**

In `tests/gates.test.ts`, add `freeze` to whatever helper builds a `GateInput` (it currently constructs the object per test or via a shared factory — add the field wherever `runs` and `properties` are supplied):

```ts
const NOT_FROZEN = { frozen: false, scope: 'none' as const };
```

Append:

```ts
test('a global freeze fails gate 17', () => {
  const r = runGates({ ...input(27), freeze: { frozen: true, scope: 'global' } });
  assert.equal(r.gates.freezeOff.verdict, 'fail');
  assert.equal(r.failedGate, 'freezeOff');
});

test('a repo freeze fails gate 17 and says which scope', () => {
  const r = runGates({ ...input(27), freeze: { frozen: true, scope: 'repo' } });
  assert.equal(r.gates.freezeOff.verdict, 'fail');
  assert.equal((r.gates.freezeOff.value as any).scope, 'repo');
});

test('an unreadable freeze flag fails gate 17 with the error as its reason', () => {
  const r = runGates({ ...input(27), freeze: {
    frozen: true, scope: 'error', reason: 'freeze flag could not be read: AccessDeniedException',
  } });
  assert.equal(r.gates.freezeOff.verdict, 'fail');
  assert.match((r.gates.freezeOff.value as any).reason, /AccessDeniedException/);
});

test('freezeOff is still the last gate', () => {
  assert.equal(GATE_ORDER[GATE_ORDER.length - 1], 'freezeOff');
});
```

In `tests/build-rules.test.ts`, remove `freeze: false` from `validDoc()`'s `rules` block and append:

```ts
test('a stale rules.freeze fails the build rather than being ignored', () => {
  // The flag moved to SSM. A rules file still carrying it would validate,
  // compile, and be silently ignored — leaving somebody convinced they had
  // frozen the fleet when they had edited a dead value.
  const doc = validDoc();
  doc.rules.freeze = true;
  const errors = validatePolicy(doc);
  assert.equal(errors.length, 1);
  assert.match(errors[0], /rules\.freeze/);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pnpm test 2>&1 | tail -30`
Expected: FAIL — `freeze` is not a member of `GateInput`; `validatePolicy` still requires `rules.freeze`.

- [ ] **Step 3: Change `src/gates.ts`**

Add the import and the input field:

```ts
import type { FreezeState } from './runtime-config.js';
```

In `GateInput`, after `properties`:

```ts
  /** The runtime freeze flag. Gate 17 reads this — NOT `rules.freeze`, which no longer exists. */
  freeze: FreezeState;
```

Replace gate 15's body (currently `gates.freezeOff = gate(rules.freeze === false, { freeze: rules.freeze });`) — it becomes gate 17 in Task 4, but the source changes now:

```ts
  // 15 — freeze, last. Read at runtime from SSM rather than from the compiled
  // rules, because a stop that needs a pull request, a build and a deploy is
  // not a stop. `frozen: true` with `scope: 'error'` is the fail-closed case:
  // an unreadable flag means we cannot confirm we are permitted to run.
  gates.freezeOff = gate(!input.freeze.frozen, {
    frozen: input.freeze.frozen,
    scope: input.freeze.scope,
    ...(input.freeze.reason ? { reason: input.freeze.reason } : {}),
  });
```

- [ ] **Step 4: Remove `freeze` from `src/rules-types.ts`**

Delete the `freeze: boolean;` line from `Rules`.

- [ ] **Step 5: Reject it in `scripts/build-rules.mjs`**

Replace `if (typeof rules.freeze !== 'boolean') bad('rules.freeze', 'must be a boolean');` with:

```js
  // Moved to SSM (/zapp/freeze). Named explicitly rather than ignored: a rules
  // file still carrying it would compile fine and be silently dead, which is
  // worse than a failed build for a value whose entire job is stopping things.
  if (rules.freeze !== undefined) {
    bad('rules.freeze', 'removed — the freeze flag is now the SSM parameter /zapp/freeze');
  }
```

- [ ] **Step 6: Remove it from `policy-rules.yaml`**

Delete lines 10-12:

```yaml
rules:
  # Gate 11, checked last. One switch makes every PR a non-candidate.
  freeze: false
```

leaving `rules:` followed directly by the `risk:` block. Add above `risk:`:

```yaml
rules:
  # NOTE: there is no `freeze` key here any more. The freeze switch is the SSM
  # parameter /zapp/freeze (and /zapp/freeze/{owner}/{repo} per repository),
  # read fresh on every evaluation — see src/runtime-config.ts. It lives outside
  # this file precisely so stopping the service does not require a deploy.

```

- [ ] **Step 7: Hoist the read in `src/evaluate.ts`**

Add the import:

```ts
import { readFreeze } from './runtime-config.js';
import type { FreezeState } from './runtime-config.js';
```

Add to `EvaluateDeps` and `defaultDeps`:

```ts
  readFreeze: typeof readFreeze;
```

Extend the hoisted fetch block — it currently resolves `[runs, properties]`:

```ts
  const [runs, properties, freeze] = skipFetches
    ? [
        [] as CheckRunSummary[],
        { resiliencyTier: null, isSoc2Compliant: null } as RepoProperties,
        { frozen: false, scope: 'none' } as FreezeState,
      ]
    : await Promise.all([
        deps.fetchCheckRuns(ctx.repoFullName, ctx.headSha),
        deps.fetchRepoProperties(ctx.repoFullName),
        deps.readFreeze(ctx.repoFullName),
      ]);
```

The skip case returns not-frozen deliberately: an unenrolled repository fails
gate 1 regardless, and reading a flag for a repository we do not evaluate would
cost a call to change nothing.

Pass it into `runGates`:

```ts
    properties,
    freeze,
```

- [ ] **Step 8: Update `src/render.ts`'s two `freezeOff` cases**

In `rejectionDetail`:

```ts
    case 'freezeOff': {
      const v = value as { scope: string; reason?: string };
      if (v.scope === 'error') {
        return `Merge-policy automation is treated as frozen because its stop switch could not be read — ${v.reason}. Nothing is a candidate until that read succeeds.`;
      }
      return v.scope === 'repo'
        ? 'Merge-policy automation is currently frozen for this repository, so nothing is a candidate.'
        : 'Merge-policy automation is currently frozen org-wide, so nothing is a candidate.';
    }
```

In `gateCell`:

```ts
    case 'freezeOff': {
      const v2 = v as { frozen: boolean; scope: string };
      if (!v2.frozen) return '—';
      return v2.scope === 'error' ? 'stop switch unreadable' : `frozen (${v2.scope})`;
    }
```

- [ ] **Step 9: Update the test harnesses**

- `tests/gates.test.ts`: every `runGates({...})` call now needs `freeze: NOT_FROZEN`.
- `tests/evaluate.test.ts`: both `deps()` and `riskDeps()` gain `readFreeze: async () => ({ frozen: false, scope: 'none' })`.
- `tests/render.test.ts`: any fixture whose `freezeOff` gate value is `{ freeze: false }` becomes `{ frozen: false, scope: 'none' }`.

- [ ] **Step 10: Run tests to verify they pass**

Run: `pnpm run typecheck && pnpm test`
Expected: PASS.

- [ ] **Step 11: Prove the flag actually stops an evaluation**

```bash
node --import tsx -e "
import { evaluate } from './src/evaluate.ts';
const base = { readFreeze: async () => ({ frozen: true, scope: 'global' }) };
" 2>&1 | head -3
```

That is a smoke check only; the real proof is the gate test from Step 1 plus
the live validation in Task 7.

- [ ] **Step 12: Commit**

```bash
git add src/gates.ts src/rules-types.ts scripts/build-rules.mjs policy-rules.yaml \
  src/evaluate.ts src/render.ts src/generated/rules.ts tests/
git commit -m "feat(controls): freeze becomes a runtime switch, not a compiled rule"
```

---

## Task 3: Both trigger paths learn labels, base branch and draft state

Gate 2 reads `pull_request.user.login`; nothing reads the target branch, the labels, or whether the PR is a draft. Before the gates can, both paths have to supply them **identically** — the same guard Spec C established for title and body.

**Files:**
- Modify: `src/pr-context.ts`
- Modify: `src/evaluate.ts` (`EvalContext`)
- Modify: `tests/pr-context.test.ts`

**Interfaces:**
- Produces: `EvalContext.labels: string[]`, `.baseRef: string`, `.isDraft: boolean`, `.defaultBranch: string`.

- [ ] **Step 1: Write the failing test**

Append to `tests/pr-context.test.ts`:

```ts
import { readFileSync } from 'node:fs';
const payload = (n: number) => JSON.parse(readFileSync(`tests/fixtures/pr-${n}-payload.json`, 'utf8'));

test('the pull_request path reads labels, base ref, draft and default branch', () => {
  const ctx = contextFromPullRequestEvent({
    repository: { full_name: 'bankrate/platform-cicd-v2-demo' },
    pull_request: payload(27),
  });
  assert.deepEqual(ctx.labels, ['dependencies', 'javascript']);
  assert.equal(ctx.baseRef, 'main');
  assert.equal(ctx.isDraft, false);
  assert.equal(ctx.defaultBranch, 'main');
});

test('the two paths produce identical contexts from the same pull request', async () => {
  // Spec C's parity guard, extended to the four new fields. The check_suite
  // path fetches the PR; the pull_request path gets it inline. They must not
  // drift, or a re-evaluation can reach a different verdict from the same code.
  const pr = payload(27);
  const fromEvent = contextFromPullRequestEvent({
    repository: { full_name: 'bankrate/platform-cicd-v2-demo' }, pull_request: pr,
  });
  const fromFetch = await fetchPrContext('bankrate/platform-cicd-v2-demo', pr.number,
    (async () => ({ ok: true, status: 200, json: async () => pr })) as any);

  const { trigger: _a, ...eventFields } = fromEvent;
  const { trigger: _b, ...fetchFields } = fromFetch;
  assert.deepEqual(eventFields, fetchFields);
});

test('a draft pull request is reported as one', () => {
  const ctx = contextFromPullRequestEvent({
    repository: { full_name: 'o/r' }, pull_request: { ...payload(27), draft: true },
  });
  assert.equal(ctx.isDraft, true);
});

test('missing fields degrade to safe defaults, not undefined', () => {
  const ctx = contextFromPullRequestEvent({ repository: { full_name: 'o/r' }, pull_request: {} });
  assert.deepEqual(ctx.labels, []);
  assert.equal(ctx.baseRef, '');
  assert.equal(ctx.isDraft, false);
  assert.equal(ctx.defaultBranch, '');
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --import tsx --test tests/pr-context.test.ts`
Expected: FAIL — `labels` is not a property of the returned context.

- [ ] **Step 3: Extend `EvalContext` in `src/evaluate.ts`**

```ts
  /** `pull_request.labels[].name`. Gate 16 reads these. */
  labels: string[];
  /** `pull_request.base.ref` — the branch this would merge into. Gate 15 reads it. */
  baseRef: string;
  /** `pull_request.draft`. A draft fails gate 16 independently of its title. */
  isDraft: boolean;
  /** The repository's default branch. Gate 15 compares `baseRef` against it. */
  defaultBranch: string;
```

- [ ] **Step 4: Read them in `src/pr-context.ts`**

Extend `toContext`:

```ts
    labels: Array.isArray(pr?.labels)
      ? pr.labels.map((l: any) => l?.name).filter((n: unknown): n is string => typeof n === 'string')
      : [],
    baseRef: pr?.base?.ref ?? '',
    isDraft: pr?.draft === true,
    // Read from `base.repo`, NOT from the event's top-level `repository`.
    // Both carry it on a pull_request payload, but only this one is also
    // present on the object `GET /pulls/{n}` returns — so taking it from here
    // gives both paths a single source and makes them structurally unable to
    // drift.
    defaultBranch: pr?.base?.repo?.default_branch ?? '',
```

Update the file's header comment to name the four new fields alongside title,
body and author.

- [ ] **Step 5: Run tests to verify they pass**

Run: `pnpm run typecheck && pnpm test`
Expected: PASS. Other tests constructing an `EvalContext` by hand will fail to typecheck until they supply the new fields — add them there too, defaulting to `[]`, `'main'`, `false`, `'main'`.

- [ ] **Step 6: Commit**

```bash
git add src/pr-context.ts src/evaluate.ts tests/
git commit -m "feat(context): carry labels, base ref and draft state on both trigger paths"
```

---

## Task 4: Gates 15 and 16 — target branch and blocking labels

**Files:**
- Modify: `src/gates.ts`
- Modify: `src/rules-types.ts`
- Modify: `scripts/build-rules.mjs`
- Modify: `policy-rules.yaml`
- Modify: `src/render.ts`
- Modify: `tests/gates.test.ts`, `tests/render.test.ts`, `tests/build-rules.test.ts`

**Interfaces:**
- Consumes: `EvalContext`'s four new fields (Task 3), passed through `GateInput`.
- Produces: `GATE_ORDER` with 17 entries; `Rules.blockingLabels`, `Rules.blockingTitlePattern`; `EnrollmentRecord.baseBranches?`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/gates.test.ts`:

```ts
test('there are seventeen gates and freezeOff is last', () => {
  assert.equal(GATE_ORDER.length, 17);
  assert.equal(GATE_ORDER[14], 'baseBranchAllowed');
  assert.equal(GATE_ORDER[15], 'notBlocked');
  assert.equal(GATE_ORDER[16], 'freezeOff');
});

test('the default branch passes gate 15', () => {
  const r = runGates({ ...input(27), baseRef: 'main', defaultBranch: 'main' });
  assert.equal(r.gates.baseBranchAllowed.verdict, 'pass');
});

test('a long-lived feature branch fails gate 15', () => {
  // A PR into a feature branch has entirely different review expectations, and
  // merging it automatically is not what anyone enrolled for.
  const r = runGates({ ...input(27), baseRef: 'release/2026-q4', defaultBranch: 'main' });
  assert.equal(r.gates.baseBranchAllowed.verdict, 'fail');
  assert.equal(r.failedGate, 'baseBranchAllowed');
});

test('an allow-listed base branch passes', () => {
  const r = runGates({
    ...input(27),
    baseRef: 'release/2026-q4',
    defaultBranch: 'main',
    enrollment: { ...enrollment(), baseBranches: ['release/2026-q4'] },
  });
  assert.equal(r.gates.baseBranchAllowed.verdict, 'pass');
});

test('an undeterminable base branch fails — unknown is not known-safe', () => {
  const r = runGates({ ...input(27), baseRef: '', defaultBranch: '' });
  assert.equal(r.gates.baseBranchAllowed.verdict, 'fail');
  assert.match((r.gates.baseBranchAllowed.value as any).reason, /could not be determined/);
});

test('a blocking label fails gate 16 and names it', () => {
  const r = runGates({ ...input(27), labels: ['dependencies', 'do-not-automerge'] });
  assert.equal(r.gates.notBlocked.verdict, 'fail');
  assert.deepEqual((r.gates.notBlocked.value as any).labels, ['do-not-automerge']);
});

test('an unlisted label does not block', () => {
  const r = runGates({ ...input(27), labels: ['dependencies', 'javascript', 'needs-review'] });
  assert.equal(r.gates.notBlocked.verdict, 'pass');
});

test('a WIP title blocks; a wip-adjacent word does not', () => {
  assert.equal(runGates({ ...input(27), title: 'WIP: chore(deps): bump' }).gates.notBlocked.verdict, 'fail');
  assert.equal(runGates({ ...input(27), title: 'DRAFT: chore(deps): bump' }).gates.notBlocked.verdict, 'fail');
  // The \b in the pattern is what stops this matching, and it is the assertion
  // most likely to break if somebody "simplifies" the regex.
  assert.equal(runGates({ ...input(27), title: 'chore: wipe stale caches' }).gates.notBlocked.verdict, 'pass');
});

test('a draft blocks independently of its title and labels', () => {
  const r = runGates({ ...input(27), isDraft: true, title: 'chore(deps): bump fastify', labels: [] });
  assert.equal(r.gates.notBlocked.verdict, 'fail');
  assert.equal((r.gates.notBlocked.value as any).draft, true);
});
```

Append to `tests/build-rules.test.ts`:

```ts
test('an uncompilable blocking title pattern fails the build', () => {
  // The gate compiles this pattern. An invalid one must fail the DEPLOY, not
  // throw inside the Lambda on the next pull request — which is the entire
  // reason rules are compiled at build time.
  const doc = validDoc();
  doc.rules.blockingTitlePattern = '^(WIP';
  assert.match(validatePolicy(doc)[0], /rules\.blockingTitlePattern/);
});

test('blockingLabels must be an array of strings', () => {
  const doc = validDoc();
  doc.rules.blockingLabels = 'do-not-automerge';
  assert.match(validatePolicy(doc)[0], /rules\.blockingLabels/);
});

test('a per-repo baseBranches must be an array of strings when present', () => {
  const doc = validDoc();
  doc.repos[0].baseBranches = 'main';
  assert.match(validatePolicy(doc)[0], /repos\[0\]\.baseBranches/);
});
```

Add `blockingLabels: ['do-not-automerge']` and `blockingTitlePattern: '^(WIP|DRAFT)\\b'` to `validDoc()`'s `rules`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `pnpm test 2>&1 | tail -30`
Expected: FAIL — `GATE_ORDER.length` is 15.

- [ ] **Step 3: Extend the rules types**

In `src/rules-types.ts`, add to `Rules`:

```ts
  /** Labels that make a pull request ineligible. The human-override story. */
  blockingLabels: string[];
  /** Titles matching this fail gate 16. Compiled at BUILD time, not runtime. */
  blockingTitlePattern: string;
  /** When automation would be permitted to merge. Recorded, never enforced. */
  mergeWindow: MergeWindow;
```

and the new interface:

```ts
/** A declared merge window. Recorded per evaluation; gates nothing in Phase 0. */
export interface MergeWindow {
  /** IANA zone, e.g. `America/New_York`. */
  timezone: string;
  /** Lowercase three-letter days, e.g. `["mon","tue"]`. */
  days: string[];
  /** Inclusive start hour, exclusive end hour, 0-23. */
  hours: [number, number];
}
```

Add to `EnrollmentRecord`:

```ts
  /** Base branches permitted in addition to the default branch. Never merged with anything. */
  baseBranches?: string[];
```

- [ ] **Step 4: Extend `policy-rules.yaml`**

Under `rules:`, after `generatedPaths`:

```yaml
  # The cheapest possible human-override story. A team that wants one pull
  # request left alone adds a label; nothing else is required, and no ticket is
  # filed. Kodiak and Mergify both do it this way.
  blockingLabels:
    - "do-not-automerge"
    - "hold"

  # Compiled by scripts/build-rules.mjs, so an invalid pattern fails the deploy
  # rather than throwing inside the Lambda. The \b matters: without it,
  # "chore: wipe stale caches" would block.
  blockingTitlePattern: "^(WIP|DRAFT)\\b"

  # RECORDED, NEVER ENFORCED in Phase 0. Business-hours-only merging is standard
  # (Mergify `schedule`, Renovate `automergeSchedule`) and the rationale is just
  # that someone is around to revert. Thirty days of `wouldHaveMergedInWindow`
  # says what fraction of candidates fall outside it, which is the number that
  # should decide whether enforcing it is worth the delay it adds.
  mergeWindow:
    timezone: "America/New_York"
    days: [mon, tue, wed, thu, fri]
    hours: [9, 17]
```

- [ ] **Step 5: Validate them in `scripts/build-rules.mjs`**

Add near the other constants:

```js
const DAYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
```

In the rules block:

```js
  if (!isStrArray(rules.blockingLabels)) bad('rules.blockingLabels', 'must be an array of strings');

  // Compiled HERE so an invalid pattern fails the deploy. src/gates.ts builds a
  // RegExp from this string on every evaluation; a bad one would throw inside
  // the Lambda, on a pull request, for every repository at once.
  if (typeof rules.blockingTitlePattern !== 'string') {
    bad('rules.blockingTitlePattern', 'must be a string');
  } else {
    try {
      new RegExp(rules.blockingTitlePattern);
    } catch (err) {
      bad('rules.blockingTitlePattern', `is not a valid regular expression: ${err.message}`);
    }
  }

  const win = rules.mergeWindow;
  if (!win || typeof win !== 'object') {
    bad('rules.mergeWindow', 'must be an object');
  } else {
    if (typeof win.timezone !== 'string' || !win.timezone) {
      bad('rules.mergeWindow.timezone', 'must be a non-empty IANA timezone');
    } else {
      // Proves the zone resolves on this Node build rather than silently
      // falling back to UTC at runtime and shifting every recorded value.
      try {
        new Intl.DateTimeFormat('en-US', { timeZone: win.timezone });
      } catch {
        bad('rules.mergeWindow.timezone', `\`${win.timezone}\` is not a recognised IANA timezone`);
      }
    }
    if (!Array.isArray(win.days) || !win.days.every((d) => DAYS.includes(d))) {
      bad('rules.mergeWindow.days', `must be an array of ${DAYS.join(', ')}`);
    }
    if (!Array.isArray(win.hours) || win.hours.length !== 2
      || !win.hours.every((h) => isInt(h) && h >= 0 && h <= 23)
      || win.hours[0] >= win.hours[1]) {
      bad('rules.mergeWindow.hours', 'must be [startHour, endHour] with 0 <= start < end <= 23');
    }
  }
```

In the repos loop:

```js
      if (r?.baseBranches !== undefined && !isStrArray(r.baseBranches)) {
        bad(`repos[${i}].baseBranches`, 'must be an array of strings when present');
      }
```

- [ ] **Step 6: Add the gates to `src/gates.ts`**

Extend `GATE_ORDER`, inserting before `freezeOff`:

```ts
  'soc2Permits',
  'baseBranchAllowed',
  'notBlocked',
  'freezeOff',
] as const;
```

Add to `GateInput`:

```ts
  /** `pull_request.base.ref`. Gate 15 reads it. */
  baseRef: string;
  /** The repository's default branch. Gate 15 compares against it. */
  defaultBranch: string;
  /** `pull_request.labels[].name`. Gate 16 reads these. */
  labels: string[];
  /** `pull_request.draft`. Gate 16 fails on it. */
  isDraft: boolean;
```

Add the two gates immediately before the freeze gate. **Both sit outside the
`if (!classified)` block**: neither reads a change class, so a PR with no
recognised class should still report whether it targets the right branch and
whether somebody labelled it hold. Skipping them there would lose exactly the
override signal a reader is looking for on a rejected PR.

```ts
  // 15 — target branch. Every comparable tool conditions on `base`: a pull
  // request into a long-lived feature branch has different review
  // expectations, and merging it automatically is not what anyone enrolled for.
  // An allow-list on the enrolment record REPLACES nothing — it adds to the
  // default branch, which is always permitted.
  const allowedBases = input.enrollment?.baseBranches ?? [];
  gates.baseBranchAllowed = !input.baseRef || !input.defaultBranch
    ? fail({
        baseRef: input.baseRef || null,
        defaultBranch: input.defaultBranch || null,
        reason: 'the target branch could not be determined',
      })
    : gate(
        input.baseRef === input.defaultBranch || allowedBases.includes(input.baseRef),
        { baseRef: input.baseRef, defaultBranch: input.defaultBranch, allowed: allowedBases },
      );

  // 16 — blocked by a human. Three independent ways to say "not this one":
  // a label, a title prefix, and GitHub's own draft flag. The draft check is
  // not redundant with the title pattern — it is the same intent expressed
  // through a first-class GitHub feature, and a draft rarely says so in words.
  const blockedLabels = input.labels.filter((l) => rules.blockingLabels.includes(l));
  const titleBlocked = new RegExp(rules.blockingTitlePattern).test(input.title);
  gates.notBlocked = gate(
    blockedLabels.length === 0 && !titleBlocked && !input.isDraft,
    { labels: blockedLabels, titleBlocked, draft: input.isDraft },
  );
```

Renumber the existing comments: `// 15 — freeze, last.` becomes `// 17 — freeze, last.`

- [ ] **Step 7: Pass the fields through `src/evaluate.ts`**

In the `runGates` call:

```ts
    baseRef: ctx.baseRef,
    defaultBranch: ctx.defaultBranch,
    labels: ctx.labels,
    isDraft: ctx.isDraft,
```

- [ ] **Step 8: Render the two new gates in `src/render.ts`**

In `rejectionDetail`:

```ts
    case 'baseBranchAllowed': {
      const v = value as { baseRef: string | null; defaultBranch: string | null; reason?: string };
      return v.reason !== undefined
        ? 'The branch this pull request targets could not be determined, so it is not treated as a known-safe target.'
        : `This pull request targets \`${v.baseRef}\`, not the default branch \`${v.defaultBranch}\`. Automated merge is only considered for the default branch, or for branches explicitly allow-listed on this repository.`;
    }
    case 'notBlocked': {
      const v = value as { labels: string[]; titleBlocked: boolean; draft: boolean };
      if (v.labels.length > 0) {
        return `This pull request carries ${v.labels.map((l) => `\`${l}\``).join(', ')}, which opts it out of automated merge. Remove the label to opt back in.`;
      }
      if (v.draft) return 'This pull request is a draft.';
      return 'This pull request\'s title marks it as work in progress.';
    }
```

In `gateCell`:

```ts
    case 'baseBranchAllowed': {
      const v2 = v as { baseRef: string | null; defaultBranch: string | null; reason?: string };
      return v2.reason !== undefined
        ? String(v2.reason)
        : `\`${v2.baseRef}\` ${result.verdict === 'pass' ? '→' : '↛'} \`${v2.defaultBranch}\``;
    }
    case 'notBlocked': {
      const v2 = v as { labels: string[]; titleBlocked: boolean; draft: boolean };
      const causes = [
        ...v2.labels.map((l) => `\`${l}\``),
        ...(v2.titleBlocked ? ['title marked WIP'] : []),
        ...(v2.draft ? ['draft'] : []),
      ];
      return causes.length > 0 ? causes.join(', ') : 'no blocking label, title or draft state';
    }
```

Update `gateTable`'s doc comment from "The fifteen gates" to "The seventeen gates".

- [ ] **Step 9: Run tests to verify they pass**

Run: `pnpm run typecheck && pnpm test`
Expected: PASS. Tests asserting `15 of 15 gates passed` become `17 of 17`.

- [ ] **Step 10: Commit**

```bash
git add src/gates.ts src/rules-types.ts scripts/build-rules.mjs policy-rules.yaml \
  src/evaluate.ts src/render.ts src/generated/rules.ts tests/
git commit -m "feat(gates): check the target branch and honour a do-not-automerge label"
```

---

## Task 5: The two recorders

Neither gates anything. Commit authorship exists because gate 2 checks only who *opened* a pull request — a human can push commits onto a bot's branch and nothing looks. Making that a gate today would fail every PR where a maintainer pushed a lockfile fixup onto a Dependabot branch, which is plausibly common and entirely unmeasured. Thirty days of counts answers it.

**Files:**
- Create: `src/commit-authorship.ts`, `src/merge-window.ts`
- Create: `tests/commit-authorship.test.ts`, `tests/merge-window.test.ts`
- Modify: `src/evaluate.ts`, `src/ledger.ts`
- Modify: `tests/evaluate.test.ts`, `tests/ledger.test.ts`

**Interfaces:**
- Produces: `CommitAuthorship`, `fetchCommitAuthorship(repoFullName, prNumber, botLogins, request?)`; `inMergeWindow(now, window)`; `EvalRecord.commitAuthorship?`, `EvalRecord.wouldHaveMergedInWindow?`.

- [ ] **Step 1: Write the failing tests**

Create `tests/commit-authorship.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fetchCommitAuthorship } from '../src/commit-authorship.js';

const BOTS = ['dependabot[bot]'];

const commit = (login: string | null, verified: boolean) => ({
  sha: 'a'.repeat(40),
  author: login === null ? null : { login },
  commit: { verification: { verified } },
});

const respond = (body: unknown, ok = true, status = 200) =>
  (async () => ({ ok, status, json: async () => body, text: async () => '' })) as any;

test('an all-bot, all-verified branch reports so', async () => {
  const r = await fetchCommitAuthorship('o/r', 27, BOTS,
    respond([commit('dependabot[bot]', true), commit('dependabot[bot]', true)]));
  assert.equal(r!.commits, 2);
  assert.equal(r!.allBotAuthored, true);
  assert.equal(r!.allVerified, true);
  assert.deepEqual(r!.foreignAuthors, []);
});

test('a human commit on a bot branch is named', async () => {
  // The whole point. Gate 2 passes this pull request today and nothing notices.
  const r = await fetchCommitAuthorship('o/r', 27, BOTS,
    respond([commit('dependabot[bot]', true), commit('scrosby', false)]));
  assert.equal(r!.allBotAuthored, false);
  assert.equal(r!.allVerified, false);
  assert.deepEqual(r!.foreignAuthors, ['scrosby']);
});

test('a null author is foreign, not ignored', async () => {
  // GitHub returns author: null for a commit whose email matches no account.
  // Treating that as "fine" would be a gap wide enough to walk through.
  const r = await fetchCommitAuthorship('o/r', 27, BOTS, respond([commit(null, false)]));
  assert.equal(r!.allBotAuthored, false);
  assert.deepEqual(r!.foreignAuthors, ['(unattributed)']);
});

test('a failed fetch records null rather than throwing', async () => {
  assert.equal(await fetchCommitAuthorship('o/r', 27, BOTS, respond(null, false, 500)), null);
});

test('a full first page is marked truncated', async () => {
  // GET /pulls/{n}/commits pages at 100. A dependabot PR has one to three
  // commits, so this is defensive — but "we saw 100 of an unknown number" must
  // not be recorded as "we saw them all".
  const many = Array.from({ length: 100 }, () => commit('dependabot[bot]', true));
  const r = await fetchCommitAuthorship('o/r', 27, BOTS, respond(many));
  assert.equal(r!.truncated, true);
});
```

Create `tests/merge-window.test.ts`:

```ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { inMergeWindow } from '../src/merge-window.js';

const WINDOW = { timezone: 'America/New_York', days: ['mon', 'tue', 'wed', 'thu', 'fri'], hours: [9, 17] as [number, number] };

test('a weekday mid-morning is inside', () => {
  // 2026-08-26 is a Wednesday. 14:00Z = 10:00 EDT.
  assert.equal(inMergeWindow(new Date('2026-08-26T14:00:00Z'), WINDOW), true);
});

test('the boundary hours are inclusive-start, exclusive-end', () => {
  assert.equal(inMergeWindow(new Date('2026-08-26T13:00:00Z'), WINDOW), true, '09:00 EDT is in');
  assert.equal(inMergeWindow(new Date('2026-08-26T21:00:00Z'), WINDOW), false, '17:00 EDT is out');
  assert.equal(inMergeWindow(new Date('2026-08-26T20:59:00Z'), WINDOW), true, '16:59 EDT is in');
});

test('a weekend is outside regardless of the hour', () => {
  // 2026-08-29 is a Saturday.
  assert.equal(inMergeWindow(new Date('2026-08-29T14:00:00Z'), WINDOW), false);
});

test('the timezone is honoured, not assumed to be UTC', () => {
  // 2026-08-26T02:00:00Z is 22:00 EDT on Tuesday the 25th — outside the window
  // in New York, but inside it if you read the UTC hour as local.
  assert.equal(inMergeWindow(new Date('2026-08-26T02:00:00Z'), WINDOW), false);
});

test('a winter date uses EST, not a fixed offset', () => {
  // 2026-01-14T14:00:00Z = 09:00 EST. A hard-coded -4 would read it as 10:00
  // and a hard-coded UTC as 14:00; only real zone handling gets this right.
  assert.equal(inMergeWindow(new Date('2026-01-14T14:00:00Z'), WINDOW), true);
  assert.equal(inMergeWindow(new Date('2026-01-14T13:30:00Z'), WINDOW), false, '08:30 EST is out');
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pnpm test 2>&1 | tail -20`
Expected: FAIL — neither module exists.

- [ ] **Step 3: Write `src/commit-authorship.ts`**

```ts
// Who actually wrote the commits on this branch.
//
// RECORDED, NEVER GATED — in Phase 0.
//
// Gate 2 checks `pull_request.user.login`, which is who OPENED the pull
// request. A human can push commits onto a bot's branch and the gate still
// passes, because nothing looks at the commits. Branch poisoning is a known
// attack against auto-merge, so this is not hypothetical.
//
// It is not a gate yet because making it one today would fail every pull
// request where a maintainer pushed a lockfile fixup onto a Dependabot branch,
// and nobody knows how often that happens. Thirty days of `allBotAuthored:
// false` counts answers it, and the gate lands in Phase 1 tuned rather than
// guessed. It IS shown on the check run in the "Recorded, not enforced" table,
// so nobody has to wonder whether we noticed.
import { githubRequest } from './github.js';
import { log } from './log.js';

const PER_PAGE = 100;

/** What the recorder observed. */
export interface CommitAuthorship {
  commits: number;
  allBotAuthored: boolean;
  allVerified: boolean;
  /** Logins that are not on the bot allow-list. `(unattributed)` for a null author. */
  foreignAuthors: string[];
  /** True when the pull request has more commits than one page. */
  truncated: boolean;
}

/**
 * Read the commits on a pull request and summarise their authorship.
 *
 * Args:
 *   repoFullName: `owner/repo`.
 *   prNumber: Pull request number.
 *   botLogins: The allow-listed automation logins, from the rules.
 *   request: Injected GitHub request.
 * Returns:
 *   The summary, or null on any failure — a recorder must never cost a check
 *   run.
 */
export async function fetchCommitAuthorship(
  repoFullName: string,
  prNumber: number,
  botLogins: readonly string[],
  request: typeof githubRequest = githubRequest,
): Promise<CommitAuthorship | null> {
  try {
    const res = await request(`/repos/${repoFullName}/pulls/${prNumber}/commits?per_page=${PER_PAGE}`);
    if (!res.ok) {
      log('warn', 'commit_authorship_unavailable', { repo: repoFullName, pr: prNumber, status: res.status });
      return null;
    }

    const commits = (await res.json()) as {
      author?: { login?: string } | null;
      commit?: { verification?: { verified?: boolean } };
    }[];
    if (!Array.isArray(commits)) return null;

    // A null author means the commit's email matches no GitHub account. That is
    // FOREIGN, not neutral — treating it as fine would be the widest hole here.
    const authors = commits.map((c) => c.author?.login ?? '(unattributed)');
    const foreignAuthors = [...new Set(authors.filter((a) => !botLogins.includes(a)))];

    return {
      commits: commits.length,
      allBotAuthored: foreignAuthors.length === 0,
      allVerified: commits.every((c) => c.commit?.verification?.verified === true),
      foreignAuthors,
      truncated: commits.length >= PER_PAGE,
    };
  } catch (err) {
    log('warn', 'commit_authorship_unavailable', {
      repo: repoFullName, pr: prNumber,
      error: err instanceof Error ? err.message : String(err),
    });
    return null;
  }
}
```

- [ ] **Step 4: Write `src/merge-window.ts`**

```ts
// Would this evaluation have merged inside the declared window?
//
// RECORDED, NEVER ENFORCED in Phase 0. Business-hours-only merging is standard
// (Mergify `schedule`, Renovate `automergeSchedule`) and the rationale is
// simply that somebody is around to revert. Whether it is worth the delay it
// adds is a question thirty days of data should answer, not a guess.
//
// Pure, and takes its clock as an argument, so the tests are deterministic
// across daylight-saving boundaries.
import type { MergeWindow } from './rules-types.js';

const DAY_INDEX: Record<string, string> = {
  Mon: 'mon', Tue: 'tue', Wed: 'wed', Thu: 'thu', Fri: 'fri', Sat: 'sat', Sun: 'sun',
};

/**
 * Is `now` inside the window?
 *
 * Uses `Intl.DateTimeFormat` with the declared IANA zone rather than an offset,
 * so daylight saving is handled by ICU rather than by arithmetic somebody has
 * to remember to update twice a year. Node 22 ships full ICU, and
 * `scripts/build-rules.mjs` proves the zone resolves at build time.
 *
 * Start hour inclusive, end hour exclusive: `[9, 17]` means 09:00:00 is in and
 * 17:00:00 is out.
 */
export function inMergeWindow(now: Date, window: MergeWindow): boolean {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: window.timezone,
    weekday: 'short',
    hour: 'numeric',
    hour12: false,
  }).formatToParts(now);

  const weekday = parts.find((p) => p.type === 'weekday')?.value ?? '';
  const hourRaw = parts.find((p) => p.type === 'hour')?.value ?? '';

  const day = DAY_INDEX[weekday];
  // `hour12: false` renders midnight as "24" in some ICU versions.
  const hour = Number(hourRaw) % 24;

  if (day === undefined || !Number.isFinite(hour)) return false;
  if (!window.days.includes(day)) return false;

  return hour >= window.hours[0] && hour < window.hours[1];
}
```

- [ ] **Step 5: Run the two new test files**

Run: `node --import tsx --test tests/commit-authorship.test.ts tests/merge-window.test.ts`
Expected: PASS, 10 tests.

- [ ] **Step 6: Record them from `src/evaluate.ts`**

Add imports and deps:

```ts
import { fetchCommitAuthorship } from './commit-authorship.js';
import type { CommitAuthorship } from './commit-authorship.js';
import { inMergeWindow } from './merge-window.js';
```

Add `fetchCommitAuthorship: typeof fetchCommitAuthorship;` to `EvaluateDeps` and `defaultDeps`.

In `evaluate()`, after the eligibility result and **outside** any candidate-only
branch — a rejected pull request is exactly when a reader wants to see what was
observed:

```ts
  // Recorders. Neither gates anything; both are wrapped so a failure can never
  // cost a check run. Run for enrolled repos only, on the same reasoning as the
  // files fetch.
  const commitAuthorship = skipFetches
    ? null
    : await deps.fetchCommitAuthorship(ctx.repoFullName, ctx.prNumber, policy.bots.map((b) => b.login));

  const wouldHaveMergedInWindow = inMergeWindow(new Date(), policy.mergeWindow);
```

Add both to the `recordEvaluation` call and to the `evaluated` log line:

```ts
    all_bot_authored: commitAuthorship?.allBotAuthored ?? null,
    in_merge_window: wouldHaveMergedInWindow,
```

Pass both into `renderEligibility` and `renderRisk` — Task 6 consumes them.

- [ ] **Step 7: Add the ledger fields in `src/ledger.ts`**

```ts
import type { CommitAuthorship } from './commit-authorship.js';
```

```ts
  /** Who authored the commits. Recorded for Phase 1 tuning; gates nothing. */
  commitAuthorship?: CommitAuthorship | null;
  /** Whether this evaluation fell inside the declared merge window. Gates nothing. */
  wouldHaveMergedInWindow?: boolean;
```

In the `Item`:

```ts
      commitAuthorship: record.commitAuthorship
        ? { S: JSON.stringify(record.commitAuthorship) }
        : { NULL: true },
      wouldHaveMergedInWindow: record.wouldHaveMergedInWindow === undefined
        ? { NULL: true }
        : { BOOL: record.wouldHaveMergedInWindow },
```

Note the asymmetry and keep it: `commitAuthorship` distinguishes "not recorded"
from a value, and `wouldHaveMergedInWindow` distinguishes "not recorded" from
`false`. Collapsing either into a falsy default would make the Phase 1
denominator a lie.

- [ ] **Step 8: Update the test harnesses**

`tests/evaluate.test.ts`: both `deps()` and `riskDeps()` gain

```ts
    fetchCommitAuthorship: async () => ({
      commits: 1, allBotAuthored: true, allVerified: true, foreignAuthors: [], truncated: false,
    }),
```

Append:

```ts
test('a failed commit-authorship fetch records null and loses no check run', async () => {
  const recorded: any[] = [];
  const verdicts = await evaluate(ctx(27), riskDeps(27, {
    fetchCommitAuthorship: async () => { throw new Error('502'); },
    recordEvaluation: async (r: any) => { recorded.push(r); },
  }) as any);
  assert.equal(verdicts.length, 2);
  assert.equal(recorded[0].commitAuthorship, null);
});

test('a non-candidate still records both recorders', async () => {
  // The rejected case is when a reader most wants to know what was observed.
  const recorded: any[] = [];
  await evaluate(ctx(37), riskDeps(37, {
    recordEvaluation: async (r: any) => { recorded.push(r); },
  }) as any);
  assert.notEqual(recorded[0].commitAuthorship, undefined);
  assert.equal(typeof recorded[0].wouldHaveMergedInWindow, 'boolean');
});
```

Note the first test requires `fetchCommitAuthorship`'s call site in
`evaluate.ts` to be wrapped — if it is not, this test fails and the wrap is the
fix, not the assertion.

- [ ] **Step 9: Run tests to verify they pass**

Run: `pnpm run typecheck && pnpm test`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add src/commit-authorship.ts src/merge-window.ts src/evaluate.ts src/ledger.ts tests/
git commit -m "feat(ledger): record commit authorship and merge window, gating neither"
```

---

## Task 6: "Recorded, not enforced" — show what is being collected

A check that silently collects a security-relevant observation and never mentions it is indistinguishable from one that never collected it. A team cannot tell what the service already knows, cannot argue with a value that looks wrong, and cannot ask for it to become a gate.

**Files:**
- Modify: `src/render.ts`
- Modify: `src/evaluate.ts` (pass the values to both renderers)
- Modify: `docs/policy.md`
- Modify: `tests/render.test.ts`

**Interfaces:**
- Consumes: `CommitAuthorship`, `wouldHaveMergedInWindow` (Task 5); `provenance`, `adoption` from Spec F's `EvalRecord`.
- Produces: `renderEligibility(result, classification, recorded)` and `renderRisk(risk, classification, completeness, recorded)`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/render.test.ts`:

```ts
const RECORDED = {
  commitAuthorship: {
    commits: 3, allBotAuthored: true, allVerified: true, foreignAuthors: [], truncated: false,
  },
  wouldHaveMergedInWindow: false,
};

const GATE_ICONS = ['✅', '❌', '⏭️', '❓'];

test('the eligibility check shows what is recorded but not enforced', () => {
  const out = renderEligibility(eligibilityResult(), classification, RECORDED);
  assert.match(out.summary, /Recorded, not enforced/);
  assert.match(out.summary, /Commit authorship/);
  assert.match(out.summary, /Merge window/);
  assert.match(out.summary, /None of them affects the verdict/);
});

test('the recorded table never uses a gate icon', () => {
  // A ✅ here would read as a passed gate, which is the exact misreading this
  // table exists to prevent. ℹ️ carries no verdict.
  const out = renderEligibility(eligibilityResult(), classification, RECORDED);
  const section = out.summary.slice(out.summary.indexOf('Recorded, not enforced'));
  for (const icon of GATE_ICONS) {
    assert.equal(section.includes(icon), false, `${icon} must not appear in the recorded section`);
  }
  assert.match(section, /ℹ️/);
});

test('a null recorder renders "not recorded", never a zero or a false', () => {
  const out = renderEligibility(eligibilityResult(), classification, {
    commitAuthorship: null, wouldHaveMergedInWindow: undefined,
  });
  assert.match(out.summary, /Commit authorship \| not recorded/);
  assert.doesNotMatch(out.summary, /0 commits/);
});

test('a foreign author is named rather than summarised away', () => {
  const out = renderEligibility(eligibilityResult(), classification, {
    ...RECORDED,
    commitAuthorship: {
      commits: 2, allBotAuthored: false, allVerified: false,
      foreignAuthors: ['scrosby'], truncated: false,
    },
  });
  assert.match(out.summary, /scrosby/);
});

test('a rejected pull request still shows the recorded table', () => {
  // The rejected case is when a reader most wants to know what was observed.
  const out = renderEligibility(rejectedResult(), classification, RECORDED);
  assert.match(out.summary, /Recorded, not enforced/);
});

test('the risk check shows provenance and adoption in the same table', () => {
  const out = renderRisk(riskResult(), classification, FINAL, {
    provenance: [
      { package: 'jose', from: '^6.2.8', to: '^6.2.9',
        fromHadProvenance: true, toHasProvenance: false, lost: true },
    ],
    adoption: { package: 'fastify', version: '5.12.0', dependentCount: 25, directDependentCount: 11 },
  });
  assert.match(out.summary, /Recorded, not enforced/);
  assert.match(out.summary, /jose/);
  assert.match(out.summary, /25/);
});

test('the recorded values change no verdict', () => {
  // The assertion that keeps "shown" from drifting into "enforced".
  const best = renderEligibility(eligibilityResult(), classification, RECORDED);
  const worst = renderEligibility(eligibilityResult(), classification, {
    commitAuthorship: {
      commits: 9, allBotAuthored: false, allVerified: false,
      foreignAuthors: ['a', 'b'], truncated: true,
    },
    wouldHaveMergedInWindow: false,
  });
  assert.equal(best.title, worst.title);
  assert.equal(
    best.summary.slice(0, best.summary.indexOf('Recorded, not enforced')),
    worst.summary.slice(0, worst.summary.indexOf('Recorded, not enforced')),
  );
});
```

Add `eligibilityResult()` and `rejectedResult()` helpers if the file does not already have equivalents — reuse whatever it uses for `renderEligibility` today rather than introducing new ones.

- [ ] **Step 2: Run tests to verify they fail**

Run: `node --import tsx --test tests/render.test.ts`
Expected: FAIL — `renderEligibility` takes two arguments.

- [ ] **Step 3: Add the shared table to `src/render.ts`**

```ts
/**
 * Values observed on every evaluation that deliberately affect no verdict.
 *
 * Fields are optional and rendered defensively: this shape grows as later specs
 * add recorders, and a renderer that throws on an absent field would take the
 * check run down with it.
 */
export interface RecordedNotEnforced {
  commitAuthorship?: CommitAuthorship | null;
  wouldHaveMergedInWindow?: boolean;
  provenance?: ProvenanceObservation[] | null;
  adoption?: Adoption | null;
}

// DELIBERATELY NOT from the gate vocabulary (✅ ❌ ⏭️ ❓). A ✅ in this table
// would read as a passed gate, which is the exact misreading the table exists
// to prevent. ℹ️ asserts nothing.
const RECORDED_ICON = 'ℹ️';

const NOT_RECORDED = 'not recorded';

/** One row per recorder that has something to say. Absent recorders say so. */
function recordedRows(recorded: RecordedNotEnforced): [string, string][] {
  const rows: [string, string][] = [];

  if ('commitAuthorship' in recorded) {
    const a = recorded.commitAuthorship;
    rows.push(['Commit authorship', a === null || a === undefined
      ? NOT_RECORDED
      : `${a.commits} commit${a.commits === 1 ? '' : 's'}, `
        + (a.allBotAuthored ? 'all bot-authored' : `also authored by ${a.foreignAuthors.map((f) => `\`${f}\``).join(', ')}`)
        + (a.allVerified ? ', all verified' : ', not all signatures verified')
        + (a.truncated ? ' (first 100 only)' : '')]);
  }

  if ('wouldHaveMergedInWindow' in recorded) {
    rows.push(['Merge window', recorded.wouldHaveMergedInWindow === undefined
      ? NOT_RECORDED
      : recorded.wouldHaveMergedInWindow ? 'inside the declared window' : 'outside the declared window']);
  }

  if ('provenance' in recorded) {
    const p = recorded.provenance;
    const lost = (p ?? []).filter((o) => o.lost === true);
    rows.push(['Provenance', p === null || p === undefined
      ? NOT_RECORDED
      : lost.length === 0
        ? `no package lost npm provenance across ${p.length} bump${p.length === 1 ? '' : 's'}`
        : `${lost.map((o) => `\`${o.package}\``).join(', ')} stopped publishing provenance`]);
  }

  if ('adoption' in recorded) {
    const a = recorded.adoption;
    rows.push(['Adoption', a === null || a === undefined
      ? NOT_RECORDED
      : `\`${a.package}@${a.version}\` — ${a.dependentCount} dependents (${a.directDependentCount} direct)`]);
  }

  return rows;
}

/**
 * The recorded-not-enforced section, or nothing when there is nothing to say.
 *
 * The explanatory sentence is not decoration. Without it a reader has no way to
 * tell this table from the one above it, and a value that looks bad reads as a
 * reason their pull request was rejected.
 */
function recordedTable(recorded: RecordedNotEnforced): string[] {
  const rows = recordedRows(recorded);
  if (rows.length === 0) return [];

  return [
    '### Recorded, not enforced',
    '',
    '_These are observed on every evaluation and stored for tuning. **None of them affects the '
      + 'verdict above.** They are shown so you can see what this service already knows — and tell '
      + 'us if a value looks wrong, or should become a rule._',
    '',
    '| | Observation | Value |',
    '|---|---|---|',
    ...rows.map(([label, value]) => `| ${RECORDED_ICON} | ${label} | ${value} |`),
    '',
  ];
}
```

- [ ] **Step 4: Use it in both renderers**

`renderEligibility` gains a third parameter and splices the section in above `NEVER_BLOCKS`:

```ts
export function renderEligibility(
  result: EligibilityResult,
  classification: ClassificationResult,
  recorded: RecordedNotEnforced = {},
): CheckOutput {
  …
    summary: [
      `**${lead}**`, '',
      context, '',
      gateTable(result), '',
      verdictLine, '',
      ...recordedTable(recorded),
      NEVER_BLOCKS, '',
      LEARN_MORE,
    ].join('\n'),
```

`renderRisk` gains a fourth parameter and does the same, after the legend and the waiting line.

The default `{}` matters: with no recorded values the section is omitted
entirely rather than rendering an empty table, which is what keeps every
existing test that calls these with two arguments passing.

- [ ] **Step 5: Pass the values from `src/evaluate.ts`**

```ts
  return [
    {
      name: ELIGIBILITY_CHECK,
      output: renderEligibility(eligibility, classification, {
        commitAuthorship, wouldHaveMergedInWindow,
      }),
    },
    assessed
      ? {
          name: RISK_CHECK,
          output: renderRisk(assessed.risk, classification, assessed.completeness, {
            provenance: assessed.provenance, adoption: assessed.adoption,
          }),
          externalId: assessed.completeness.final ? 'final' : 'provisional',
        }
      : { name: RISK_CHECK, output: renderRiskNotEvaluated(), externalId: nonCandidateFinal ? 'final' : 'provisional' },
  ];
```

- [ ] **Step 6: Correct `docs/policy.md`'s "Recorded, but not graded" section**

Spec F's section currently ends: *"They surface in the weekly shadow report, not
on your pull request."* That is now false. Replace that sentence with:

```markdown
They appear on your pull request in a **Recorded, not enforced** table on both
checks, and in the weekly shadow report. The table is marked so you can tell at
a glance that nothing in it decided anything — if a value there looks wrong, or
you think it should become a rule, that is exactly the conversation the last
section of this document is for.
```

Extend the same section's bullet list with the two new recorders:

```markdown
- **Commit authorship** — how many commits the branch carries, whether they were
  all authored by the automation account that opened it, and whether their
  signatures verify. A human pushing onto a bot's branch is a known attack
  against auto-merge; this measures how often it happens legitimately before any
  rule is written about it.
- **Merge window** — whether this evaluation fell inside the declared
  business-hours window.
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `pnpm run typecheck && pnpm test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add src/render.ts src/evaluate.ts docs/policy.md tests/render.test.ts
git commit -m "feat(render): show what is recorded but enforces nothing, on both checks"
```

---

## Task 7: Documentation and the honest regression

**Files:**
- Modify: `docs/policy.md`, `AGENTS.md`, `README.md`, `docs/architecture.md`, `docs/call-flows.md`
- Modify: `tests/evaluate.test.ts`

- [ ] **Step 1: `docs/policy.md` — seventeen gates**

Retitle `## The fifteen gates` to `## The seventeen gates` and add two rows in
order, before `freezeOff`:

```markdown
| 15 | **Target branch** | The pull request targets the repository's default branch, or a branch explicitly allow-listed for this repository. A pull request into a long-lived feature branch has different review expectations. |
| 16 | **Not blocked** | No `do-not-automerge` or `hold` label, no `WIP:`/`DRAFT:` title prefix, and not a GitHub draft. **This is your override:** add the label and this service stops considering the pull request, with no ticket and no deploy. |
```

Update the `freezeOff` row to say 17 and to describe the two scopes:

```markdown
| 17 | **Not frozen** | Merge-policy automation is not frozen — neither fleet-wide nor for this repository. The switch lives outside the rules file so it takes effect immediately rather than after a deploy. If the switch cannot be read at all, everything is treated as frozen. |
```

Update the two later "fifteen gates" references.

- [ ] **Step 2: `AGENTS.md`**

Line 5: "the fifteen gates" becomes "the seventeen gates", and add after the
risk-heuristics clause:

```
runtime freeze control at fleet and repository scope (SSM, never cached, unreadable means frozen)
```

Line 10: add to the fan-out description that the hoisted stage is now **three**
parallel fetches — check runs, repository properties and the SSM freeze read —
plus a commits GET for the authorship recorder.

Add a new bullet:

```
- The freeze flag is the ONLY runtime-read configuration in this service; everything else compiles into `src/generated/rules.ts` at build time. `infrastructure/terraform/ssm.tf` carries `ignore_changes = [value]` on the parameter, because without it the next `terraform apply` would silently un-freeze a fleet somebody stopped during an incident — and applies happen on merges to main, which is exactly when people are shipping fixes.
```

- [ ] **Step 3: `README.md`**

Update "the fifteen gates" to seventeen wherever it appears, and add the freeze
switch to the operational notes with the two `aws ssm put-parameter` commands
from the spec.

- [ ] **Step 4: `docs/architecture.md` and `docs/call-flows.md`**

- Add SSM to the external-dependency diagram alongside `api.deps.dev`.
- Update the gate count and the hoisted-fetch description in both.
- Note that `freezeOff` is the one gate whose input is not compiled.

- [ ] **Step 5: The regression, recorded not assumed**

Append to `tests/evaluate.test.ts`:

```ts
test('PR #27 is still a candidate at 17 of 17', async () => {
  const [eligibility] = await evaluate(ctx(27), riskDeps(27) as any);
  assert.match(eligibility!.output.title, /would have been a candidate/i);
  assert.match(eligibility!.output.summary, /\*\*17 of 17 gates passed\.\*\*/);
});

test('a frozen fleet makes PR #27 a non-candidate without changing any other gate', async () => {
  const [eligibility] = await evaluate(ctx(27), riskDeps(27, {
    readFreeze: async () => ({ frozen: true, scope: 'global' }),
  }) as any);
  assert.match(eligibility!.output.title, /not a candidate/i);
  assert.match(eligibility!.output.summary, /\*\*16 of 17 gates passed\.\*\*/);
});
```

- [ ] **Step 6: Full verification**

```bash
pnpm run typecheck && pnpm test && pnpm run build
grep -rn 'fifteen gates\|15 of 15\|rules\.freeze\|of 15 gates' src/ docs/ tests/ *.md
```

Expected: all three pass; the grep returns nothing.

- [ ] **Step 7: Commit**

```bash
git add docs/ AGENTS.md README.md tests/evaluate.test.ts
git commit -m "docs: seventeen gates, the runtime freeze switch, and the recorded table"
```

---

## Task 8: Live validation

**Files:** none — verification against the deployed service.

- [ ] **Step 1: Open the PR and let CI deploy to QA**

```bash
gh pr create --repo bankrate/zapp --base main \
  --title "feat(PLAT-1184): human override — runtime freeze, blocking labels, base-branch gate" \
  --body "Implements docs/superpowers/zapp/specs/2026-08-26-controls-and-override-design.md (Spec G)."
```

- [ ] **Step 2: Confirm the parameter exists and the Lambda can read it**

```bash
aws ssm get-parameter --name /zapp/freeze --query 'Parameter.Value' --output text
```

Expected: `false`. If this returns `ParameterNotFound`, the Terraform apply has
not run yet — wait for it rather than creating the parameter by hand, or the
next apply will fight you.

- [ ] **Step 3: Trigger an evaluation and confirm 17 of 17**

Close and reopen the newest open dependabot PR on
`bankrate/platform-cicd-v2-demo`, then:

```bash
gh api repos/bankrate/platform-cicd-v2-demo/commits/<headSha>/check-runs \
  --jq '.check_runs[] | select(.name=="merge-policy/eligibility") | {title: .output.title, conclusion}'
```

Confirm the summary says **17 of 17 gates passed**, both new gates appear in the
table, the **Recorded, not enforced** section is present, and `conclusion` is
still `neutral`.

- [ ] **Step 4: Prove the freeze actually stops it — then put it back**

```bash
aws ssm put-parameter --name /zapp/freeze --value true --overwrite
```

Re-trigger the same pull request and confirm the eligibility check now says
**not a candidate**, first failure `freezeOff`, and the cell reads
`frozen (global)`.

**Then immediately:**

```bash
aws ssm put-parameter --name /zapp/freeze --value false --overwrite
aws ssm get-parameter --name /zapp/freeze --query 'Parameter.Value' --output text
```

Expected: `false`. **Do not skip this.** A freeze left on is silent — every
subsequent evaluation reports not-a-candidate and looks like a working service.

- [ ] **Step 5: Prove per-repo scope**

```bash
aws ssm put-parameter --name /zapp/freeze/bankrate/platform-cicd-v2-demo --value true --type String
```

Re-trigger; confirm the cell reads `frozen (repo)`. Then remove it:

```bash
aws ssm delete-parameter --name /zapp/freeze/bankrate/platform-cicd-v2-demo
aws ssm get-parameters --names /zapp/freeze /zapp/freeze/bankrate/platform-cicd-v2-demo \
  --query '{found: Parameters[].Name, missing: InvalidParameters}'
```

Expected: `found` lists only `/zapp/freeze`, and `missing` lists the per-repo
name. That output is also a direct demonstration of the found/not-found
distinction the implementation relies on.

- [ ] **Step 6: Test the label override end to end**

Add `do-not-automerge` to the demo PR, re-trigger, and confirm the first failure
is `notBlocked` naming the label. Remove the label afterwards.

- [ ] **Step 7: Report the outcome**

State plainly: the gate count, whether both freeze scopes stopped evaluation,
whether the parameter is back to `false`, whether the label override worked, and
what the recorded table showed for commit authorship on a real dependabot PR —
that last one is the first data point on the question Phase 1 has to answer.

---

## Definition of done

- [ ] `/zapp/freeze` exists; `aws ssm put-parameter` stops the fleet on the next delivery with no deploy *(Tasks 1, 8)*
- [ ] `/zapp/freeze/{owner}/{repo}` stops one repository without touching the others *(Tasks 1, 8)*
- [ ] Global `false` plus repo `true` is **frozen** — OR, never override *(Task 1)*
- [ ] Both scopes are read in one `GetParameters`, once per evaluation, never cached, proven by call count *(Task 1)*
- [ ] A failed call means frozen; an absent parameter means not frozen; a non-boolean value means frozen *(Task 1)*
- [ ] The SSM parameter carries `ignore_changes = [value]` so an apply cannot un-freeze an incident *(Task 1)*
- [ ] `rules.freeze` is removed from `policy-rules.yaml` and its presence fails the build *(Task 2)*
- [ ] The `enable_ssm_permissions` comment explains the scoped grant rather than contradicting itself *(Task 1)*
- [ ] `baseBranchAllowed` and `notBlocked` land before `freezeOff`, which stays last at 17 *(Task 4)*
- [ ] Draft PRs fail `notBlocked` independently of the title pattern *(Task 4)*
- [ ] An uncompilable `blockingTitlePattern` fails the build, not the Lambda *(Task 4)*
- [ ] Labels, base ref and draft state are identical across both trigger paths *(Task 3)*
- [ ] `commitAuthorship` and `wouldHaveMergedInWindow` are recorded and gate nothing *(Task 5)*
- [ ] A null author counts as foreign, not as fine *(Task 5)*
- [ ] Both checks carry a "Recorded, not enforced" table using ℹ️, never a gate icon *(Task 6)*
- [ ] The risk check's table shows Spec F's `provenance` and `adoption`, and `docs/policy.md`'s "not on your pull request" line is corrected *(Task 6)*
- [ ] Worst-case recorded values produce an identical verdict to best-case — shown is not enforced *(Task 6)*
- [ ] PR #27 is still a candidate at 17 of 17 *(Task 7)*
- [ ] Both checks remain `neutral` and on no required-checks configuration *(Task 8)*
