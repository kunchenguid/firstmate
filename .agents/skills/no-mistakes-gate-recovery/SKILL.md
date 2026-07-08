---
name: no-mistakes-gate-recovery
description: >-
  Agent-only recovery reference for crewmates whose no-mistakes gate or push step fails inside a firstmate task worktree.
  Load when a no-mistakes push, gate, or pipeline step errors before debugging by hand.
user-invocable: false
metadata:
  internal: true
---

# no-mistakes-gate-recovery

Check this list before hand-debugging a no-mistakes failure.
Apply the matching fix, resume the run, and escalate `blocked:` only if the fix fails a second time.
This is a narrow list of confirmed recoveries, not a general troubleshooting guide: a failure mode is added only after it has actually been observed and its fix verified.

## "invalid gate path: ." on the pipeline's first push

The pipeline's first push to its internal gate repo fails with `invalid gate path: .` from inside a treehouse task worktree.
Observed twice on trashtalknyc-website against no-mistakes v1.31.2, 2026-07, by different crews with the identical resolution (tasks revamp-about-x4 / PR #15 and revamp-home-q2 / PR #16).

1. Delete the branch ref on the internal no-mistakes remote: `git push no-mistakes :refs/heads/<your-branch>`.
2. Re-push the branch: `git push no-mistakes <your-branch>`.
3. Resume the run; the pipeline's own version-matched guidance (`no-mistakes axi run --help` and the `help` lines in each `axi` response) is authoritative for the resume mechanics.

Do not modify the code change, do not abort the run, and do not re-validate by hand.
If the push fails again after the ref re-push, append `blocked: no-mistakes gate push failing after ref re-push` to your status file and stop.

The durable fix belongs upstream in no-mistakes and is tracked with root-cause analysis at https://github.com/kunchenguid/no-mistakes/issues/420; this recovery exists so a crewmate is not stranded while that lands.

## Anything else

Follow the pipeline's own version-matched guidance (`no-mistakes axi run --help`, per-response `help` lines).
Escalate through `needs-decision:`/`blocked:` per your brief rather than inventing a workaround.
