# Accepted red gates

Gates listed here are permitted to be red without failing CI.
`tests/run-all.sh` skips a gate's test only when **both** conditions hold: the gate's status is `red` in `gates/ledger.json`, **and** its id appears below.
Being red is not enough, and being listed is not enough.

That double condition is the whole point.
A runner that skipped whatever happened to be red would mask a real regression the moment a working gate went red, and it would do it silently.
Listing a gate here is a deliberate, reviewable statement that its red is understood and accepted; everything else that goes red still fails the build.

Every entry states the reason, and what would make it go away.
An entry with no route back to green is a bug report, not a baseline.

This file has two readers, and the rule they share has exactly one implementation: `fm_gates_classify` in `bin/fm-gates-lib.sh`, which `tests/run-all.sh` calls to decide what CI may skip and `bin/fm-verify.sh` (the Quarterdeck) calls to decide whether a crewmate's `done:` may be accepted.
Neither restates the double condition; both ask the classifier.

Nobody declares their own red.
A line a branch adds here that its own ledger then leans on has been reviewed by nobody, so the Quarterdeck compares every relied-upon declaration against the merge base and escalates a self-authored one to the captain instead of honouring it.
Adding a baseline is legitimate work; approving one is a human's call.

Format, one per line: `- <gate-id> - <reason>`

- gate-l2-loop-audit-level - Accepted red baseline, unrelated to any work in flight. `loop-audit` scores this repo L1 against a required L2 (score >= 58). Declared out of scope by the captain rather than repaired opportunistically, so that unrelated branches are not conscripted into fixing it. Goes away when the loop docs earn the score; see `docs/specs/2026-07-03-loop-conformance.md`.
- m1-hook-registered - Blocked on another repository, not on work here. The gate asserts that `bin/fm-boot-context.sh` is a registered SessionStart hook, but `~/.claude/settings.json` is rendered from `mac-config`'s desired state and a render deletes undeclared keys, so registration is a declared change there. Asserting on direct invocation instead would go green while a real session still boots blind, which is the exact false green this ledger exists to prevent. Goes away when `docs/declarations/2026-08-27-boot-context-hook-registration.md` is applied in `mac-config` and `stone apply` runs - no further change in this repo.
