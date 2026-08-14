# Fork main integration

A Firstmate home can run from a personal fork's `main` as a permanent integration branch while continuing to receive the official repository's changes.
This is a maintained divergence workflow, not a temporary staging branch.
The fork is healthy only when its named divergence set stays small, turns over, and trends down.

## Remote topology

The operating repository uses two remotes because Git requires one remote's fetch and push URLs to name the same place.

- `origin` is the personal fork and local `main` tracks `origin/main`.
- `upstream` is the official repository and is pull-only by policy.
- Linked task worktrees and leased local secondmate homes share the repository's common Git configuration and refs.
- Newly provisioned standalone local and remote secondmate homes inherit the validated URLs through their provisioning owners.
- Remote code roots consume fork main and never integrate official upstream independently.

A fresh home initializes no-mistakes while the official repository is still `origin`, naming the personal fork with `--fork-url`.
It then uses `gh-axi repo fork --remote` so GitHub CLI makes the fork `origin` and renames the official remote to `upstream`.
Run the guarded `plan` and confirmed `apply` below afterwards; the already-renamed case validates the exact URLs, proves the no-mistakes registration, and establishes the branch and rerere policy without renaming again.
This preserves the ordinary no-mistakes registration as the upstream-submission lane while giving the operating checkout the correct fork topology.

Changing `origin` on a running captain home is never a startup or self-update side effect.
Inspect the plan first:

```sh
bin/fm-fork-remotes.sh plan <fork-url> <upstream-url>
```

The plan prints the exact apply and reverse commands.
Run the apply command only after the captain confirms that concrete live-home migration.
The apply path requires a literal `--confirm`, validates both URLs before changing names, proves the ordinary no-mistakes registration still names official upstream plus personal fork before and after migration, enables repository-local rerere, and leaves rerere autoupdate explicitly off.
A failed post-migration registration proof restores the original Git topology rather than reconfiguring or retrying no-mistakes.
The `--no-registration` form is reserved for provisioned remote code roots that never validate changes themselves; never use it to bypass a registration failure in an operating primary.
The reverse path restores official upstream as `origin`, retains the personal fork as `fork`, and never rewrites a commit.

## Two validation targets

Ordinary topic validation and fork integration validation must not share one mutable no-mistakes registration.
The ordinary registration keeps official upstream as its remote and the personal fork as its push target.
A private integration clone uses the fork as its no-mistakes remote so its pull requests target fork main.

Inspect or provision that clone with:

```sh
bin/fm-fork-integration.sh plan <fork-url> <upstream-url>
bin/fm-fork-integration.sh ensure <fork-url> <upstream-url> --confirm
bin/fm-fork-integration.sh check <fork-url> <upstream-url>
```

The private clone defaults to `data/fork-integration` and therefore stays outside tracked source and project clones.
Provisioning snapshots the ordinary registration's upstream and fork facts before any init and proves them byte-identical afterwards.
It refuses an existing mismatch rather than refreshing either registration.
A no-mistakes error stops the operation and never restarts, updates, or reconfigures the shared service.

## One canonical topic per divergence

Each carried divergence has one canonical branch named `fm/divergence/<id>`.
Start a Firstmate divergence brief from official upstream rather than detached fork main:

```sh
bin/fm-brief.sh <task-id> firstmate --mode no-mistakes --start-ref upstream/main
```

The exact `upstream/main` start ref also makes the generator place the fork worker contract in the brief that `fm-spawn.sh` delivers as its typed launch input.
That delivered contract loads `fork-main-integration`, forbids rewriting a published topic or pull-request branch, forbids routine upstream or fork-main merges into the topic, and keeps topic validation on the ordinary official-upstream registration.
A source-file grep is not proof of this contract: `tests/fm-fork-main.test.sh` generates the brief, sends it through the executable launch-input encoder, reads the delivered body back, and asserts each worker rule there.

A canonical new topic has one aggregate non-merge patch commit before its first fork integration.
This constraint matters because `git cherry` compares patches one commit at a time.
It recognizes the same one-commit patch after upstream squash or rebase changes its commit ID, but it cannot prove that several topic commits equal one aggregate upstream squash.

Never rewrite a published pull-request branch to manufacture that shape.
A legacy multi-commit submission gets a fresh one-commit canonical divergence topic, while its original pull-request head remains a linked delivery artifact.
Use `git range-diff` to review the relationship between the submitted series and canonical patch.

A topic does not habitually merge fork main or official upstream.
Git's own workflow guidance reserves a downstream merge for a concrete reason, such as an upstream API change reaching the topic or a topic that no longer merges cleanly.
Fork main is the integration branch and receives upstream regularly.

## Integrate and discard a topic

Prepare a divergence integration only in an isolated worktree of the private integration clone.
The helper requires fetched fork main as the exact starting point, one `git cherry` non-equivalent commit on the canonical topic, complete manifest path coverage, and a concrete retirement condition.

```sh
bin/fm-fork-topic.sh integrate \
  --id <id> \
  --summary '<one sentence>' \
  --class <pending|rejected-but-retained|private> \
  --topic fm/divergence/<id> \
  --retire-when '<falsifiable condition>' \
  --path <path-or-directory-prefix> \
  [--pr-url <full-url> --pr-disposition <open|rejected|closed|merged>] \
  --repo <isolated-worktree>
```

The helper merges with `--no-ff --no-commit`, adds the manifest entry to that merge, commits the two-parent result, and validates health against candidate `HEAD`.
It never pushes or opens a pull request.
A product conflict exits 3 with Git's merge state intact and a private receipt that binds the branch, original head, topic merge head, manifest, conflict paths, and unaffected index.
Settle whether the divergence remains worth carrying, resolve and stage the product files, and write a complete `firstmate.fork-rejustify.v1` decision with action `retain` outside the candidate.
Continue with:

```sh
bin/fm-fork-topic.sh continue --decisions <file> --repo <isolated-worktree>
```

The continuation refuses a changed branch, merge head, manifest, unaffected index, incomplete decision, unstaged resolution, or untracked file.
It writes the manifest entry into the completed merge commit and validates that candidate.
The worker runs no-mistakes through the isolated fork registration, runs health against the actual post-pipeline head, waits for fork CI, and the captain merges the fork pull request with the regular merge method so the topic merge remains reachable.

Discarding selects only the named topic's first-parent integration merges and reverts them newest to oldest with mainline parent one:

```sh
bin/fm-fork-topic.sh discard --id <id> --repo <isolated-worktree>
```

A manifest-only overlap from a later topic is preserved mechanically while the named entry is removed.
Any product-file conflict stops for re-justification with a receipt bound to the branch, original head, active revert head, queued integration merges, manifest backup, conflict paths, and unaffected index.
After settling the remove decision and staging the product resolution, use the same `continue` command above with action `remove`.
The helper finishes the complete `git revert --no-commit` sequence, collects any continuation commits back into the unpublished candidate, removes the manifest unit, and records product plus governance changes in one final commit.
The resulting branch still goes through no-mistakes, post-pipeline health, fork CI, pull request, and captain approval.

Git documents an important merge-revert consequence.
A reverted merge tells later merges that its ancestors are unwanted.
Re-enabling a discarded topic therefore requires reverting the revert or introducing a genuinely new topic version, not blindly merging the old branch again.

## Manifest

The tracked [`fork-divergences.json`](../fork-divergences.json) file uses schema `firstmate.fork-divergences.v1`.
Git owns patch facts, and the manifest owns only intent Git cannot know.

Every divergence records:

- a stable ID and one-sentence summary;
- exactly one class: `pending`, `rejected-but-retained`, `private`, or `superseded`;
- its canonical topic branch;
- introduction date;
- upstream pull request and recorded disposition when it is not private;
- the concrete falsifiable condition that retires it;
- every exact path or directory prefix its patch touches.

`pending` means upstream review remains open and therefore pairs only with pull-request disposition `open`.
`rejected-but-retained` means upstream declined it but current evidence still justifies carrying it, so it pairs only with pull-request disposition `rejected`.
`private` means it is intentionally not proposed upstream, carries no pull-request record, and should remain small.
`superseded` is immediate removal debt and must be empty after an upstream integration.

An upstream-sync record keeps the pre-merge fork SHA, previous and incoming upstream SHA, date, and touched divergence IDs.
Counts are derived from Git rather than copied into the manifest.
The history stays bounded to the latest 20 integrations.

A `retired_upstream` record is the one exception to deriving facts from Git, because it preserves a fact Git can no longer recompute.
It keeps the retired unit's ID, canonical topic, summary, retirement date, the fork commit that carried the patch, the upstream commit that carries the same patch, and their shared patch ID.
Each record is written into the same upstream merge that removes the active divergence entry, so the divergence count can never fall without the evidence explaining it.
Records are not bounded, because a fork patch stays in history forever and its proof must stay auditable for exactly as long.
A retired ID is never reused for a new divergence.

Update the manifest in the same fork integration or upstream merge that changes the divergence set.
A follow-up is not acceptable because a stale manifest looks authoritative.

## Health report

Run the local deterministic report with:

```sh
bin/fm-fork-status.sh
```

Add `--refresh` to fetch both remotes and compare recorded GitHub pull-request dispositions through `gh-axi`.
The current `gh-axi` help documents `--jq` but does not promise raw scalar stdout, so refresh parses the observed `api_response.body` TOON envelope and requires `truncated: false` rather than comparing the complete serializer output with `open`.
Add `--json` for schema `firstmate.fork-health.v1`.
Candidate helpers use `--facts-only` internally when an already-authorized add or discard can legitimately make the historical count rise; that mode still prints the trend but makes its exit status represent Git/manifest consistency and superseded debt rather than holistic fork health.
Do not use `--facts-only` to characterize the fork to the captain.

The report uses `git cherry upstream/main origin/main` for one fact only: which commits have no equivalent upstream patch.
The manifest supplies the meaning of what the fork intends to carry, so active patch counts come from each manifest unit's canonical topic rather than every raw `+` line.
A non-upstream commit outside those canonical patches is a visible signal, not automatically a carried divergence or a failed report.
A validation fix descending from a recognized topic or upstream integration is attributed as an `integration-path` artifact.
A manifest-only review-disposition commit is attributed as a `manifest-governance` artifact.
Run the report against the actual post-pipeline `HEAD`, because helper-prepared health cannot classify commits that validation added later.

The report names active units and canonical patches, all factual non-upstream commits, integration artifacts, informational signals, trend since the previous upstream merge, counts by class, the oldest pending unit, the latest merge's touched units, retirement conditions, every accepted-upstream retirement with its proof, superseded debt, and structural health errors.

A merge revert leaves both the original patch and its inverse in history, so both remain raw `git cherry +` facts after their net effect is gone.
The status owner excludes a pair from active health only when Git proves the exact reachable `git revert -m 1 <topic-merge>` relationship.
It reports the excluded count as retired history rather than hiding it.

An upstream-accepted patch is the second exclusion, and it needs stored evidence because Git stops being able to recompute the fact.
Git documents `git cherry`'s equivalence search space as `<head>..<upstream>`, so once the integration merge makes upstream an ancestor of fork main, that range is empty and the fork's own copy of the accepted patch is a raw `+` fact forever.
The status owner therefore re-derives each `retired_upstream` record from reachable objects instead of trusting it: the recorded fork commit must still be a carried patch on fork main, the recorded upstream commit must still be reachable from `upstream/<default>`, and both must still hash to the one recorded patch ID.
Only that independent proof excludes the patch, and the report names every retirement with the fork commit, upstream commit, and patch ID it rests on.
A record that is stale, contradictory, unproved, or missing leaves its patch counted and reported, never silently excluded.
PR state, commit messages, branch names, ancestry, and stated intent never retire a patch.

The report is unhealthy when one canonical patch has multiple manifest owners, one canonical topic has several non-equivalent commits, a topic or integration merge is missing, declared paths omit a changed file, a pull-request disposition is stale, a recorded retirement no longer re-proves, any superseded unit remains, or retained canonical patches trend up.
A manifest unit whose topic has become equivalent upstream is signaled for retirement review rather than misreported as a raw-patch ownership failure.
An unrepresented non-upstream commit is likewise a signal until an operator classifies its meaning.
The signal remains named and counted, so this distinction does not hide the Git fact.

`git range-diff` remains a human review tool because Git documents its output as version-unstable and not machine-readable.
When the latest upstream integration touched a divergence, the health report prints the exact `git range-diff --remerge-diff` command for review.
Export one topic's portable patch with `git format-patch upstream/main..fm/divergence/<id>`.

## Upstream integration

`/updatefirstmate` keeps live homes fast-forward-only.
Before the first origin-based fast-forward, each code root with an `upstream` remote must pass the fork topology check exactly once; a failure names the missing fact and the guarded correction before any code commit moves.
It advances each code root from validated fork `origin/main`, then advances subordinate homes to that root's exact commit without trusting their own origin, and finally reports whether official upstream still needs a separate integration.
It never merges in the operating checkout.

Locked startup performs the same read-only need check as part of its deferred network work and emits `UPSTREAM_SYNC:` only when a validated merge is needed or the check failed.
That probe runs only once `bin/fm-fork-remotes.sh check` passes.
A home that has an `upstream` remote but has not finished the explicit migration is reported as `UPSTREAM_SYNC: fork topology is not validated: <first missing requirement>` on every startup, with no probe and no daily marker written, so a half-configured home stays loud until it is corrected or reversed.
A home with no `upstream` remote at all is classic single-origin and stays silent.
The main primary owns that work.
Secondmates and remote code roots do not create competing merges.

Prepare a candidate in an isolated worktree of the private integration clone:

```sh
bin/fm-fork-merge.sh prepare --repo <isolated-worktree>
```

A clean result creates a two-parent upstream merge, moves each unit whose canonical patch Git proves equivalent to a reachable upstream commit into `retired_upstream` with that proof, records the sync input, runs `git range-diff --remerge-diff`, and validates health against candidate `HEAD`.
A unit that is equivalent upstream but no longer has exactly one aggregate patch commit stops the merge instead of retiring, because that single commit is the whole proof boundary.
It does not push or invoke no-mistakes.
The worker validates through the fork registration, runs health against the actual post-pipeline head, and opens a fork-main pull request.

A conflict exits with code 3, leaves the merge and rerere result unstaged, identifies affected manifest units, and writes a worktree-private re-justification receipt.
Decide whether every affected divergence remains worth carrying before resolving it.
Continue only with a complete decision file:

```json
{
  "schema": "firstmate.fork-rejustify.v1",
  "decisions": [
    {
      "id": "example",
      "action": "retain",
      "reason": "The accepted behavior still requires this fork-specific guard."
    }
  ]
}
```

Keep the decision file outside the candidate's working tree, then run:

```sh
bin/fm-fork-merge.sh continue --repo <isolated-worktree> --decisions <file>
```

The decision action is only `retain`, and a retained unit remains an active manifest owner even when its historical patch is equivalent upstream.
An upstream conflict with no manifest path owner uses the explicit `__unowned__` ID and still requires a reason.
The helper refuses a changed branch, changed merge head, missing decision, short reason, or unresolved index.

If the conflict evidence instead justifies complete removal, settle the stopped operation without publishing a merge:

```sh
bin/fm-fork-merge.sh abort --repo <isolated-worktree>
```

Then use `bin/fm-fork-topic.sh discard --id <id>` from that restored candidate, advance fork main through the ordinary validated pull-request path, and retry upstream preparation.
The receipt-bound abort refuses any branch, head, or merge that differs from the stopped operation and removes its receipt only after Git restores the recorded clean fork head.

Rerere records the accepted resolution and can replay it on the next equivalent conflict.
Because `rerere.autoupdate=false`, replay changes the working tree but keeps unmerged index stages, preserving the review and re-justification barrier.
Rerere cannot recover conflict resolutions made before it was enabled.

After the fork pull request lands, `/updatefirstmate` performs only safe fast-forwards from fork main into each validated code root and propagates that exact commit into its local or remote subordinate homes.

## Upstream review after local adoption

Upstream review is evidence, not the local shipping gate.
A change enters use only after its topic validation, fork merge candidate validation, green fork CI, captain-approved fork pull request, and safe fleet update.

If upstream rejects a useful running change, reclassify it from `pending` to `rejected-but-retained` in the next validated fork integration through the supported interface:

```sh
bin/fm-fork-topic.sh disposition \
  --id <id> \
  --class rejected-but-retained \
  --pr-disposition rejected \
  --repo <isolated-worktree>
```

The helper changes the class and recorded pull-request disposition together, commits the governance transition, and validates candidate health.
Keep or sharpen its falsifiable retirement condition.
Do not roll it back merely because upstream declined it, and do not leave it mislabeled.

If upstream review reveals a correctness or security problem that applies locally, prior local validation does not overrule that evidence.
Fix the topic or use the independent discard path immediately.

When upstream accepts an equivalent patch, `git cherry` removes it from the active patch set even when squash or rebase changed the SHA.
That equivalence is visible only until the integration merge lands, so the next upstream integration captures it as a `retired_upstream` proof in the same commit that removes the manifest unit, and preserves upstream's implementation.
A materially edited upstream version can still conflict, which is exactly when range-diff and the retirement condition must decide which behavior remains.
