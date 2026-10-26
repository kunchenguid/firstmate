# Firstmate add-ons

Add-ons for running a fleet of coding agents on one machine: small, independent fixes for the gaps a busy fleet hits — runaway deletes, burned provider quota, stalled tasks, merges nobody watches. Every add-on installs and removes on its own; take only the ones you need.

Who needs this: anyone running that fleet on their own machine who wants it to keep moving when a provider slows down, a task wedges, or an agent tries something destructive.

Where this is going: [VISION.md](../VISION.md).

## The add-ons

One line per add-on, with how it wires in. `<home>` is your home folder for the fleet manager — the one with `bin/` and `state/` in it.

- `account-pool` — new workers start on the pool account with the most room (`config/account-pool`), and `relaunch --account <id|next>` moves a running worker to another account with no key or token in the launch. Wire in: hook lines in the fork's `bin/fm-spawn.sh` and `bin/fm-control.sh`; check with `account-pool/install.sh <home>`; see `account-pool/README.md`.
- `alerts` — groups tasks stopped by a provider outage into one alert per scan. Dormant copy: the fork still runs its own.
- `bearings-board` — runs the Bearings board from the Firstmate checkout as a thin wrapper, with no copied upstream code. Wire in: `bearings-board/install.sh <home>`.
- `ask-default` — owns owner-only ask authoring (`python3 ask-default/bin/fm-captain-ask.py --help`; after merge, `install <home>` wires the config shim) and an unanswered ask falls back to its pre-declared safe default instead of blocking the home. Needs a fork hook (FORK-EXIT.md).
- `backlog-lock-reclaim` — reclaims a 0-byte `<home>/data/backlog.md.lock` left by a dead tasks-axi writer, once it is older than 60 s and no process has it open; until then every backlog write fails LOCKED. Wire in: `backlog-lock-reclaim/install.sh <home>`.
- `claude-accounts` — one quota view of every signed-in Claude account (5-hour and 7-day left), shown on the dashboard and written for dispatch; new Claude workers start on the account with the most runway. Wire in: `claude-accounts/install.sh <home>` plus the reader on a timer; see `claude-accounts/README.md`.
- `claude-model-guard` — keeps agent runs off Fable (Sonnet is allowed): the fable alias resolves to Haiku, full Fable ids are refused. Wire in: `claude-model-guard/install.sh`.
- `claude-quota` — alarms when the whole Claude account pool (every `claude-accounts` account together) will run dry before its soonest 5-hour or weekly reset. Wire in: `claude-quota/install.sh <home>`.
- `codex-guard` — runs the delete, kill and read guards before every Codex shell command; Codex workers start with hooks off, so Codex's own shell environment carries it. Wire in: `codex-guard/install.sh` after the guards; remove: `codex-guard/uninstall.sh`.
- `delete-guard` — stops any agent from recursively deleting `/` or a home folder; a block alerts you and is final. Wire in: `delete-guard/install.sh <home>`.
- `fleet-contract-check` — runs each real cross-repo call (dispatch-resolve, owner-guard, checks-lint) in a throwaway HOME and names the caller that breaks. Nothing to install: run `fleet-contract-check/fleet-contract-check`.
- `fleet-dashboard` — the read-only fleet dashboard: board, charts, kanban, insights, ship view. Served through the fork shim (FORK-EXIT.md).
- `lookout-adapter` — prints or serves this fleet as the JSON document Lookout reads (`lookout-firstmate`): hosts, homes, lanes, workers, quota, merges, history and devices from the fleet dashboard builder's output; read-only, no secrets.
- `tickets-sync` - reads registered backlogs into sign-off Tickets; see [setup and limits](../tickets-sync/README.md).
- `fleet-flow` — reads fleet lifecycle, queue and bottleneck JSON; installs the home flow check for task slots. Wire in: `fleet-flow/install.sh`.
- `fleet-stall` — alerts you when a team lead idles with ready work, or workers sit stuck waiting on their team lead. Wire in: `FM_HOME=<home> fleet-stall/install.sh`.
- `fleet-stats` — per-model and per-skill fleet statistics plus the task outcome recorder. Dormant copy: the fork still runs its own.
- `fleet-pulse` — appends redacted captain chat from Claude transcripts to a private, gitignored TSV. Wire in: `fleet-pulse/install.sh <home>`.
- `git-identity` — task commits always carry the configured git identity; pushes of foreign-author commits are refused. Wire in: `git-identity/install.sh <home>`, plus a fork hook.
- `key-in-env-check` — wakes Main when any running fleet process carries a provider API key (OPENROUTER, ANTHROPIC, OPENAI, MINIMAX...) in its environment; names only, never a value. It names the pid, home, task and the topmost parent still exporting the key, and writes `state/key-in-env.incidents` for the dashboard. Wire in: `FM_HOME=<home> key-in-env-check/install.sh`; see `key-in-env-check/README.md`.
- `kill-guard` — protects critical services and interactive shells, refuses pattern kills, and permits audited fleet-process kills by verified primary Main; other callers keep descendant/worktree ownership (see [rules and limits](../kill-guard/README.md)). Record device launches with `node guard.mjs own start <serial> -- <command>`; records bind device PID to start time and serial, while unrecorded legacy device processes stay refused (stop a stuck one via its owned host adb parent or have the lead stop it). A block is final, except a kill whose PID the shell sets (`$pid`, `$!`, `%1`), which asks for the literal PID. Wire in: `kill-guard/install.sh`; remove: `kill-guard/uninstall.sh`.
- `read-guard` — blocks agent tool access to provider logins, BYOKit person credentials and no-mistakes config; metadata-only `ls`, `stat`, `test` and `[` checks are allowed. Process/library reads are unaffected. Wire in: `read-guard/install.sh`; remove: `read-guard/uninstall.sh`.
- `glm-queue` — one local line in front of the GLM API, so parallel calls queue instead of hitting rate limits. Wire in: `glm-queue/install.sh`, then point pi at the queue.
- `host-memory` — a gate that makes heavy jobs wait for host memory instead of crashing. Wire in: `host-memory/install.sh`.
- `brief-inherit` — shared worker instructions (`config/brief-include-shared.md`) reach every home's briefs. Needs fork hooks (FORK-EXIT.md); step A only.
- `local-qwen-tuning` — operator reference for the local Qwen model server: launch, tuning, limits, rollback. Reference only, nothing to install.
- `lead-wake` — wakes a secondmate home that sits below its lane floor with ready backlog work, and withdraws the wake when the work is gone, and rings a stalled lead naming its frozen row. Needs fork hooks (FORK-EXIT.md).
- `merge-card` — runs the merge gate and posts one evidence card per merge to the sign-off board. Wire in: config shims, see Install.
- `merge-on-green` — merges a PR you allowed to auto-merge once its checks are green and its proof receipt passes. Wire in: `merge-on-green/install.sh <home>`.
- `nm-drain` — updates the shared pipeline service through a planned drain, never over live runs. Wire in: `nm-drain/install.sh <home>`.
- `owner-rules` - enforces owner asks, backlog hierarchy and risk reasons at brief creation, plus [Lavish refusals for secondmate notes and merge-card posts](../owner-rules/README.md#lavish-refusal-secondmate-notes-and-merge-card-posts).
  Wire in: `owner-rules/install.sh <home>`; brief checks need the brief-inherit seam.
- `pane-titles` — gives worker and lead panes a stable readable terminal title and matching Herdr tab label. Wire in: `pane-titles/install.sh <home>`; remove: `pane-titles/uninstall.sh <home>`.
- `owner-guard` — refuses commits, pushes and PR merges that add the owner's private details, and scans public repos for them once a day. Wire in: `owner-guard/install.sh <home>` and `owner-guard/install-scan.sh`; remove with `owner-guard/uninstall.sh <home>`. Installation reversal covers both hook guards and the daily scan.
- `parked-homes` — a paused team home gets no messages, nudges, relaunches or config pushes. Verify-only install/uninstall: `parked-homes/install.sh`, `parked-homes/uninstall.sh`. Needs fork hooks (FORK-EXIT.md).
- `pipeline-literal-delete` — gives pipeline agents the safe recursive-delete rule in their own instructions. Wire in: `pipeline-literal-delete/install.sh`.
- `pipeline-quota-failover` — moves pipeline model calls to the next model in the chain on a quota error, and pins the pipeline route (Claude Haiku through claude-bridge on the subscription accounts, rotated on a limit, no paid fallback). Wire in: `pipeline-quota-failover/install.sh`.
- `limit-prompt-move` — a Claude worker or lead sitting on Claude's usage-limit menu ("What do you want to do? 1. Stop and wait ...") is interrupted and relaunched on another pool account through `fm-control`, every 5 minutes, never choosing a menu option. Wire in: `limit-prompt-move/install.sh --all <main home>`.
- `quota-axi-pool` — PATH wrapper so dispatch's `quota-axi --json` Claude runway matches `fm-model-pool`'s account reading; upstream quota-axi unchanged. Wire in: `quota-axi-pool/install.sh`; see `quota-axi-pool/README.md`.
- `quota-failover` — relaunches stalled workers onto a live route or the next pool account and rests dead routes until they answer again; moves an idle worker off a pool account at or below 15% before it hits the limit; with an account pool, its Claude route tests run on the pool's pick, never the default login. Wire in: `quota-failover/install.sh --all <home>` (the home and every active local secondmate home it lists).
- `status-wait-check` — refuses `blocked` status text that describes a wait and directs the worker to `paused:`; the fork's `bin/fm-secondmate-report.sh` must call it before appending status (thin hook documented in the add-on README).
- `receipts` — publishes one PASS or FAIL completion receipt per task for guarded landing checks. Dormant copy: the fork still runs its own.
- `route-change` — one command moves worker dispatch, the pipeline gate and team-lead pins to one route together. Wire in: `route-change/install.sh`.
- `sentinel` — re-arms supervision after an agent-runtime restart killed every agent and watcher. Dormant copy: the fork still runs its own.
- `signoff` — turns sign-off board answers into hold answers and merge-gate events. Dormant copy: the fork still runs its own.
- `supervisor-guard` — stops a supervisor session from doing a worker's job, via a pre-tool check. Dormant copy: the fork still runs its own.
- `tailscale-resilience` — heals a Tailscale connection that died while its daemon still runs; alerts on a dead display. Wire in: a systemd timer you add, see Install.
- `wait-timers` — owner-alert and escalation timers for tasks that declared a wait. Dormant copy: the fork still runs its own.
- `zai-quota-check` — alarms when the GLM plan burns ahead of its window, naming the route moves that protect the pipeline. Wire in: `FM_HOME=<home> zai-quota-check/install.sh`.

Every change still on the fork that is not upstream yet, with its exit path and status, is tracked in [FORK-EXIT.md](../FORK-EXIT.md). Add-ons marked "dormant copy" or "fork hook" do not wire into an unmodified install of the host tool yet; FORK-EXIT.md lists the fork changes each one waits for.

## Install

There is no install-all script yet. The shortest real install for the add-ons that work on an unmodified install of the host tool is this loop, run from a clone of this repo (any installer accepts `--dry-run` first to print what it would change and write nothing):

```sh
git clone https://github.com/umeranjum17/juggernaut && cd juggernaut/addons
export FM_HOME=~/firstmate    # your home folder for the fleet manager
for d in pipeline-literal-delete pipeline-quota-failover host-memory fleet-flow glm-queue route-change claude-model-guard; do "$d/install.sh"; done
for d in delete-guard claude-quota merge-on-green git-identity nm-drain owner-guard pane-titles; do "$d/install.sh" "$FM_HOME"; done
read-guard/install.sh
codex-guard/install.sh
FM_HOME="$FM_HOME" fleet-stall/install.sh
FM_HOME="$FM_HOME" owner-guard/install-scan.sh
FM_HOME="$FM_HOME" zai-quota-check/install.sh
quota-failover/install.sh --all "$FM_HOME"   # also each active local secondmate home in data/secondmates.md
```

`route-change` must come after `pipeline-quota-failover` from the same clone (the loop's order). To route GLM calls through the queue, set `.providers.zai.baseUrl` to `http://127.0.0.1:8787/api/coding/paas/v4` in `~/.pi/agent/models.json`; new pi sessions pick it up. `git-identity` prints a note until the fork's launch-env hook is merged — until then lanes stay unguarded.

The delete, kill and read guards put their Claude hook in `~/.claude` and in every Claude account folder listed in the account pool's registry (`~/.muxr/plans/accounts-v1.json`), since a worker started with `CLAUDE_CONFIG_DIR` reads only that folder's settings: rerun them after adding an account.

Two add-ons wire in by hand:

```sh
# merge-card, one shim per home (needs done-done on PATH; see its Details section):
printf '#!/bin/sh\nexec <this-clone>/merge-card/merge-card gate "$@"\n' > "$FM_HOME/config/merge-gate"
printf '#!/bin/sh\nexec <this-clone>/merge-card/merge-card post --board <board.json> "$@"\n' > "$FM_HOME/config/post-merge"
chmod +x "$FM_HOME/config/merge-gate" "$FM_HOME/config/post-merge"
owner-guard/install.sh "$FM_HOME"   # re-chain: the owner-details merge scan runs first, then the shim
```

`tailscale-resilience` installs as a systemd user timer; copy the unit from its Details section. The dormant and fork-hook add-ons install nothing.

## Check

One command per add-on, from the repo root — all of these were run and pass:

```sh
bash claude-quota/tests/claude-quota.test.sh
bash claude-quota/install.sh --dry-run <home>            # what it would write; same shape as every --dry-run below
bash delete-guard/install.sh --dry-run <home>
bash read-guard/tests/read-guard.test.sh
bash claude-model-guard/install.sh --dry-run
bash zai-quota-check/tests/zai-quota-check-e2e.sh
bash pipeline-quota-failover/tests/switch-route.test.sh
bash pipeline-quota-failover/tests/pi-quota-failover-e2e.sh
bash pipeline-quota-failover/tests/pi-quota-failover-route.test.sh
bash pipeline-literal-delete/tests/pipeline-literal-delete.test.sh
bash quota-failover/tests/quota-failover-e2e.sh
bash limit-prompt-move/tests/limit-prompt-move-e2e.sh
FM_TEST_FORK=<fork checkout> bash quota-failover/tests/install.test.sh
bash glm-queue/tests/glm-queue.test.sh
bash route-change/tests/route-change-e2e.sh
bash merge-on-green/tests/merge-on-green.test.sh
bash merge-on-green/tests/no-old-receipt-path.test.sh
bash merge-card/tests/merge-card-e2e.sh
bash owner-rules/tests/owner-rules-gate.test.sh
bash owner-rules/tests/design-flag.test.sh
bash owner-rules/tests/no-lavish.test.sh
bash nm-drain/tests/nm-drain.test.sh
bash owner-guard/tests/owner-guard.test.sh
bash owner-guard/tests/owner-guard-global.test.sh
bash owner-guard/tests/owner-guard-merge.test.sh
bash fleet-stall/tests/fleet-stall-e2e.sh
bash fleet-flow/tests/fm-flow-check.test.sh
bash fleet-pulse/tests/chat-tsv.test.sh
bash fleet-pulse/install.sh --dry-run <home>
bash host-memory/tests/fm-mem-gate.test.sh
bash pane-titles/tests/pane-titles.test.sh
bash git-identity/tests/git-identity.test.sh
parked-homes/install.sh <home>                           # verify-only; prints MISSING until the fork hooks merge
tailscale-resilience/tailscale-resilience check --state-dir /tmp/tsr-check
```

The dormant and fork-hook add-ons are not wired into an unmodified install of the host tool, so there is nothing to check for them here.

## Remove

```sh
claude-model-guard/install.sh --restore                  # removes exactly its keys and hook entries
pipeline-quota-failover/install.sh --restore             # removes the wrapper and its config key
"$FM_HOME/bin/fm-check-unregister.sh" quota-failover-watch
"$FM_HOME/bin/fm-check-unregister.sh" claude-quota       # then rm "$FM_HOME/state/claude-quota.check.sh" ~/.local/share/fm-claude-quota -r
"$FM_HOME/bin/fm-check-unregister.sh" merge-on-green     # then rm "$FM_HOME/state/merge-on-green.check.sh" ~/.local/share/fm-merge-on-green -r
"$FM_HOME/bin/fm-check-unregister.sh" 0-nm-drain         # then rm "$FM_HOME/state/0-nm-drain.check.sh" ~/.local/share/fm-nm-drain -r
"$FM_HOME/bin/fm-check-unregister.sh" fleet-stall        # then rm "$FM_HOME/state/fleet-stall.check.sh" ~/.local/share/fm-fleet-stall -r
"$FM_HOME/bin/fm-check-unregister.sh" zai-quota          # then rm "$FM_HOME/state/zai-quota.check.sh"
rm "$FM_HOME/config/merge-gate" "$FM_HOME/config/post-merge"                    # merge-card (with owner-guard: its config/merge-gate.pre-owner-guard instead of merge-gate)
owner-guard/install.sh --uninstall "$FM_HOME"            # owner-guard: also restores the home's previous config/merge-gate
pane-titles/uninstall.sh "$FM_HOME"                      # pane-titles: restores the home's previous launch-env-hook
rm "$FM_HOME/config/parked-homes"                        # parked-homes: a missing file parks nothing
systemctl --user disable --now fm-glm-queue && rm -r ~/.local/share/fm-glm-queue ~/.config/systemd/user/fm-glm-queue.service   # glm-queue
rm -r ~/.local/share/fm-route-change ~/.local/bin/route-change                  # route-change
rm -r ~/.local/share/fm-host-memory ~/.local/share/fm-fleet-flow                # host-memory, fleet-flow
rm -r ~/.local/share/fm-git-identity                     # git-identity: also restore the backed-up "$FM_HOME/config/launch-env-hook"
"$FM_HOME/bin/fm-check-unregister.sh" delete-guard      # delete-guard: then rm -r ~/.local/share/fm-delete-guard and drop its hook entries (its .bak files show what it added)
rm ~/.pi/agent/extensions/fm-literal-delete.ts           # pipeline-literal-delete: also drop its Claude SessionStart hook entry
systemctl disable --now tailscale-resilience.timer       # tailscale-resilience: then remove its unit files
```

The dormant and fork-hook add-ons install nothing from this repo — removing them means removing the fork-side hook ([FORK-EXIT.md](../FORK-EXIT.md)).

## Details

### delete-guard

No agent can recursively delete `/`, `/home`, a home folder or a folder directly in it, or a bare `.` `..` `*` or `$VAR` target, and an attempt on a real folder wakes the main firstmate.
`delete-guard/guard.mjs` holds the one rule, and each runtime adapter hands it the shell command before it runs.
A block is final: there is no allow-once, flag or environment override, and no agent, reviewer or pipeline gate can approve the delete.
The one `$VAR` exception: when `d=$(mktemp ...)` with any options or template (plain `$NAME` or `${NAME}` expansions allowed; no command substitution, backticks, `;`, `&`, `|` or parentheses), or `d=$(mktemp ... || mktemp ...)` where every `||` alternative is a mktemp call, is its own statement (optionally after `export`, `local`, `readonly`, `typeset` or `declare` with only `-r`, `-x`, `-g`; never a `-n` nameref) and the last assignment to `d` in the same command, `rm -rf -- "$d"` runs (never for `HOME` or another shell or runtime variable). A literal-path assignment takes the same prefixes.
Each block appends one JSON line (time, home, task, cwd, runtime, target, command) to `<fm-home>/state/delete-guard.log`.
The block message names the literal-path fix: delete the folder in a later command by its literal path (`rm -rf -- /tmp/tmp.Ab12`), delete a variable only when the same command sets it under the agent's own name, never a shell or runtime variable (`d=$(mktemp -d); ...; rm -rf -- "$d"`), and treat the block as final.
The `delete-guard` watcher check turns new lines into one wake on the watcher's check cadence (5 minutes by default), but only for a block whose target is a literal path, or a variable the same command set to one (`$HOME` with no assignment is the home folder), outside temp and scratch folders (`/tmp`, `/var/tmp`, `/dev/shm`, `.cache/fm-scratch`).
Every other block is counted, not woken: a `$VAR` with no literal value, a bare `.` `..` `*`, a temp or scratch target, a block from an agent working in a temp or scratch folder (a lab or probe), and a repeat the guard already woke on.
The blocks themselves are unchanged; an agent that needs a blocked delete reports blocked to its lead, and the lead escalates.
The check keeps the counts per UTC day as `<day><TAB><count>` lines in `<main-fm-home>/state/delete-guard.counted`; a daily fleet summary reads yesterday's with `awk -F'\t' -v d="$(date -u -d yesterday +%F)" '$1 == d { print $2 }' <main-fm-home>/state/delete-guard.counted`.
A second block by the same task (or, with no task, the same cwd) within 10 minutes queues an immediate `delete guard REPEAT` wake.
A heredoc body fed to a shell (`bash <<EOF`, `cat <<EOF | sh`) is checked as commands, and one fed to anything else (`python3`, `cat > file`) is data.
Only the command string is checked, so a delete inside a script file the agent runs is not seen.
Covered: Claude Code (workers, leads and the pipeline's Claude agent) by a `PreToolUse` Bash hook in `~/.claude/settings.json`, pi by `~/.pi/agent/extensions/fm-rm-guard.ts`, and OpenCode by `~/.config/opencode/plugins/fm-delete-guard.js`.
Not covered: Codex, because Firstmate launches its crewmates and scouts with `--disable hooks` and a new `~/.codex/hooks.json` entry puts a hook-trust prompt in front of every Codex launch, and cursor-agent, grok, omp, kimi and gemini, which the fleet does not dispatch.

Install or update with `delete-guard/install.sh [--dry-run] <main-fm-home>`; it is idempotent, and `--dry-run` prints the changes and writes nothing.
It backs up each file it changes as `<file>.bak-delete-guard-<epoch>`, copies the rule to `${XDG_DATA_HOME:-~/.local/share}/fm-delete-guard/`, writes the adapters, merges the Claude hook without dropping other settings, and registers the check in `<main-fm-home>`.
Test: `delete-guard/tests/delete-guard.test.sh <firstmate-checkout> [ref]` installs into a throwaway HOME against a home built from that checkout's `bin/`, then drives the installed hook through every rule case and the log, check and repeat-wake journey, then replays the retained log (`delete-guard/tests/fixtures/`) one check sweep per row and asserts the only wake is the recorded real-folder block.

### pipeline-literal-delete

Pipeline agents (the no-mistakes review, test, document and lint steps on pi and Claude) never read the worker brief, and the gate neutralizes repository AGENTS.md/CLAUDE.md, so they kept deleting a `$VAR` set in an earlier command and losing the step to a delete-guard block.
This add-on gives every pipeline agent the literal-path delete rule before it deletes, delivered once at the one place every agent in every home already reads: the runtime's own user-level instruction surface.

The rule (`pipeline-literal-delete/rule.txt`): recursive deletes (`rm -r`, `rm -rf`, `find -delete`, `rimraf`) name a literal path (`rm -rf -- /tmp/tmp.Ab12`), or keep the mktemp variable and the delete in the same command under your own variable name such as d - never TMP, TMPDIR, TEMP, HOME, PWD or another shell or runtime variable (`d=$(mktemp -d); ...; rm -rf -- "$d"`); never delete a `$VAR` set in an earlier command; a delete-guard block is final - do not retry it or reword it.

Surfaces: pi gets `~/.pi/agent/extensions/fm-literal-delete.ts`, which appends the rule to the system prompt of every pi session on `before_agent_start` (gate agents run with project context files disabled, but user extensions still load - the delete guard's own pi adapter proves it fires there).
Claude gets a `SessionStart` hook in `~/.claude/settings.json` whose `additionalContext` carries the rule into every session, gate agents included.
One install covers every firstmate home, because both surfaces live under the Unix user's home, not under any FM_HOME.

Install or update with `pipeline-literal-delete/install.sh [--dry-run]`; it is idempotent and needs no fm-home argument (no watcher is registered).
It backs up each file it changes as `<file>.bak-pipeline-literal-delete-<epoch>`, copies the rule to `${XDG_DATA_HOME:-~/.local/share}/fm-pipeline-literal-delete/`, writes the pi extension, and merges the Claude hook without dropping other settings.
It touches no `~/.no-mistakes/config.yaml` and no project `.no-mistakes.yaml`.
Test: `pipeline-literal-delete/tests/pipeline-literal-delete.test.sh` installs into a throwaway HOME/XDG copy, drives the installed pi handler and the installed hook command, and checks the idempotent rerun and the delete-guard block message's literal-path hint.

### merge-card

Every merge runs done-done and, only with passed proof, posts one evidence card to a sign-off board, with nobody posting by hand.

`merge-card/merge-card` is one bash script with three subcommands:

- `merge-card gate <task-id> <worktree|-> <head|-> <pr-url|->` runs `done-done check --from <source> --judge --json` in the task's worktree, where `<source>` is the pull request when there is one and `$FM_HOME/data/<task-id>/checks.md` otherwise.
  The Checks evidence lives in `$FM_HOME/data/<task-id>`, so each relative or bare name resolves there before done-done checks that the file exists, while absolute paths stay unchanged: `done-done check --citation-base $FM_HOME/data/<task-id>` resolves the names itself on done-done 0.3.1+, and on an older one merge-card resolves them in the Checks block and hands it to `done-done check --from -` (with the pull request's branch as `--claim-id`). A name still missing there is reported missing at its resolved path.
  The work copy only supplies the repo identity.
  It prints the verdict and saves it for the card in `$FM_HOME/data/<task-id>/merge-card.json`.
  done-done's verdict is report only, but a PR merge is refused (exit 1) when `$FM_HOME/data/checks-gate.log` has no `pass` row for the head (rows come from merge-on-green's `checks-lint.sh`).
  Hand-captured evidence legitimately comes back inconclusive and the merge still lands.
  A judge that is not configured degrades to a plain "not checked" verdict; a done-done that could not check at all names the real reason (an older done-done rejecting `--citation-base`, say) instead of a bare exit code.
  `merge-card gate`, `merge-card check` and `merge-card post` all take `--judge <route>`, which reaches `done-done check --judge <route>` for that call alone: a lane whose configured judge route is rate limited names another one instead of waiting on done-done's fallback. Without the flag nothing changes.
  `merge-card check <task-id> <worktree|-> <head|-> <pr-url|->` runs the gate's check alone: it saves and prints the verdict and posts nothing.
- `merge-card post --board <board.json> <task-id> <worktree|-> <head|-> <pr-url|->` keeps one live evidence card per PR: a post at a new head archives the earlier card (kept under Archived); only real, passed proof is posted. A screen-free card includes up to 40 lines of captured `.txt`, `.log`, `.out`, `.stdout` or `.stderr` command output in its 500-character note when available; oversized excerpts get a visible full-run pointer.
  A merge whose Checks block has a `screen: none` line (an internal fleet tool with no user-visible screen) posts a text-only card from its sealed clean run and demands no capture.
  That card carries the receipt, the Checks outcome and a bounded excerpt of the run's text output, and done-done is not run for it.
  The owner-rules gate says so in one line at the top of its output.
  A claim that cites an evidence file the sealed run does not hold is not refused whole: one line names the run's own capture, and the claim is checked against that file (or the card names it) instead.
  A claim no sealed run supports is still refused, and every refusal names the command that clears it.
  A merge posts only an evidence card: the plain outcome as the title and the passed proof on the card.
  A merge with missing or unconfirmed proof posts no card; the gap goes back to the lane owner to fix the proof and re-run the post.
  The card carries the Checks claim (what a user can now do) as the title, done-done's verdict in plain words, the pull request link (the merged commit when there is no PR), and the passed proof media (at most 12 screens or recordings), or those of a verify run at the merged head.
  It also carries the passed-test receipt as its `run`: the verify run's, else a sealed clean done-done run at the merged head in the task folder. The sign-off board files a card with a receipt under Evidence.
  The card key is the merge's own (`merge-<owner>-<repo>-pull-<n>`, or `merge-<head>` for a local merge), so a repeat post or a second home adds nothing.
  sign-off-axi writes the board under its lock and only appends.
  After each card it files, `merge-card/one-card-per-pr --apply <board.json>` archives every other live evidence card for the same PR, from any filer: the newest card carrying a passed-test receipt stays (the newest card when none has one), and nothing is deleted (`sign-off-axi restore <key>` brings one back). Run it without `--apply` for a dry run that prints one `archive` line per card.
  Feedback trail: for a PR, each card the task's `$FM_HOME/data/<task-id>/brief.md` or the PR body names on a line `sign-off cards: <key>[, <key>...]` is marked acted on with `sign-off-axi feedback <key> <board.json> --acted --link <pr-url>` (`--reply "<text>"` instead when a `sign-off reply: <text>` line gives the outcome), once per card and PR, whether or not an evidence card posts. NOT_FOUND (nothing sent on the card yet) counts as done, a sign-off-axi older than 0.6.1 skips with one line, and any other failure is printed and retried on the next post.

In a home with a worker account pool (`config/account-pool`), the judge is a claude caller, so the check runs it on the account the pool picks: that account's profile folder goes into `CLAUDE_CONFIG_DIR` and the login variables the pool sheds are unset for the call, so the judge never answers on the default login. The line says which account ran. A failed pool read uses the last good pick with its age; without a usable pick the judge is not started: a proof check never refuses a merge over the pool.

`merge-card` needs `done-done` on `PATH` (0.3.1+ resolves the block's relative evidence names itself; on an older one merge-card resolves them first), plus `sign-off-axi`, `jq` and `gh`.

Install into one home, so the post-merge hook calls `post` once for each recorded merge:

```sh
printf '#!/bin/sh\nexec <addons>/merge-card/merge-card gate "$@"\n' > $FM_HOME/config/merge-gate
printf '#!/bin/sh\nexec <addons>/merge-card/merge-card post --board <board.json> "$@"\n' > $FM_HOME/config/post-merge
chmod +x $FM_HOME/config/merge-gate $FM_HOME/config/post-merge
```

With `owner-guard` installed, rerun `owner-guard/install.sh "$FM_HOME"` after rewriting the gate shim, so the owner-details merge scan is chained back in front of it (see [owner-guard](../owner-guard/README.md)).

Test: `merge-card/tests/merge-card-e2e.sh` drives the real script end to end against a task folder holding a retained PNG, with a stub `done-done` placed earlier on `PATH` (one accepting `--citation-base`, one rejecting it, and one that lies about supporting it), and asserts the recorded verdict, the invocation the stub saw, and that the card's media resolves in each case.

### quota-failover

Workers and leads stopped by a provider usage limit or a provider 429/5xx move to the next live route on their own, and the dead route stays out of new dispatch until it answers again.

`quota-failover/quota-failover <fm-home>` is one bash script that makes one pass over the home's workers and leads under a lock, so any cadence can run it.
A worker or lead counts as stopped by a limit when all of these hold:

- its status says working, or it has no status yet;
- it has written no status, turn end or progress for `QUOTA_FAILOVER_STALL_SECS` (default 240), and it was not spawned or relaunched inside that window;
- it is not busy, where a harness that is only retrying a provider error counts as not busy;
- one of: its visible screen shows a provider limit error; `quota-axi` reads its route's provider as exhausted now; its pinned route is already out of dispatch; or a one-line test of its pinned route answers a provider limit or 429/5xx error (that probe runs at most once per `QUOTA_FAILOVER_PROBE_SECS`, default 900, per task).

A busy worker that is making progress is never touched.
A stopped task gets the routes of the `config/crew-dispatch.json` rules that hold its current route, then the default list, in order.
Routes that are out of dispatch or whose provider reads exhausted are passed over, and the first other route that answers a one-prompt live test (`QUOTA_FAILOVER_TEST_SECS`, default 90) wins.
The task is relaunched there with `bin/fm-control.sh <task> relaunch`, with a note naming the old route, the new route and why.
A route that sits only in rules whose models all contain `opus` moves only to another such model; with none live, the task is left waiting and the reason is logged.
A remote task is detected and logged, never switched.
A route whose screen shows a limit, or that answers its pinned one-line test with a limit or 429/5xx error, is out until it answers that test again: its profile objects are dropped from `config/crew-dispatch.json` (a rule left with no profiles goes with them; the schema never changes) into `state/quota-failover-dead.json`, so a new dispatch cannot rank it, and every pass re-tests it after `QUOTA_FAILOVER_RETEST_SECS` (default 1800) to put the profiles back at the end of their list when it answers.
The filter reads the dispatch file on disk, so hand edits survive while a route is out, but a dropped profile cannot be re-added by hand until it answers again.
A stopped task on a pool account (`account=` in its meta that the pool command in a usable `config/account-pool` names as its own) hit that account's limit, not its route's, so its route stays in dispatch (a route-scoped verdict, its pinned probe, still takes it out as above). An account the pool does not name, such as the `ambient` id a Claude pool gives a Codex or Pi launch, has nothing to move or rest, so that task takes the route move:

- When the task's tool may change accounts automatically (the list below), it runs `bin/fm-control.sh <task> relaunch --account next` (which rests the account) with a note naming the old account and why. No human, no switch to write. Only when that fails, for example with no next account ready, does the route move above run.
- `$FM_HOME/config/account-pool-autorelaunch-off` (content ignored) puts the human back in the loop for that home.
- With the opt-out written, or with a tool that may not move accounts automatically, the account only rests, through the pool's own rest, and one line naming the task, the account and the manual `bin/fm-control.sh <task> relaunch --account ...` command goes to the log and to `state/quota-failover.wake`, which the watcher check prints as a wake. The rest and the wake happen once per stop.
- Which account's limit stopped it is read on that account's own profile folder, the folder the pool command names for the account in the task's meta, with the login variables a pool launch sheds also shed: the ambient login answers for a different account than the one the worker is on. A Claude pool task stopped by that reading moves to the next account; the verdict never takes its route out of dispatch, because a full account is not a dead route.

The tools that may change accounts automatically are fixed in code, not config: Claude Code, Cursor and Pi subscription logins. OpenCode's Go tier never does (its terms ban several accounts used to get around limits; switch it by hand). Codex and Pi on an OpenAI login (`openai-codex/`, `codex-native/`) stay rest + wake: OpenAI's consumer terms (effective 1 Jan 2026) bar using the service to "circumvent any rate limits or restrictions".
Every decision is one line in `state/quota-failover.log`.
A worker left with no live route also gets one failed line on the home's parent channel; nothing else is sent there.

It needs `quota-axi`, `jq`, `flock` and the harness command of each dispatch route on `PATH`.

`quota-failover/install.sh [--dry-run] [--all] [--list] <fm-home>` copies the watcher (with the parked-homes reader and the account-pool Claude environment it sources beside it) to `~/.local/share/fm-quota-failover`, points the home's `state/quota-failover-watch.check.sh` at it through an exec shim (a different check there is backed up first) and registers it. `--all` does the same for every active home: the given home and each local secondmate home its `data/secondmates.md` lists, minus the ones `config/parked-homes` parks; a remote home is skipped and named, and a home that cannot register fails the run. `--list` prints the homes it would reach. `quota-failover/uninstall.sh [--all] <fm-home>` retires the check from the same homes.
`QUOTA_FAILOVER_MAX_AGE` (default `10m`) is the oldest quota reading it trusts.

Test: `quota-failover/tests/quota-failover-e2e.sh` drives the real script end to end against a fixture home (stub firstmate libs in its `bin/`, stub `quota-axi` and `opencode` on `PATH`): a lead on a route that answers every one-line test with a provider 429, and a screen-stopped worker on a second dead route ranked first in the dispatch rules. It asserts both move to the live candidate, the dead routes are passed over and dropped from `crew-dispatch.json`, and a second pass with the routes answering again restores them and moves nothing. Five more passes add pool workers: with the switch file present a Claude worker moves to the next account with no route move, a Claude worker with no next account takes the route move, and OpenCode's Go-tier and Codex workers only rest and wake; with the file gone a Claude worker only rests and wakes, once across two passes and again when the same account stops a new incarnation, and a pool rest that fails still wakes the home, once; a pool worker wedged with a clean screen loses its route to the pinned probe's verdict, and the stop's changed label re-fires nothing.

Install into one home as a watcher check, so it runs on the watcher's own cadence; `check.sh` prints any pending wake line and starts the pass detached (an install with the older `setsid -f .../quota-failover` line keeps working but never wakes, so re-run this):

```sh
printf '<addons>/quota-failover/check.sh %s\n' "$FM_HOME" > $FM_HOME/state/quota-failover-watch.check.sh && chmod 700 $FM_HOME/state/quota-failover-watch.check.sh && $FM_HOME/bin/fm-check-register.sh quota-failover-watch
```

Remove it with `$FM_HOME/bin/fm-check-unregister.sh quota-failover-watch`.

### pipeline-quota-failover

The no-mistakes pipeline agent moves to the next allowed model the moment a provider answers a quota error, instead of retrying the same model 4 times and failing the run (speed-report row Q1: about 1,650 pipeline minutes a day).

`pipeline-quota-failover/pi-quota-failover` is one bash wrapper installed as the pipeline's `pi` through `agent_path_override.pi`. It runs the real `pi`; when an attempt answers a quota error (pi reports provider errors inside its JSON stream and still exits 0, and no-mistakes' terminal list covers only seven exact quota phrasings, so real limit errors are retried up to 4 times on the same model), the wrapper starts the next model in the chain inside the same invocation: the chain is one route, `claude-bridge/claude-haiku-5-5` (Claude Haiku on the subscription accounts), so a call pinned to a model outside the chain runs that route and the pinned model never runs, and it is never Codex, Go, Muse, Opus, Sonnet, Fable or Step 5. With an account pool each bridge call runs on the pool's Claude pick, and a Claude limit rests that account and runs the same route on the next one; with every account resting nothing runs (see the add-on README). An `openrouter/*` route takes the deepseek idle limit (300 s, `PI_QUOTA_FAILOVER_DEEPSEEK_IDLE_SECS`), not the generic 120 s one, so a slow answer on the floor route is not killed; the list is read at call time, see the README. The requested model goes first when it is in the chain and its skip window does not hold it out, then the other chain models in chain order; a model pinned outside the chain does not run, and the chain runs in chain order instead. Before each route `quota-axi` can skip it as exhausted now, and a call silent for 120 s is killed and counts as a stall, not a quota failure; the details are in `pipeline-quota-failover/README.md`. A non-quota failure passes through byte-for-byte with its original exit code; a quota-limit error on any chain route counts as a quota error. A resumed `--session` is dropped on the failover attempt (fresh-session retry, the pipeline's own semantics after a provider switch). A quota error also leaves a marker (the model and the time) in `~/.local/state/pi-quota-failover-dead/`, and later calls skip that model for `PI_QUOTA_FAILOVER_DEAD_SECS` (default 3600) instead of waiting out pi's own retries on it again (13-16 min per call on a dead GLM); after the window the model is tried again, and an answer without a quota error clears its marker. When every chain model is quota-dead the wrapper fails once with a line containing "quota exhausted", which no-mistakes classifies as terminal, so the dead chain is never re-retried. Calls pinned to a model outside the chain (for example `axi run --model`) no longer pass through to that model: the chain runs instead, so a pinned call cannot bypass the failover. Each decision is one timed line in `~/.local/state/pi-quota-failover.log` and on the step's stderr.
Because every pipeline model call passes through this wrapper, it is also where the host-memory gate sits (speed-report row B3: model calls under heavy host load crash): before each call it runs `~/firstmate/config/fm-mem-gate.sh` with no command, which only waits until the host has room, for at most `PI_QUOTA_FAILOVER_GATE_SECS` (default 600) before pi starts anyway, with pi keeping its normal priority and no memory cap (`PI_QUOTA_FAILOVER_GATE` names another gate, empty disables it).

The OpenRouter key that route needs lives only in the systemd user manager environment (imported with `systemctl --user import-environment`, never copied into a file). It survives a daemon restart but not a reboot or a manager restart: after either, re-import it from `~/.config/openrouter/api_key` before starting the daemon. Never print the key and never copy it into a file.

Neither installed v1.79 nor current v1.84 can express this in config: `agent:` fallback is per agent and fires only on process-unavailable errors (`pi reported error:` matches none of its needles), and `agent_config.<agent>.model` is a single string, so one agent cannot carry a model chain. The daemon re-reads the config per run, so wiring needs no daemon restart.

Install or remove with `pipeline-quota-failover/install.sh [--dry-run] [--restore]`; it copies the wrapper to `~/.local/share/fm-pipeline-quota-failover/`, makes one key-level edit to `~/.no-mistakes/config.yaml` (timestamped backup next to it, key name only in output, no config contents printed), and is idempotent.
Test: `pipeline-quota-failover/tests/pi-quota-failover-e2e.sh` drives the real wrapper against a stub pi in a throwaway HOME with the exact argv shape no-mistakes builds (quota-dead GLM route using the fleet's real 429 usage-limit surface, a GPT-6 Luna route that is healthy or answers a codex usage-limit surface): one attempt per model, the winning stream on stdout, timed log lines, non-quota passthrough, off-chain pins running the chain, session drop on failover, chain exhaustion exiting 1 with the terminal line, quota-dead markers (written on a quota error, the model skipped while fresh with no pi call when every model is, tried again once expired, cleared by an answer), the quota-axi pre-check, the idle watchdog, and the install edit's add, idempotence, restore and backup. It also checks the extension argv (`-ne`, the guard extensions loaded, no pi-hermes-memory, a settings built-in turned off, an unreadable pi list falling back with one log line). `pipeline-quota-failover/tests/pi-quota-failover-route.test.sh` pins the pipeline route: the default chain is Claude Haiku through claude-bridge, a call pinned outside the chain lands on it and never on the pinned model, an `openrouter/*` route is killed by the deepseek idle limit and not by the generic one, and with a stub pool a limit on one account answers on the next, a refused rest writes no route marker, and with every account resting nothing runs on the default login.

### route-change

One command moves worker dispatch, the no-mistakes gate and the lead pins to one route together, so no route is edited by hand.

`route-change/route-change [--dry-run] <fm-home> <route>` takes a route from the pipeline-quota-failover chain, the fleet's one route list, which it reads from the wrapper the gate runs (`agent_path_override.pi`).
Every route runs on pi, with the provider `pi --list-models` names for it.
It refuses a route whose provider quota-axi reads exhausted now, naming the scope and window, and a route quota-failover holds out of dispatch; nothing is written then.
Otherwise it backs up each file it changes as `<file>.bak-route-change-<stamp>` and writes all of them:

- `config/crew-dispatch.json`: in the default and every rule, the route leads the non-Claude profiles; Claude and Opus entries keep their place and an Opus-only rule is left alone.
  A list that already holds the route, as `<route>` or `<provider>/<route>` on any harness, moves that entry; any other list gets a pi profile for it.
- the gate: `agent` and `agent_config.pi.model` in `~/.no-mistakes/config.yaml` (or `$NM_CONFIG`), edited by key name and checked so no other key changes; only route names are printed.
- the lead pins `config/secondmate-harness` and `config/secondmates/*/harness`, except pins on Claude or Opus.

Then it sends one real request through pi on the route, the way the gate calls it; when that fails it restores every backup and prints the cause.
`--dry-run` runs the quota check, prints the planned edits and writes nothing.
Each switch is one line in `<fm-home>/state/route-change.log`, and it holds quota-failover's lock while it works.
Secondmate homes get the new `crew-dispatch.json` through firstmate's config inheritance.

Install with `route-change/install.sh [--dry-run]` after `pipeline-quota-failover/install.sh` from the same checkout (the route list needs the wrapper's `PI_QUOTA_FAILOVER_PRINT_CHAIN`).
Test: `route-change/tests/route-change-e2e.sh` runs the real script and the real wrapper against a fixture home and config with stub quota-axi and pi: an exhausted route is refused with nothing written, a good route moves every pin and keeps backups, and a failed real request restores every file.

### ask-default

An unanswered ask gets a safe, pre-declared default instead of blocking the home, and work continues.

`ask-default/ask-default` is one bash script with four subcommands:

- `ask-default open <ask-id> --wait-until <YYYY-MM-DDTHH:MM:SSZ> | --wait <seconds> --default-cmd <command> --safety <class> --reason <one line>` records one ask in `$FM_HOME/data/ask-default/asks/<ask-id>`: its wait clock, the pre-declared default action, that action's safety class, and the reason.
  A class of `safe` means the default action is reversible and touches no destructive, irreversible, money, credential, or merge action, and it must name the command that performs it; any other class (`destructive`, `irreversible`, `money`, `credential`, `merge`) or `none` declares that no safe default exists and the ask must stay held.
  Re-opening refreshes the wait clock; a defaulted ask is settled and never re-opens under the same id.
- `ask-default decide <ask-id> [--probe-cmd <command>] [--timeout <seconds>]` probes the operator once under a hard timeout and decides what the home does about the ask.
  The probe command exits 0 for reachable; anything else, including the timeout, resolves to unreachable inside the bound, so a hanging endpoint never wedges the caller.
  Its command comes from `--probe-cmd` or `$ASK_DEFAULT_PROBE` and its timeout from `--timeout`, `$ASK_DEFAULT_TIMEOUT`, or 5 seconds; with no probe configured it refuses rather than assume the operator is unreachable.
  Exit codes: `0` defaulted (or already-defaulted), so the caller may continue unrelated work, `10` held (the clock expired but no safe default exists), `11` waiting (the clock has not expired), `12` reachable (the ask stays open for the real answer), `1` error on stderr.
  A defaulted ask runs its default action exactly once, under a per-ask lock, and appends `{ask, applied_at, default_cmd, reason, rc}` to the append-only `$FM_HOME/data/ask-default/applied.log`.
- `ask-default probe <command> [--timeout <seconds>]` runs one bounded reachability probe on its own: exit 0 reachable, 1 unreachable.
- `ask-default show <ask-id>` prints the ask record.

`ask-default` needs `bash`, `jq`, `flock`, and GNU coreutils (`timeout`, `date -d`) on `PATH`, plus `FM_HOME` set.

The add-on decides; it does not wire itself in. A home discovers open asks and calls `decide` per ask from its own supervision loop, which is a thin hook in the firstmate fork, not in this repo.

### tailscale-resilience

One host watchdog for the two failures that quietly take a lane offline: the Tailscale network going unreachable while `tailscaled` still runs, and a display/session dying while logind still lists it.

`tailscale-resilience/tailscale-resilience` is one bash script with one subcommand:

- `tailscale-resilience check [--samples N] [--window S] [--cooldown S] [--state-dir DIR]` reads both detectors from the real CLI, advances their bounded sample windows in the state dir, and on the first window that holds a failure for the whole window it heals, alerts and records.
  - `net` uses `tailscale status --json` (BackendState, peer Online flags) and `tailscale netcheck --format json` (RegionLatency): the network is unreachable when the daemon answers but nothing else does - the status call fails, `BackendState` is not `Running`, or no DERP relay and no peer is reachable.
  - `display` uses `loginctl list-sessions` and `show-session`: a session logind still lists is dead when it is closing, its leader PID is gone from `/proc`, or a graphical session has no display socket left for its user.
  - A window needs `--samples` (3) consecutive failing samples inside `--window` (600) seconds, so one transient failure never heals and never alerts.
  - The heal is one `tailscale up` per detected outage and never twice inside `--cooldown` (300) seconds.
  - It reattaches the connection and changes nothing else, so a dead `tailscaled` or a `NeedsLogin` node is recorded with the real cause instead of being papered over.
  - Alerting never uses Tailscale: `$STATE_DIR/alerts.log` always works, and `TSR_ALERT_CMD` adds a local channel - a LAN webhook, `notify-send`, an SMS gateway - run with the alert text on stdin and as `$1`.
  - Every detection, heal and alert is appended to `$STATE_DIR/events.jsonl`, one JSON line each, naming what was detected, when, and the heal result.

It needs `bash`, `jq`, `tailscale` and `loginctl` on `PATH`, and one instance owns the state dir.

Install it as a timer so the windows are fed at the fleet's scan cadence (60s matches a Firstmate scan):

```sh
printf '%s\n' '[Unit]' 'Description=Tailscale and display resilience check' \
  '[Service]' 'Type=oneshot' 'ExecStart=<addons>/tailscale-resilience/tailscale-resilience check' \
  'Environment=TSR_ALERT_CMD=<a local push channel, never a tailnet address>' \
  'EnvironmentFile=-/etc/default/tailscale-resilience' > /etc/systemd/system/tailscale-resilience.service
printf '%s\n' '[Unit]' 'Description=Run the resilience check' \
  '[Timer]' 'OnCalendar=minutely' 'Persistent=true' \
  '[Install]' 'WantedBy=timers.target' > /etc/systemd/system/tailscale-resilience.timer
systemctl enable --now tailscale-resilience.timer
```

The state defaults to `${XDG_STATE_HOME:-$HOME/.local/state}/tailscale-resilience`, so a timer runs it as one user and that user owns the record.
`TSR_SAMPLES`, `TSR_WINDOW`, `TSR_COOLDOWN` and `TSR_STATE_DIR` set the same knobs as the flags.

The dead-display case is detected, recorded and alerted but not healed; a heal for it is a later slice.

### claude-model-guard

Claude Code never starts Fable; Sonnet is allowed (the captain lifted the Sonnet ban on 2026-10-19).
`claude-model-guard/install.sh [--dry-run] [--restore] [--config-dir <dir>]` edits `<dir>/settings.json` (default `${CLAUDE_CONFIG_DIR:-~/.claude}`) at key level, with a timestamped backup, so every Fable form ends on Haiku or is refused, never on another model: `env.ANTHROPIC_DEFAULT_FABLE_MODEL` = `claude-haiku-5-5`, so the `fable` alias (a `--model fable` launch, an agent's `model: fable`) runs on Haiku (a reinstall deletes the old `env.ANTHROPIC_DEFAULT_SONNET_MODEL` mapping to Haiku, so the `sonnet` and `opusplan` aliases run on Sonnet again); and a `UserPromptSubmit` hook plus a `PreToolUse` hook for `Agent|Task` running `refuse-model.sh` (copied to `${XDG_DATA_HOME:-~/.local/share}/fm-claude-model-guard`), which refuses the prompt or the subagent call before any request is sent when a full Fable id such as `claude-fable-5-1` comes from `--model`, `ANTHROPIC_MODEL`, a settings `model` key or an Agent call. It prints only its own keys and never reads or touches credentials; `--restore` removes exactly its keys and hook entries.
Claude Code itself cannot refuse a full id from user settings: `availableModels` and the managed-only `deniedModels` both fall back to the default model (Opus), and `modelOverrides` does not remap first-party ids. Not covered: a launch with `--setting-sources` that leaves out `user` (the `fm-live-lab.sh` primary uses `project,local`) loads no user settings, so neither the mapping nor the hook applies there; a session with its own `CLAUDE_CONFIG_DIR` needs the installer run with `--config-dir` for that dir. The hook fails open if it cannot run.

Test: `claude-model-guard/tests/claude-model-guard-e2e.sh` installs into a throwaway HOME with no credential and drives the real `claude` binary: each `--model` (the sonnet and fable aliases, full Sonnet and Fable ids, `--model=`, `ANTHROPIC_MODEL`, a settings `model`, opus, haiku, none) is checked against the model Claude Code dispatches to, or the hook refusal, in its debug log, so no API call is made and a refused model can never run; the Agent-call check feeds the hook a tool input; plus key-only output, other settings kept, idempotence, backup, upgrade of an old install that mapped the sonnet alias to Haiku, and restore.

### merge-on-green

A yolo task's PR merges itself once the required checks are green, instead of waiting for the lead to notice and merge (about 21 minutes per change).

`merge-on-green/merge-on-green.sh check <fm-home>` is the watcher check. For each `state/<task>.meta` with `yolo=on` and a recorded `pr=` and `pr_head=` whose resolved state (`bin/fm-crew-state.sh`) says checks green / PR ready, it skips silently when the meta says `merge=manual` or the evidence gate (`checks-lint.sh`, pinned to done-done-axi 0.6.4 with Firstmate's size rules, falling back to the legacy lint when unavailable, must print PASS) returns a not-proven PASS; otherwise it requires the run receipt to be a PASS for exactly the meta's `pr_head` and `spawn_gen`, and only then merges through `bin/fm-pr-merge.sh` — never `--auto`, never `gh merge` directly, and no refusal is ever bypassed, so fm-pr-merge's live green check, head pin and refusal rules stay in charge. One merge attempt per task per head, remembered in `<home>/data/fm-merge-on-green/<task>.head`; refusals are remembered per task+head+reason+receipt state in `<task>.refused` and repeat silently until the head, the receipt or the reason changes; a timeout kill wakes truthfully once per task+head+reason like a refusal, records no attempt and is retried next sweep, while a `fm-crew-state` timeout stays silent. A merge prints one wake line with the verified merged URL, so the lead runs the post-merge steps (install from main, teardown), and appends the normal `done [at=<epoch>]: merged <PR URL>` line to `state/<task>.status`, so the lead relays it. Every command is bounded with `timeout` (a third of `FM_CHECK_TIMEOUT`, floor 5 s): a gate starts only before 80% of the bound and a merge only when it fits inside the whole bound, so the watcher's kill can never cut a merge.

Install with `merge-on-green/install.sh [--dry-run] <fm-home>`; it copies the watcher, pinned done-done lint adapter and config to `${XDG_DATA_HOME:-~/.local/share}/fm-merge-on-green/`, writes the `state/merge-on-green.check.sh` shim, and registers the check with `bin/fm-check-register.sh`; it is idempotent and `--dry-run` writes nothing.
Tests: `merge-on-green/tests/merge-on-green.test.sh` drives the check end to end against a fixture home with stub `fm-crew-state.sh`, `fm-pr-merge.sh` and lint, and `merge-on-green/tests/checks-lint-parity.test.sh` compares pinned done-done verdicts against the legacy verdict fixtures, covering the `merge=manual` and "not proven" skips, the merged status line, the skip and refusal cases, the per-head and per-refusal memory, the timeout contract, and `install.sh` in both `--dry-run` and real mode.

### zai-quota-check

`zai-quota-check/zai-quota-check` is a shippable version of a proven state check: it alerts you when the GLM plan it watches burns ahead of time - the 5 h window under 30% with more than 45 min to its reset, or the week's used share more than 15 points ahead of the week's elapsed share, or the week under 20% - with the message naming the route moves that keep the pipeline's share. It reads `quota-axi --json` at most once per 10 min (the check cadence bounds it further) and repeats only when its repeat signature changes: on a 10% step of the 5 h window only while the 5 h condition holds, otherwise on a 10% step of the week alone. The fix over the state copy it shipped from: its `fp//10|wp//10` signature carried the 5 h step on every week-ahead wake and so woke about 10 times per 5 h window while the week-ahead condition stayed true all week. `$0 <quota-json-file>` is the test mode: it reads the file instead of `quota-axi`, and `ZAI_QUOTA_MARK` then names the repeat-state file (default a fresh temp file), so a fixture sequence can exercise the repeat logic with no live quota read.

Install with `zai-quota-check/install.sh [--dry-run]` and `FM_HOME` set: it copies the check to `$FM_HOME/state/zai-quota.check.sh` (mode 700) and registers the zai-quota check with the home's `bin/fm-check-register.sh`; idempotent. Out of the box the live repeat state lives at `~/firstmate/state/.zai-quota.last`, the same file the state copy used, so the install replaces it in place with no re-wake.

Test: `zai-quota-check/tests/zai-quota-check-e2e.sh` drives the real check in the file-argument mode over fixture sequences: with the week-ahead condition true all week and the 5 h window above 30%, fp 90->80->...->40 wakes once (the old signature woke on every run); with the 5 h condition each 10% step wakes once (29, 19, 9); a week 50->40->30 step wakes once per step.

### claude-quota

`claude-quota/claude-quota.check.sh` alerts you when the Claude account pool as a whole burns ahead of time.
It reads every pool account from the `claude-accounts` reader's `state/claude-accounts.json`, so one low account is no alarm: new lanes and relaunches move to another account.
For each window (5 h, week) it adds up the accounts' percent left, takes the pool's burn rate over the last 1-5 h of its own history (counted from after the last reset), and wakes when that sum runs out before the soonest reset among the accounts, again on each 10% step of the pool's mean left.
The wake names each account's share, the burn and the account that resets first, with the action: new lanes pick the pool account with the most runway; relaunch --account next on a limit; never usage credits.
A reading file that is missing, older than 30 min, or with any account unread prints a diagnostic on stderr and gives no verdict, so it never wakes falsely; the watcher drops stderr, so run the check by hand to see it.
It reads at most once per 10 min.
`$0 <claude-accounts-json-file>` is the test mode: it reads the file, and `CQ_MARK` and `CQ_HIST` name the repeat-state and history files (default fresh temp files).

Install with `claude-quota/install.sh [--dry-run] <main-fm-home>`: it copies the check to `${XDG_DATA_HOME:-~/.local/share}/fm-claude-quota/`, backs up a replaced `state/claude-quota.check.sh` as `<file>.bak-claude-quota-<epoch>`, writes that path as an exec shim (mode 700), and re-registers the `claude-quota` check with `bin/fm-check-register.sh`; idempotent.
The live repeat state stays at `~/firstmate/state/.claude-quota.last`, the file the state copy used.

Test: `claude-quota/tests/claude-quota.test.sh` drives the real check over sample pool readings: one account low and the others fine gives no wake; all accounts together short of the soonest reset give one wake with the action text and no other route, the same step stays quiet and the next step wakes again; an account with no reading, an hour-old file or no file gives a stderr diagnostic and no wake; live mode reads the home's file and holds a second read inside 10 min.
It then drives `install.sh` against a throwaway home, as `--dry-run` and as a real install and rerun.

### fleet-stall

`fleet-stall/fleet-stall-check` is a shippable version of a proven state check: it alerts at most every 45 min when a home lead is idle while it has 0 busy lanes and ready work, or while live workers have sat more than 45 min in a `paused:` that waits on the lead; the missed-wake guard, fleet-pause marker, zero-busy guard, live-lane filter and `slot` exclusion are unchanged. Fix over the state copy: the paused-reason word list is matched against the reason text only, with absolute paths, URLs, `key=value` tokens (`evidence=...`) and `[at=...]`/`[key=...]` stamps removed first. Before it, a treehouse evidence path matched `firstmate`, so workers waiting on their own CI or emulator runs counted as waiting on the lead. `FM_STALL_ROOT` (the main home) and `FM_STALL_BASE` (the leads' homes) default to the live paths and exist for the fixture test.

Install with `fleet-stall/install.sh [--dry-run]` and `FM_HOME` set: it copies the check to `${XDG_DATA_HOME:-~/.local/share}/fm-fleet-stall/fleet-stall-check`, writes `$FM_HOME/state/fleet-stall.check.sh` as a shim that execs it (mode 700; a different old file is kept as `.bak-fleet-stall-<epoch>`) and registers the fleet-stall check with the home's `bin/fm-check-register.sh`; idempotent.

Test: `fleet-stall/tests/fleet-stall-e2e.sh` runs the real check against a fixture fleet (the main home's lead records, two fixture homes, a stub herdr showing both leads idle): the false-stall lines no longer count, while `waiting on firstmate for the decision` and `awaiting main instruction` still do. `FLEET_STALL_BIN` runs another copy against the same fixture.

### glm-queue

Every pi GLM call waits in one local line instead of drawing the provider's "Rate limit reached for requests" refusal and backing off.
`glm-queue/glm-queue.mjs` is a Node proxy on `127.0.0.1` (port `GLM_QUEUE_PORT`, default 8787) that forwards to `https://api.z.ai` (`GLM_QUEUE_UPSTREAM`) with at most `GLM_QUEUE_MAX` calls in flight (default 8) and a FIFO line for the rest.
Method, path, headers (Authorization included) and body pass through unchanged, responses and SSE streams are piped back as they arrive, and a caller that leaves while waiting hands its slot on unused. An upstream request that goes idle is cut after 5 minutes, and an upstream that dies mid-response (a truncated body, say) cuts the client connection immediately so the caller sees the failure and re-queues instead of hanging; its slot is freed at once.
It logs only one line per call to the journal: upstream status, ms waited, ms in flight, and the in-flight and waiting counts (`journalctl --user -u fm-glm-queue`).

Install or update with `glm-queue/install.sh [--dry-run] [--max N] [--port P]`: it copies the proxy to `${XDG_DATA_HOME:-~/.local/share}/fm-glm-queue/`, writes the `fm-glm-queue` systemd user service, and restarts it only when either file changed (a restart cuts calls in flight); it is idempotent and `--dry-run` writes nothing.
pi uses the queue once `.providers.zai.baseUrl` in `~/.pi/agent/models.json` is `http://127.0.0.1:8787/api/coding/paas/v4`; new pi sessions pick it up, running ones keep the direct URL.
Test: `glm-queue/tests/glm-queue.test.sh` runs the proxy against a stub upstream: 20 parallel clients through N=4 all complete unchanged while the upstream never sees more than 4 at once, a streamed response reaches the client before it ends, and a truncated Content-Length response fails the client in milliseconds with its slot freed for the next call.

### git-identity

No task can commit or push as anyone but the configured identity, even when its project clone's shared `.git/config` carries a stray `[user]`.
Why: a worker's `git config user.email t@e.c` in its pooled worktree leaks to every later task on that clone, because pooled worktrees share the clone's `.git/config`.
`git-identity/git-identity env-file <out>` runs in the lane pane through the home's `config/launch-env-hook` (a thin hook in the fork's `bin/fm-spawn.sh`) and exports two `includeIf.gitdir` entries through `GIT_CONFIG_*`, scoped to the lane worktree's clone (its common dir and every linked worktree under it), that include `identity.gitconfig`: the configured `user.name`/`user.email` and `core.hooksPath` = the add-on's `hooks/`.
Command-scope config beats the clone's `.git/config`, so a stray repo-local `[user]` cannot reach lane commits, in every engine the pane runs (claude, pi, opencode and the rest inherit the environment); `git -c user.email=...`, `GIT_AUTHOR_*` and repositories outside the clone (test fixtures) keep their own identity.
Its `pre-push` refuses any pushed commit not already on a remote whose author or committer email is not the configured one, prints each bad commit and the fix (find and unset the stray `[user]`, then `git rebase -r --exec 'git commit --amend --no-edit --reset-author' <oldest>~1`), and refuses outright when a pushed commit cannot be inspected; a forge-made commit (committer `noreply@github.com`) passes only because it is already on a remote.
Every hook in `hooks/` then runs any add-on extensions in the installed `hooks.d/` dir (sorted, same args, pre-push with git's stdin; a non-zero exit refuses the operation) and the repository's own hook of that name (its `core.hooksPath`, else `.git/hooks`), behind the fork's AI-trailer hooks, which chain to it the same way.
The no-mistakes pipeline commits and pushes from its own repositories with the global identity, outside any lane clone, so it needs neither part.

Install or update with `git-identity/install.sh [--dry-run] [--email <email>] [--name <name>] <fm-home>`: it copies the script to `${XDG_DATA_HOME:-~/.local/share}/fm-git-identity/`, writes `identity.gitconfig` there (a configured identity is kept unless a flag replaces it; default `you <you@example.com>`) and one read-only wrapper per client hook in `hooks/`, backs up a different `<fm-home>/config/launch-env-hook` as `<file>.bak-git-identity-<epoch>` and writes it as an exec shim (mode 700); idempotent, and `--dry-run` writes nothing. It says so when the home's `fm-spawn.sh` does not run `config/launch-env-hook` yet.

Test: `git-identity/tests/git-identity.test.sh` builds a pooled-style lane (a shared clone whose `.git/config` holds `t <t@e.c>` and its own logging pre-push, a linked worktree, a bare origin carrying a forge-made squash commit), shows the leak without the add-on, then launches the lane the way `fm-spawn` runs the hook: task commits carry the configured identity, a push of a hand-made `t@e.c` commit is refused with the commit and the fix and reaches nothing, a clean push on the forge-made base passes and runs the repository's own pre-push with git's stdin, a push whose inspection fails (a `git log` error) is refused instead of let through, a fixture repository outside the clone keeps its identity and pushes freely, and `--email` changes what is pinned and allowed; it also drives `install.sh` as `--dry-run`, a real install with a backup and an idempotent rerun.
With `FM_ROOT=<firstmate checkout>` the lane also gets that checkout's AI-trailer hooks dir layered on top, as a real spawn does.
