# cmux + herdr — the two-surface operating model

**Status:** design, grilled. 2026-08-09.
**Thesis:** cmux is the *glass*, herdr is the *engine room*. Cortana lives on the glass;
every other agent lives in the engine room.

> **herdr shows you agents. cmux shows you code, files, and folders.**

---

## Decisions locked (captain, 2026-08-09)

| # | Decision | Consequence |
|---|---|---|
| D1 | **Full migration.** Crew runtime moves to herdr — driver seam, state-based watcher, tmux retired for crew. | Gated by the Phase 0 spike. |
| D2 | **Cortana runs bare in a cmux workspace.** | Already true — `TMUX` unset, `CMUX_WORKSPACE_ID` set. No work; but it exposes D7's defect. |
| D3 | **One shared herdr session** for the whole fleet. | One attach shows everything. Superseded in *shape* by D10 — the unit is a pane, not a workspace. |
| D4 | **Watcher sensor = `herdr api snapshot` poll.** | One call returns every agent's status; O(1) at any fleet width. fm-watch's loop, lock, coalescing, backoff and wake-queue survive untouched — only the sensor swaps. `events.subscribe` is a later optimization. |
| D5 | **Turn-end collapses onto `agent_status`.** | Drop the per-harness turn-end hook install on the herdr path; retires the `__TURNEND__` / `__PIEXT__` launch-template machinery. |
| D6 | **Two drivers, not one.** herdr crew-side, **cmux captain-side**. | The away-mode daemon reaches Cortana via `cmux send` + hook-session lifecycle, not tmux. |
| D7 | **Driver-parity gate suite.** | Existing behavioral tests parameterized over `FM_MUX`; both drivers satisfy identical assertions against stubbed binaries, plus 3–4 real-server e2e gates. |
| D8 | **cortana-bus gets a herdr backend.** | V1's 10 frozen gates stay valid; `who` merges `cmux tree` + `herdr api snapshot`. Sequenced after Phase 0, before the canary. |
| D9 | **Two-tier glass.** Review pane beside the conversation (one, reused, deduped by path) **+** a per-project, cwd-rooted **Review workspace**. | Routing rule: *a document* → review pane; *a place you'll navigate* → Review workspace with the files sidebar on. |
| D10 | **Fleet map: project → domain → task.** | herdr workspace = project, tab = domain, panes = tasks. cmux workspace group = project. Name path `<project>/<domain>/<task-id>`. Default domain `direct` for main-firstmate work. |
| D11 | **Secondmates live in a pinned `fleet` workspace.** | A secondmate isn't project-scoped; its crewmates still appear under the project they're actually touching, so a pane's location always names the repo it changes. |
| D12 | **Engine room = a pinned cmux workspace** running the herdr client. | Always one switch away. |
| D13 | **Layout as code.** `bin/fm-glass.sh ensure` idempotently creates / renames / groups / orders cmux workspaces from `data/projects.md`, run at bootstrap. | cmux workspace *groups* are runtime state, not config — consistency must be enforced, not declared. |
| D14 | **Auto-surface at delivery moments only** — finished investigation, work ready for review, a local branch awaiting approval, a plan or spec. Never routine progress. | **Only Cortana pushes to the glass.** A crewmate calling `cmux markdown open` would be addressing the captain directly; crewmates write files, Cortana decides what surfaces. |
| D15 | **Phase 0 delivers a gated probe**, not a throwaway: `bin/fm-herdr-probe.sh` + a frozen gate. | Its output becomes Phase 1's real-server integration test. The spike crewmate is spawned the *old* way (tmux) so the thing under test isn't bootstrapping itself. |
| D16 | **Spec before implementation.** design doc → spec with numbered gates → intake council → build. Spec phases 0–2 now; 3–7 stay design until reached. | Gates carry `spec_ref`; this document has no observables and is not a contract. The canary week will teach us things a phase-5 spec written today would get wrong. |
| D17 | **Remote/VPS lane deferred**, implication recorded: `herdr --remote` is the intended remote lane. | Nothing built in 0–7 may foreclose it. A herdr server on sbx1 puts remote crewmates in the same fleet map with the same `agent_status`. |
| D18 | **Context-watch is re-sourced from the transcript**, not ported. | herdr's hook hands over `agent_session_path`; read the transcript JSONL for real token counts and turn boundaries. Removes ctxwatch from the mux seam entirely. Its own phase; the nine gates get re-keyed to the new observable. |
| D19 | **Clutter is a defect.** Cleanliness is a continuous, code-enforced obligation — not a phase and not discipline. | Stone has severe OCD and ADHD; on-screen clutter costs real focus. `fm-glass.sh` gains a **sweep** that runs at bootstrap, after every teardown, and after every surface push: close scratch/probe workspaces, finished agent workspaces, orphaned groups, duplicate surfaces of the same path, stale terminals. Everything belongs to a folder; nothing ungrouped. Stable names and positions — no auto-reorder, no drifting auto-titles. Cleanup touches the **view only, never the disk**. This is a *gate*, not a habit: a sweep that leaves debris is a failing test. |

**The doctrinal line:** *organization ≠ monitoring.* At fifteen concurrent agents no layout
works as a monitoring surface — you'd be scanning panes again, which is the thing being
deleted. The layout is for **navigating**; attention is **pushed** (notification + status
badge on blocked/done). If you ever sweep the engine room to find what needs you, the
design failed.

---

## 1. What each thing actually is

### cmux — the bridge
Native macOS terminal **application** (Ghostty core), window → workspace → pane → surface,
with a socket CLI and workspace *groups*.

| Capability | Command |
|---|---|
| Rendered markdown, **live-reload** | `cmux markdown open <path>` |
| Real diff viewer (split/unified) | `cmux diff --source branch --base <ref> --cwd <dir>` |
| Right sidebar: files / find / vault / sessions / feed / dock | `cmux right-sidebar files` |
| Workspace grouping + ordering | `new-workspace --group`, `reorder-workspaces` |
| Status badges, progress, todo, log — per workspace | `set-status`, `set-progress`, `todo` |
| Notifications / Feed | `cmux notify`, `cmux feed tui` |
| Browser panes with full CDP automation | `cmux browser ...` |
| Custom vibe-coded sidebars (beta) | `~/.config/cmux/sidebars/*.swift` |

cmux is the only surface in the stack that renders **documents**.

### herdr — the engine room
Rust **terminal workspace manager**, headless server + attachable client, session →
workspace → tab → pane. 0.8.0, launchd login service, prefix `ctrl+g`.

Categorically different from tmux: **it is agent-aware.** Every pane carries an
`agent_status` — `unknown | working | idle | blocked | done` — aggregating pane → tab →
workspace.

**Where that status actually comes from (verified, and narrower than it first looks).** The
installed Claude hook (`~/.claude/hooks/herdr-agent-state.sh`, v7) handles only the
`session` action and reports exactly one thing: `pane.report_agent_session` — the session id
and **`agent_session_path`**. It does *not* report working/idle. So `agent_status` for
Claude comes from herdr's **agent detection manifests**: centrally maintained terminal
pattern-matching, background-refreshed (`manifest_check`, `server.agent_manifests`,
`herdr agent explain`).

So this is still pattern-matching, and it can be wrong the same way firstmate's regexes can.
The win is narrower than "state instead of pixels": herdr maintains those patterns for 16
harnesses upstream and refreshes them, instead of firstmate owning `FM_BUSY_REGEX` and a
dim-ANSI ghost-text stripper.

The *larger* win is the one that hook does deliver: **`agent_session_path` is the transcript
JSONL**. Turn boundaries, token counts and context usage become readable ground truth — see
D18.

| Capability | Command |
|---|---|
| Block until an agent changes state | `herdr agent wait <t> --until idle,blocked,done` |
| Submit a prompt, wait for readiness | `herdr agent prompt <t> "<text>" --wait` |
| Launch an agent in a pane | `herdr agent start <n> --kind claude --pane <id>` |
| Whole-fleet state in one call | `herdr api snapshot` |
| Remote fleet over SSH | `herdr --remote <target>` |

**Verified during recon:**
- `herdr workspace create --no-focus` works with **no client attached** — panes are
  server-side; attaching is opt-in spectating.
- Workspace ids and labels **survive a full server restart** (created `w3`, restarted via
  `brew services`, came back intact).
- The socket exposes **149 methods** including `events.subscribe` / `events.wait` and a
  `pane_agent_status_changed` push event — not exposed as a CLI verb, but present.
- herdr **ships integrations for 16 agent kinds**; `pi` and `opencode` are available and
  merely uninstalled. Two commands, no code.

---

## 2. Why this is worth doing (bigger than visibility)

firstmate's supervision today is **screen-scraping tmux**. `bin/fm-tmux-lib.sh` is 192
lines whose own header documents two incidents:

- *afk-invx-i5* — the composer-empty detector only recognized a bare `> ` prompt. Claude
  draws its input box with box-drawing borders, so **every idle pane read as "pending
  input" and away-mode deferred 100% of escalations for 9.5 hours.**
- *composer-robust* — Claude renders predicted text dim; indistinguishable from typed input
  in a plain capture. The reader now captures the cursor row *with ANSI styling* and strips
  SGR-2 runs to decide whether a human typed something.

That class of bug exists because firstmate maintains its own detection against raw pixels.
herdr moves that burden upstream — `agent wait --until blocked` replaces a hand-rolled regex
over box-drawing characters with a manifest someone else keeps current across 16 harnesses.
And for the signals that matter most, the transcript replaces inference entirely (D18).

The same class ate the cortana-bus build: postmaster TOCTOU delivering mid-turn,
retry-on-unconfirmed-landing, unbatched double-delivery. All artifacts of blind pty
injection. `agent prompt --wait` deletes it.

---

## 3. Two live defects found while grilling

1. **Away-mode cannot reach Cortana.** `fm-supervise-daemon.sh` discovers its target from
   `$TMUX_PANE`, falling back to `FM_SUPERVISOR_TARGET_DEFAULT="firstmate:0"`. With Cortana
   bare in cmux, `TMUX` is unset, so escalations aim at a **crewmate's** window. There are
   zero `cmux` references anywhere in `bin/`. Fixed by D6.
2. **The crew is invisible by construction.** Because `TMUX` is unset, `fm-spawn.sh:352-356`
   takes its "not inside tmux" branch and parks every crewmate in a **detached `firstmate`
   tmux session** — currently 8 windows you cannot see without attaching. This is precisely
   the gap the migration closes.

Glass debris confirming D9/D13: `workspace:3 / pane:4` holds four markdown surfaces, three
of them the *same file*; `workspace:2` is an orphaned `"Group 1"`; `workspace:423` is an
`adw-builder` agent running on the glass.

---

## 4. The fleet map

```
herdr (engine room)                    cmux (glass) — every top level is a FOLDER
├── fleet                 ← D11        ▾ bridge            ← pinned first
│   └── secondmate panes               │   ├── cortana     ← the conversation
├── firstmate             ← project    │   └── engine-room ← herdr client
│   ├── direct            ← domain     ▾ firstmate         ← folder per project
│   │   └── fm-<id> panes              │   ├── Review      ← cwd-rooted, files sidebar
│   └── loops                          │   ├── specs       ← docs/specs
├── agent-fabric                       │   └── plans       ← docs/plans
│   └── bus                            ▸ agent-fabric      ← collapsed when untouched
└── leadrankr                          ▸ leadrankr
    ├── triage
    └── growth
```

Same top-level names in both tools, so one map serves both eyes.

**Use folders liberally.** Every project is a cmux workspace group, and a group you are not
working in collapses to a single row (`toggleFocusedWorkspaceGroupCollapsed` is bound by
default) — so breadth costs no screen. Nothing sits ungrouped: `bridge` holds Cortana and
the engine room, every other workspace belongs to a project folder. Within a project folder,
separate the *place* surfaces by purpose — `Review` (code and file tree), `specs`, `plans` —
rather than stacking unrelated documents into one pane. Group nesting depth beyond one level
is unverified; confirm during Phase 5 and nest by domain if it holds.

**Config that does the organizing** (all real settings):
- herdr `[ui] agent_panel_sort = "priority"` — the agents panel becomes an attention queue;
  blocked and needs-input float to the top regardless of project.
- herdr `[ui] show_agent_labels_on_pane_borders = true` — panes self-identify.
- herdr `[ui.toast] delivery` + `done` / `request` sounds — push, not scan.
- cmux `reorderOnNotification: false` — **defaults to `true`**, which reshuffles your
  workspace order whenever one notifies. This is why the current layout feels ad-hoc.
- cmux auto-titles workspaces from agent activity; evicting agents to herdr mostly ends it.

**Self-pruning roster.** Teardown closes the task's pane; a domain with no tasks closes its
tab; a project with no domains closes its workspace. The engine room only ever shows live
work.

---

## 5. Workstreams

### W1 — the mux driver seam
100 tmux references across 15 scripts; the seam is half-built (`fm-tmux-lib.sh` holds 22).
Funnel into `fm-mux-lib.sh` with drivers `tmux` / `herdr` (crew) and `cmux` (captain),
selected by `FM_MUX` per home.

Verbs: `create-window`, `send-text`, `submit`, `read-pane`, `is-busy`, `input-pending`,
`kill-window`, `list-windows`. Under herdr, `is-busy` / `input-pending` stop being regexes
and become one `agent get`.

Funnel order by coupling: `fm-supervise-daemon` (18) → `fm-context-watch` (13) →
`fm-spawn` (10) → `fm-ctx-lib` (8) → `fm-send` (7) → tail.

**treehouse stays.** herdr's `worktree.*` verbs are plain git worktrees; treehouse is a
*pooled, pre-warmed, leased* pool and teardown safety reads `treehouse status`. herdr owns
the pane; treehouse owns the worktree. Spawn becomes:
`pane run 'treehouse get'` → poll `pane get` for the `cwd` change (herdr exposes both `cwd`
and `foreground_cwd`) → `agent start --kind claude --pane <id>`.

### W2 — watcher rewrite (D4)
Swap the sensor, keep the loop. Stale detection becomes `agent_status: unknown`.

### W3 — the glass (D9)
`bin/fm-show.sh <target>` routing by type: `.md` → `cmux markdown open` (live reload means a
crewmate's report updates on screen as it writes); a task id → `cmux diff --source branch`
from its worktree; a directory → the project's Review workspace with `right-sidebar files`.
Dedupe by path — select an existing surface rather than stacking a duplicate.

Wired into: scout report relay, PR-ready relay, `local-only` diff review, plan/spec
presentation.

### W4 — config layer
Global `CLAUDE.md`'s "show artifacts in a right-hand cmux split" rule becomes the surface
routing rule; firstmate `AGENTS.md` gets the mux seam and herdr supervision; statusline and
context-watch move from tmux to cmux `set-status` / `set-progress` on Cortana's workspace;
`herdr integration install pi opencode`. Keybinding layers drop from three to two.

### W5 — layout as code (D13)
`bin/fm-glass.sh ensure` — idempotent create / rename / group / order from
`data/projects.md`, at bootstrap.

---

## 6. Risks — one spike each

1. **Server-restart survival.** `pane_history` defaults `false`, so a plain restart loses
   recent screen; `resume_agents_on_restore = true` restores agent conversations. Recovery
   assumes it can re-read a pane. Turn `pane_history` on and verify end-to-end.
2. **Spawn sequencing.** The recorded gotcha: the first `agent prompt` after `agent start`
   is silently swallowed — verify readiness and re-send.
3. **Reading output.** `agent read` / `pane read` emit **plain text, not JSON**, unlike
   every other verb; `recent-unwrapped` returns nothing for TUI agents. `fm-peek` adapts.
4. **herdr renders no documents.** By design — W3 is what keeps it painless.

---

## 7. Sequence

| Phase | Work | Exit gate |
|---|---|---|
| **0 — spike** | Headless-spawn one real Claude crewmate into herdr; drive a full ship task via `pane run` → `agent start` → `agent prompt --wait` → `agent wait` → `agent read`. Zero firstmate changes. | A green PR from an agent firstmate never touched via tmux |
| **1 — seam** | `fm-mux-lib.sh` + herdr/cmux drivers behind `FM_MUX`; tmux default | Driver-parity suite green for both (D7) |
| **2 — captain-side** | cmux driver for the away-mode daemon; fixes defect #1 | Away-mode e2e green with Cortana bare in cmux |
| **3 — canary** | One secondmate home on `FM_MUX=herdr` for a week | No missed wakes, no false stale |
| **4 — sensor** | Watcher on herdr states; retire composer scraping | `fm-tmux-lib.sh` gone from the herdr path |
| **5 — glass** | `fm-show.sh`, `fm-glass.sh`, doctrine/config update | Every report and diff reaches you rendered, unprompted |
| **6 — bus** | cortana-bus herdr backend (D8) | Crew addressable from the bus again |
| **7 — ctxwatch** | Re-source from `agent_session_path` transcripts (D18) | Nine gates re-keyed to real token counts |
| **8 — retire** | tmux off for crew | `grep -c tmux bin/` → personal shells only |

Phases 0–2 get a spec with numbered gates before any code (D16). Phases 3–8 stay design in
this document until reached.

Phase 0 is one crewmate-day and de-risks everything after it. Nothing else starts until
it's green.
