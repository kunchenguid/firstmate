---
name: fork-main-integration
description: >-
  Agent-only procedure for operating Firstmate from a permanent personal-fork main.
  Use before configuring or reversing Firstmate code remotes, briefing a Firstmate divergence topic, provisioning or using the isolated fork validation registration, integrating or discarding a divergence, responding to UPSTREAM_SYNC or upstream-sync output, preparing an upstream merge, re-justifying its conflicts, or deciding what the fork still carries.
user-invocable: false
metadata:
  internal: true
---

# fork-main-integration

Load this procedure only when the Firstmate code repository itself uses permanent fork-main integration.
[`docs/fork-main.md`](../../../docs/fork-main.md) is the operator-current owner.
The script headers own exact mechanics and arguments.

## Safety boundaries

- `origin` is the personal fork and `upstream` is official.
- Never migrate the captain's operating checkout as a side effect.
  Run `bin/fm-fork-remotes.sh plan`, show the reverse command, and obtain concrete captain confirmation before the live `apply` command.
- Never reconfigure the ordinary no-mistakes registration to target fork main.
- Normal live-home remote migration must prove that registration before and after the Git change.
  The `--no-registration` exception belongs only to provisioned remote code roots that never validate changes, and is never a retry or bypass after a registration error.
- Provision a separate private integration clone only through `bin/fm-fork-integration.sh`.
  Stop if ordinary-registration isolation cannot be proven before and after init.
- Never restart or update the shared no-mistakes service from this workflow.
- Live homes remain fast-forward-only consumers of validated fork main.
  Real upstream and topic merges happen only in isolated candidates.
- Keep `rerere.autoupdate=false`.
  A replayed resolution must remain unstaged and reviewable.
- Never force-push or rewrite a published topic or pull-request branch.
- Never habitually merge upstream or fork main into a divergence topic.
  Do so only for a concrete API dependency, a real merge conflict, or an upstream maintainer request.
- Every fork-main PR still requires the captain's explicit merge approval.

## New divergence intake

1. Scaffold the Firstmate ship brief with `--start-ref upstream/main` so unrelated fork divergences cannot enter the upstream pull request.
2. Run the ordinary no-mistakes path against the official-upstream registration.
3. Preserve the upstream pull request as the delivery and review artifact.
4. Before fork integration, ensure the canonical `fm/divergence/<id>` topic contains one aggregate non-merge patch commit relative to upstream.
   `git cherry` is patch-by-patch and cannot prove that a multi-commit topic equals one upstream squash commit.
5. Never rewrite a published multi-commit PR branch to satisfy step 4.
   Create a fresh one-commit canonical divergence topic and retain the original head as the manifest-linked delivery artifact.
6. Create an isolated candidate from fetched fork main in the private integration clone.
7. Run `bin/fm-fork-topic.sh integrate` with a concrete retirement condition and complete path list.
8. Drive no-mistakes from that integration clone, open the fork-main PR, and require fork CI green.
9. Tell the captain the full fork PR URL and concise local outcome.
10. Merge only after the captain says so, using the regular merge method so the inner topic merge remains reachable.
11. Run `/updatefirstmate` after landing so safe homes fast-forward from validated fork main.

A vague retirement reminder is not a valid manifest condition.
Use a falsifiable statement such as "Upstream ships equivalent endpoint identity validation" or "This compatibility path is no longer reachable on every supported backend".

## Upstream review disposition

A pending divergence whose PR closes without merge must not remain pending.
Choose one of two outcomes in the next validated fork integration:

- Reclassify it to `rejected-but-retained` because current evidence still justifies the behavior.
- Discard it because its retirement condition is true or the evidence no longer supports carrying it.

Upstream rejection does not automatically remove useful running behavior.
A correctness or security finding that applies locally is stronger evidence than the earlier green run and requires an immediate fix or discard.

## Upstream integration

Handle `UPSTREAM_SYNC: required` or `upstream-sync: required` as work for the main primary, never a secondmate or remote code root.
Coalesce duplicate notifications behind one open integration task.

1. Ensure the private fork registration passes `bin/fm-fork-integration.sh check`.
2. Create an isolated candidate branch at fetched `origin/main` from the private integration clone.
3. Run `bin/fm-fork-merge.sh prepare`.
4. On a clean result, inspect the emitted `git range-diff --remerge-diff` review and health result before starting no-mistakes.
5. On exit 3, treat every named conflict as a divergence re-justification decision before resolving files.
6. Load `ask-user-authority` before deciding whether routine authority can answer a re-justification.
   A material behavior expansion, destructive choice, security-sensitive choice, or captain-owned product trade-off still goes to the captain.
7. Resolve files only after the decision is settled, write the complete `firstmate.fork-rejustify.v1` decision file outside the candidate working tree, and run `continue`.
8. Drive no-mistakes through the private fork registration and process every gate.
9. Require fork CI green and captain merge approval.
10. Use the regular merge method, then run `/updatefirstmate`.

A repeated rerere result does not answer whether the divergence remains valuable.
It only supplies the previously accepted file resolution.
The unmerged index is the barrier that keeps the relevance decision explicit.

## Health and relevance

Use `bin/fm-fork-status.sh` for the local answer and add `--refresh` only when live remote and PR evidence is needed.
Git facts outrank the manifest.
Do not describe the fork as healthy when:

- retained divergence units or active patches trend up;
- any superseded unit remains;
- a pending unit is aging without action;
- a patch lacks exactly one manifest owner;
- a topic has more than one non-equivalent aggregate patch;
- a manifest unit no longer owns a patch;
- declared paths miss changed files; or
- a recorded upstream PR disposition differs from live evidence.

`git range-diff` is a human review surface, not machine state.
Run the command printed by the health report for every unit touched by the latest upstream merge.

## Discard

Prepare discard only from an isolated branch at fetched fork main:

```sh
bin/fm-fork-topic.sh discard --id <id> --repo <isolated-worktree>
```

The helper selects that topic's integration merges only and reverts them newest to oldest.
Any product-file conflict reopens re-justification.
Validate the candidate through the private fork registration and require captain approval for its fork-main PR.
Never reset or rewrite fork main to remove a divergence.

Git remembers a reverted merge as unwanted ancestry.
To restore discarded behavior, revert the revert or introduce a genuinely new topic version.
Do not merge the old topic blindly.
