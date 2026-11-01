# Claude account binding and release shaping verification

Audience: maintainer verification.

This record supports two current guarantees and is what must be re-established when their inputs change:

- One firstmate home is bound to one terminal session and one Claude account, and every fleet mutation from another session is refused (`bin/fm-home-identity.sh`, `docs/configuration.md` "Home session and account pin").
- Firstmate's own Claude launches onto a shaped credential store are paced at a limit-reset edge, and that store's committed parked demand is measurable (`bin/fm-claude-admission.sh`, `docs/configuration.md` "Claude release shaping").

It records empirical facts only.
Credential paths are shown with the home directory replaced by `<home>`, and no credential value appears here or in any output the tooling produces.

## Claude Code transcript shape the census depends on

Verified 2026-09-02 against Claude Code transcripts under `<home>/.claude-<account>/projects/*/*.jsonl`.

The committed-demand census reads three record shapes and nothing else.
A vendor change to any of them is what invalidates this record.

| Record | Fields read | Meaning |
| --- | --- | --- |
| `type=system`, `subtype=informational`, `level=notice` | `content`, `timestamp`, `sessionId` | The park and resume notices below |
| `type=assistant` | `message.model`, `message.id`, `message.usage` | A real turn; `model` `<synthetic>` is local and not billed |
| `type=continued-in` | position only | The session was forked onward, so its park is not live |

Exact `content` prefixes observed, and how each is classified:

```
Usage limit reached · continuing automatically at 8:20pm · esc or type to cancel      -> park
Usage limit reached again after you continued · continuing automatically ...          -> park
Usage limit reset · continuing automatically                                          -> resume
```

The classifier anchors on the `Usage limit reached` prefix together with the `continuing automatically` marker for a park, and on the `Usage limit reset` prefix for a resume.
Agent-written status prose in the same transcripts also contains the words "session limit"; that prose is deliberately not matched, because only a `type=system` notice record is read.

Billable input per turn is `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` from `message.usage`.
Turns are deduplicated by `message.id`, because a resumed transcript replays prior assistant messages and a naive count doubles them.

A session counts as live committed demand only when its park is the last decisive record in the file, no resume, real turn, or `continued-in` follows it, and the park is no older than `FM_CLAUDE_DEMAND_MAX_AGE`.

## Explicit launch-time Claude store

Verified 2026-11-01 on Linux with Claude Code `2.1.316 (Claude Code)`.
With `HERDR_SESSION=personal`, an explicit `CLAUDE_CONFIG_DIR` is honored by the real Claude executable rather than re-derived from the Herdr session.
This token-free probe uses a throwaway HOME and empty store, not either operator login:

```bash
tmp=$(mktemp -d)
mkdir -p "$tmp/home" "$tmp/store"
env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN \
  HOME="$tmp/home" CLAUDE_CONFIG_DIR="$tmp/store" HERDR_SESSION=personal \
  strace -f -e trace=%file -o "$tmp/paths" claude auth status > "$tmp/status" 2>/dev/null
# Exit 1 is expected: the throwaway store is not logged in.
grep -oE '"[^" ]*(\.credentials.json|\.claude.json)"' "$tmp/paths" | sort -u
```

Observed output (temporary prefix normalized to `<tmp>`):

```text
"<tmp>/store/.claude.json"
"<tmp>/store/.credentials.json"
```

The pin check compares the explicitly exported store as well as the session; `tests/fm-home-identity.test.sh` exercises switching the store while keeping `personal`, refusal of the previous store, and refusal of another session afterward.
The operator launch and clean-exit contract remains in [configuration](../configuration.md#home-session-and-account-pin-datahome-identity).

## Executable coverage

| Guarantee | Test |
| --- | --- |
| A reset-edge herd is staggered one release per interval, highest priority first | `tests/fm-claude-admission.test.sh` |
| A second release inside one slot is withheld and stays durable across processes | `tests/fm-claude-admission.test.sh` |
| Parked demand paces only the store the home lists | `tests/fm-claude-admission.test.sh` |
| An unshaped store's spawn is byte-for-byte unchanged | `tests/fm-claude-admission.test.sh` |
| Malformed or unreadable evidence refuses without losing work | `tests/fm-claude-admission.test.sh` |
| Shaping disarms a horizon after parked demand clears, however many gates arrive inside it | `tests/fm-claude-admission.test.sh` |
| A corrupted durable queue row refuses instead of releasing the herd | `tests/fm-claude-admission.test.sh` |
| An unreadable durable queue refuses on the gate, queue, and withdraw paths | `tests/fm-claude-admission.test.sh` |
| Every poll refusal - unreadable queue, committed demand, shaped-store list, or no nameable store - reaches firstmate on stdout instead of silence, while an unconfigured home stays silent | `tests/fm-claude-admission.test.sh` |
| Each distinct poll refusal wakes firstmate once, a different fault wakes it again, and a cleared fault that recurs is announced | `tests/fm-claude-admission.test.sh` |
| An FM_HOME that is not an existing home refuses and is never pinned | `tests/fm-home-identity.test.sh` |
| Withdrawing one task never drops another whose id differs only by a regex metacharacter | `tests/fm-claude-admission.test.sh` |
| A remote second mate is steered under its home's recorded session and account, and refused under any other | `tests/fm-remote-secondmate-identity.test.sh` |
| A remote second mate's recorded account beats a caller that exports another one, store-bound or default | `tests/fm-remote-secondmate-identity.test.sh` |
| Explicit rebind requires confirmation, credentials and no live lock; preserves the session, archives history, re-seeds local mates and leaves workers unchanged | `tests/fm-home-identity.test.sh` |
| Rebind skips and reports a live second mate and its subtree, keeps a worker-pinned second mate on its pin, and reaches nested second mates | `tests/fm-home-identity.test.sh` |
| With no detectable harness, rebind pins a worker-pinned second mate by its recorded harness and skips it when none is recorded | `tests/fm-home-identity.test.sh` |
| `fm-open.sh` starts the same home on either store from `personal`, is reversible, and refuses a live lock, another session, or a home pinned elsewhere | `tests/fm-home-identity.test.sh` |
| A second mate moved by rebind relaunches on the new store and stays accepted by its own home | `tests/fm-control-relaunch.test.sh` |
| A relaunch of a second mate still pinned to another identity refuses before the agent is stopped | `tests/fm-control-relaunch.test.sh` |
| A home refuses the other session in both directions, and survives a restart | `tests/fm-home-identity.test.sh` |
| A spawn from a foreign session is refused and creates nothing | `tests/fm-home-identity.test.sh` |
| A foreign-session spawn refusal is reported as the session mismatch even when the backlog preflight also refuses | `tests/fm-home-identity.test.sh` |
| A second-mate spawn from a foreign session refuses before touching the child home's worktree, state, or config | `tests/fm-home-identity.test.sh` |
| A withheld second-mate spawn leaves the child home byte-for-byte untouched and keeps the request queued | `tests/fm-claude-admission.test.sh` |
| A spawn refused for any other reason never spends the store's release slot | `tests/fm-claude-admission.test.sh` |
| A pre-store poll refusal that clears and later recurs wakes firstmate again | `tests/fm-claude-admission.test.sh` |
| A worker records and launches on its home's account | `tests/fm-home-identity.test.sh` |
| A relaunch keeps the task's own recorded account, in both directions | `tests/fm-control-relaunch.test.sh` |
| A worker relaunch with `--account` moves it onto another allowlisted seat and rebinds every store, an ineligible seat refuses before the agent is touched, and a second mate is never moved | `tests/fm-control-relaunch.test.sh` |
| A relaunch that is not released yet refuses before the agent is stopped | `tests/fm-control-relaunch.test.sh` |
| A lab anchors to running named sessions while `default` is stopped | `tests/fm-herdr-lab.test.sh` |
| A change to any live session during lab work is a hard tripwire failure | `tests/fm-herdr-lab.test.sh` |
| A fleet with nothing running, or with an ambiguous default, refuses | `tests/fm-herdr-lab.test.sh` |

Run them with `bin/fm-test-run.sh tests/fm-claude-admission.test.sh tests/fm-home-identity.test.sh tests/fm-control-relaunch.test.sh tests/fm-remote-secondmate-identity.test.sh`.

## Live verification

Verified 2026-09-03 on Linux 6.18 (WSL2) with `herdr 0.8.0` and `treehouse 2.1.1`.
Both runs used throwaway credential stores and a stub harness, so no real Claude account was reached and no quota was consumed.
The operator fleet at the time was `default` present but stopped, with two running named sessions kept strictly separate; it was byte-identical afterward.

### Isolated Herdr lab

`bin/fm-herdr-lab.sh` provisioned a named lab session against that fleet, and its tripwire recorded all three sessions.
Proved live on the real Herdr backend through `bin/fm-spawn.sh`: the home pinned itself on first use, a second launch inside one release slot was withheld with no task record created and the request preserved in the durable queue, a work-pinned home refused a personal session and created nothing, and a personal-pinned home refused a work session.
Teardown re-read the fleet and confirmed every session unchanged.

One thing the Herdr path cannot prove from an ordinary operator pane: firstmate's own Herdr backend refuses to place a worker whose launcher pane belongs to a different Herdr server, so a worker cannot be launched into a lab session from a pane living in another session.
That refusal is correct and was not worked around; the pane-level proof below runs on tmux, the verified reference backend, instead.

```
error: herdr launcher pane '<id>' belongs to the server at '<...>/sessions/<other>/herdr.sock',
not session 'fm-lab-<...>' at '<...>/sessions/fm-lab-<...>/herdr.sock';
refusing to place a worker from a cross-session parent identity
```

### Pane-level account binding, on a private tmux server

The tmux adapter has no session override: `fm_backend_tmux_container_ensure` reuses the current `$TMUX` session, else a fixed `firstmate` one.
So the run happened inside a private tmux server (`tmux -L fmlab`), which scopes every call the spawn makes to that server and cannot reach the operator's sessions.

Two real spawns, then each launched process's own environment read from `/proc/<pid>/environ`:

```
work-bound task:      CLAUDE_CONFIG_DIR=<throwaway work store>
personal-bound task:  (no CLAUDE_CONFIG_DIR at all)
```

The personal result is the load-bearing one: the tmux server environment carried a `CLAUDE_CONFIG_DIR`, and the launched process still had none, so the recorded default binding is enforced by unsetting an inherited value rather than by omitting a prefix.

Relaunch account preservation is covered by `tests/fm-control-relaunch.test.sh` rather than here: a stub harness is not a recognizable agent, so the live relaunch path refuses with `endpoint reads 'ambiguous'` before reaching the launch.
