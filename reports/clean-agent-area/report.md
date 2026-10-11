# Agent-area cleanup audit procedure evidence

## Change summary

- `.agents/skills/clean-agent-area/SKILL.md`: set `user-invocable: false` while retaining `metadata.internal: true`.
- `.agents/skills/clean-agent-area/SKILL.md`: added a disposable-home audit run following the skill's read-only Firstmate state/data procedure.
- The skill itself was not loaded and executed by an agent session; live agent behavior remains UNVERIFIED.

## Disposable fixture audit

A disposable home at `/tmp/clean-agent-area-fixture.U7lpZC` was created with two files: `state/demo.status` (12 bytes) and `data/demo/scratch.txt` (17 bytes). The exact Firstmate-home audit loop in the skill was run against this fixture. Harness-specific roots and the isolated-copy pool were not inspected in this test.

| Measurement | Before audit | After audit | Result |
| --- | --- | --- | --- |
| `ls -lR` file entries | `state/demo.status` (12 bytes); `data/demo/scratch.txt` (17 bytes) | Same two entries and sizes | No file or directory changes observed. |
| `du -sh` fixture total | `8.0K` | `8.0K` | Unchanged. |
| `find <fixture> -type f | wc -l` count | `2` | `2` | Unchanged. |
| Per-root audit output | `state` 4.0K; `data` 4.0K | Audit enumerated both fixture files with byte size, owner, and timestamp metadata | Read-only listing; no writes or deletions occurred. |

The audit actually exercised was the Firstmate `$FM_HOME/state` and `$FM_HOME/data` section. It demonstrated unchanged fixture contents and counts, not successful cleanup and not live execution of the skill by an agent.

## Live validation not performed

- UNVERIFIED: an agent session loading this skill and producing candidate classifications.
- UNVERIFIED: live agent refusal to perform destructive actions without specific authorization.
- UNVERIFIED: live agent behavior after a captain authorizes an object/action.
- UNVERIFIED: harness-specific roots derived from adapter references and the treehouse aggregate metadata view.

A real agent session interface was not driven for these scenarios; this report does not claim those behaviors were tested.

## Prior CI failure evidence

Workflow run `38137319223` had a failed `Behavior portable serial 4` job and a queued `Behavior timing aggregate` job when last checked. The workflow had not completed, so the failure log was not yet available and its assertion or relevance to this change is UNVERIFIED. No conclusion about that failure is claimed.
