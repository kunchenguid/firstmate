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
The worker runs no-mistakes through the isolated fork registration, waits for fork CI, and the captain merges the fork pull request with the regular merge method so the topic merge remains reachable.

Discarding selects only the named topic's first-parent integration merges and reverts them newest to oldest with mainline parent one:

```sh
bin/fm-fork-topic.sh discard --id <id> --repo <isolated-worktree>
```

A manifest-only overlap from a later topic is preserved mechanically while the named entry is removed.
Any product-file conflict stops for re-justification.
The resulting branch still goes through no-mistakes, fork CI, pull request, and captain approval.

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

`pending` means upstream review remains open.
`rejected-but-retained` means upstream declined it but current evidence still justifies carrying it.
`private` means it is intentionally not proposed upstream and should remain small.
`superseded` is immediate removal debt and must be empty after an upstream integration.

An upstream-sync record keeps the pre-merge fork SHA, previous and incoming upstream SHA, date, and touched divergence IDs.
Counts are derived from Git rather than copied into the manifest.
The history stays bounded to the latest 20 integrations.

Update the manifest in the same fork integration or upstream merge that changes the divergence set.
A follow-up is not acceptable because a stale manifest looks authoritative.

## Health report

Run the local deterministic report with:

```sh
bin/fm-fork-status.sh
```

Add `--refresh` to fetch both remotes and compare recorded GitHub pull-request dispositions through `gh-axi`.
Add `--json` for schema `firstmate.fork-health.v1`.
Candidate helpers use `--facts-only` internally when an already-authorized add or discard can legitimately make the historical count rise; that mode still prints the trend but makes its exit status represent Git/manifest consistency and superseded debt rather than holistic fork health.
Do not use `--facts-only` to characterize the fork to the captain.

The report uses `git cherry upstream/main origin/main` for patch-equivalence facts and groups active patches by canonical topic.
It reports active unit and patch counts, trend since the previous upstream merge, counts by class, oldest pending unit, last merge's touched units, retirement conditions, superseded debt, and every Git/manifest mismatch.

A merge revert leaves both the original patch and its inverse in history, so both remain raw `git cherry +` facts after their net effect is gone.
The status owner excludes a pair from active health only when Git proves the exact reachable `git revert -m 1 <topic-merge>` relationship.
It reports the excluded count as retired history rather than hiding it.

The report is unhealthy when a factual patch has no manifest owner, a patch has multiple owners, an active unit owns no patch, one canonical topic has several non-equivalent commits, a topic or integration merge is missing, declared paths omit a changed file, a pull-request disposition is stale, any superseded unit remains, or retained patches trend up.
Git facts win whenever prose disagrees.

`git range-diff` remains a human review tool because Git documents its output as version-unstable and not machine-readable.
When the latest upstream integration touched a divergence, the health report prints the exact `git range-diff --remerge-diff` command for review.
Export one topic's portable patch with `git format-patch upstream/main..fm/divergence/<id>`.

## Upstream integration

`/updatefirstmate` keeps live homes fast-forward-only.
It fetches and advances safe homes from already validated fork `origin/main`, then reports whether official upstream still needs a separate integration.
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

A clean result creates a two-parent upstream merge, removes manifest units whose canonical patch is now equivalent upstream, records the sync input, runs `git range-diff --remerge-diff`, and validates health against candidate `HEAD`.
It does not push or invoke no-mistakes.
The worker validates through the fork registration and opens a fork-main pull request.

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

The decision action is `retain` or `remove`.
An upstream conflict with no manifest path owner uses the explicit `__unowned__` ID and still requires a reason.
The helper refuses a changed branch, changed merge head, missing decision, short reason, or unresolved index.

Rerere records the accepted resolution and can replay it on the next equivalent conflict.
Because `rerere.autoupdate=false`, replay changes the working tree but keeps unmerged index stages, preserving the review and re-justification barrier.
Rerere cannot recover conflict resolutions made before it was enabled.

After the fork pull request lands, `/updatefirstmate` performs only safe fast-forwards from fork main into the operating primary, local secondmate homes, remote code roots, and remote homes.

## Upstream review after local adoption

Upstream review is evidence, not the local shipping gate.
A change enters use only after its topic validation, fork merge candidate validation, green fork CI, captain-approved fork pull request, and safe fleet update.

If upstream rejects a useful running change, reclassify it from `pending` to `rejected-but-retained` in the next validated fork integration.
Keep or sharpen its falsifiable retirement condition.
Do not roll it back merely because upstream declined it, and do not leave it mislabeled.

If upstream review reveals a correctness or security problem that applies locally, prior local validation does not overrule that evidence.
Fix the topic or use the independent discard path immediately.

When upstream accepts an equivalent patch, `git cherry` removes it from the active patch set even when squash or rebase changed the SHA.
The next upstream integration removes its manifest unit while preserving upstream's implementation.
A materially edited upstream version can still conflict, which is exactly when range-diff and the retirement condition must decide which behavior remains.
