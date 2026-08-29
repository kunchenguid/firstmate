<!--
Promoted verbatim from scout report `fmx-design-q2` (2026-08-27), which lived in the
gitignored `data/` tree. Tracked here so gates can cite it as `spec_ref` and so the
design is readable from any clone. Body below is the report as written.

Erratum reconciled during the slice-1 build (see the `## Erratum` section appended at
the end of this file): §7's per-helper timeout and its total wall-clock ceiling were
mutually unsatisfiable. The appended section records the reconciliation and is the
authority for the helper budget.
-->

# N concurrent firstmates — design

Scout `fmx-design-q2`. Design only; a mechanical build brief should be written from this.
Every claim is from the binary, the files, or a command I ran. Measurements are reproduced inline.

---

## 0. Two reframes, before the questions

### Reframe 1 — home isolation is already built and running right now

```
$ ps -eo pid,args | grep fm-watch.sh
  7909  bash /Users/stoneevenson/firstmate/bin/fm-watch.sh   FM_HOME=/Users/stoneevenson/firstmate
 65876  bash /Users/stoneevenson/firstmate/bin/fm-watch.sh   FM_HOME=.../firstmate-d89373/6/firstmate
```

Two homes, two independent watchers, two `state/` dirs, two backlogs, two locks, one shared
`bin/`. `fm-lock.sh:12-14` is per-home; `fm-watch.sh:50` stamps `fm-home` into the watcher lock
and `fm-watch-arm.sh:59` verifies it. Send/peek/watch/teardown resolve windows through **this
home's** `state/<id>.meta`, never a name search. The council was right to kill the "two homes hold
locks" gate — it is green on the unchanged tree.

So this is not a new architecture. The state layer is already home-parameterised. Four things are
missing, and one of them is the whole ballgame.

### Reframe 2 — the hook was not forgotten. It was **evicted, with cause.**

This is the single most important finding in the task, and it changes the answer to Q4.

`bin/fm-captain-bootstrap.sh` **was** registered. A mac-config apply on 2026-08-14 removed it, and
the removal is recorded as a defect with a stated rationale — `mac-config/desired/policy.yaml:266-270`,
which I read directly:

```yaml
  - value: fm-captain-bootstrap
    reason: >
      D-11 — a SessionStart hook that moves and deletes files, keyed to tmux, whose writer
      has been dead since 2026-06-25.
```

That is a **forbidden-substring ban in the control plane**, not an oversight. `~/.claude/settings.json`
is a *rendered* file (`desired/registry.yaml`, `render: json`), and the registry's own cutover note
says undeclared keys are deleted on apply. Three green gates enforce it: **V13** (forbidden
substring), **V15** (hook allowlist), and the hook budget (`policy.yaml:199`, `global_hooks_max: 1`).
`Edit(~/.claude/settings.json)` is additionally on the permissions deny list.

**The objection is correct on its facts.** The script really does mutate durable files on every
session start — `shutil.move` of the handoff at `:125` and `os.remove` of the resume directive at
`:131` — and its writer really is dead: `fm-ctx-statusline.sh` is **also unregistered**
(`settings.json` has no `statusLine` key), so nothing is producing the sentinels that machinery
consumes.

**The design answers the objection rather than arguing with it** (§5).

---

## 1. Measurements

Run against the live primary home, exactly as a SessionStart would invoke it.

```
$ /usr/bin/time -p env FIRSTMATE_ROLE=captain FM_HOME=~/firstmate bash bin/fm-captain-bootstrap.sh \
    <<<'{"source":"startup","cwd":"~/firstmate","session_id":"probe"}'
real 0.21   real 0.12   real 0.13
```

| Fact | Value |
|---|---|
| Hook wall-clock today | **0.12–0.21 s** |
| Injected captain block | **10,188 chars ≈ 2,550 tokens** |
| `additionalContext` cap | **10,000 chars** — today's block is **already over it**. Corroborated two ways: firstmate's own spec (`docs/specs/context-watchdog.md:36`, "a pointer if > 10k chars") and `FM_CTX_INJECT_CAP=10000` at `:84`. Treat as a real ceiling; I could not verify it against harness source |
| `fm-watch-arm.sh --status` | **0.07 s** (its 5 s timeout is a ceiling, never paid) |
| `fm-lock.sh status` | **0.02 s** |
| Crew-role output today | **0 bytes** |
| `data/projects.md` verbatim dump | **4,108 chars — 40% of the block** |
| Declared hook timeout convention | **`"timeout": 10`** (harness default is 600) |

At 12 peers, the decision-making measurement:

```
READ 12 PEERS FROM FILES:  0.66 ms   (663 bytes)
12 SUBPROCESS EXECS:     373    ms   (healthy helpers; ~60 s if they hang)
```

**A per-peer exec design is ~565× slower and can exceed the declared 10 s timeout, which yields
zero injected context.** That ratio decides §6 and §7.

The boot is not slow because the script is slow. It is slow because the script never runs.

---

## 2. Q1 — Activation contract

### Precedence chain

| # | Signal | Why it ranks here |
|---|---|---|
| 1 | **tmux pane option `@fm_role`** (herdr: `--env` at tab create) | Positive, set only by `fm-spawn`, and **measured non-inheriting in both directions** — a new window reports `invalid option`, and a split of a marked pane does not receive it |
| 2 | `FIRSTMATE_ROLE` ∈ `{captain, crew}` | Existing validated override (`fm-ctx-lib.sh:74`, `fm-captain-bootstrap.sh:76`) |
| 3 | `FM_CTX_ROLE` | Legacy passthrough, unchanged |
| 4 | **Default: `captain`** | D2 — the inversion |

The pane marker outranks the env var deliberately: a pane option is *placed* by the spawner and is
authoritative for that pane, whereas an env var can arrive by accident. This is the positive signal
on spawned panes that D2 requires, and it is not a cwd heuristic.

### The leak, measured precisely

`fm-spawn.sh:369` calls `tmux new-window` with **no command and no `-e`**, then types the launch
line in with `send-keys -l` (`:525`). So the agent's base environment is the **tmux server's**
environment, and `fm-spawn.sh:504,514` layers on only six names — five set to empty and `FM_HOME`.
It never writes `FIRSTMATE_ROLE` or `FM_CTX_ROLE`; a full `bin/` grep shows both names are
**read-only across the entire tree**, in exactly two files.

The leak path is narrower than "env inheritance", and worth stating exactly:

- **A captain pane exporting the var does NOT leak.** Measured: a pane that ran
  `export FIRSTMATE_ROLE=captain` then `tmux new-window` produced `CHILD_ROLE=[]`.
- **The tmux server's global environment DOES leak.** Measured, twice:
  ```
  $ tmux setenv -t <ses> FIRSTMATE_ROLE captain ; tmux new-window -d -t <ses>:
    LEAKED=[captain]
  ```
  and independently, a server *started* from an environment carrying the var showed
  `FIRSTMATE_ROLE=captain` in `show-environment -g`, and every window created afterwards inherited it.

So the hazard is **latent, not active** — today's live server env is clean. It arms the moment the
tmux server is started from a captain context (a Hermes-launched "be Cortana" session is the
realistic trigger). `fm-spawn.sh:506-513`'s comment — *"Role is unaffected — fm_ctx_role is
cwd-based"* — is true only while `FIRSTMATE_ROLE` is unset, and the cwd branch is the **last** rung
of the chain, not the operative one. D2 removes the last rung's safety anyway.

### The structural guarantee

Three changes to `fm-spawn`, in order of strength:

1. **`tmux set-option -p @fm_role crew`** on the pane after `new-window`. Non-inheriting in both
   directions (measured), so it cannot leak to a grandchild.
2. **`tmux new-window -e FIRSTMATE_ROLE=crew`** — confirmed supported in the installed **tmux 3.6b**,
   read back as `crew`, and it overrides the inherited global without writing session env.
3. Add `FIRSTMATE_ROLE=crew` to the existing assignment prefix, so the agent process agrees.

Each independently defeats the leak; together they cover pane re-launch by hand (1), window
creation (2), and process env (3). A shell assignment prefix is applied after all inheritance, so
no server env, login profile, or `update-environment` copy can beat it.

**Zero-change fallback worth knowing:** `state/<id>.meta` already records `window=<session>:<window>`
for every spawned pane (`fm-spawn.sh:482-494`). A hook can compute its own `session:window` from
`$TMUX_PANE` and match. That marker exists on disk today with no `fm-spawn` change at all.

**Ruled out:** process ancestry. Measured — by launch time the agent's parents are
`zsh ← treehouse get ← -zsh ← tmux server`; no `fm-spawn` frame survives.

---

## 3. Q2 — Home resolution

A session opened by hand in `~/mac-config` has no `FM_HOME`. The rule, in order:

1. **`FM_HOME` if set.** Every spawned pane and every provisioned peer workspace has it.
2. **Else the home containing cwd.** Walk cwd upward, prefix-match against registered homes in the
   fleet view (§6). Catches a session inside a home or inside `<home>/projects/<name>`. Zero execs —
   a string compare over an already-read file.
3. **Else the primary home** = `FM_ROOT` (the parent of the running `bin/`), **not** `$HOME/firstmate`.

`~/mac-config` therefore resolves to the primary and gets Tier-1 context (§7). It does not need to
"know which firstmate it is" in any deeper sense: with a shared fleet view every instance can answer
*what is the fleet doing* regardless of home. The home only decides which backlog it would write to
and which lock it would take.

**Fix required:** `fm-ctx-lib.sh:77` and `fm-captain-bootstrap.sh:18` both hardcode
`${FM_HOME:-$HOME/firstmate}`. Both must fall back to `FM_ROOT`. `FM_ROOT` is the *code* checkout,
`FM_HOME` the *data* home; they are independent, and every home already runs the primary's `bin/`.

---

## 4. Q3 — Same-home collision

**The lock guards mutation, not activation.** That distinction is the answer, and it is already how
`fm-lock.sh` behaves — it is consulted only when a session intends to steer.

- The second instance **activates fully**: same injected fleet view, answers "what is the fleet
  doing" perfectly, reads any project, reasons, drafts.
- It is **an observer, not an error**. One line, in captain-facing language:

  > *Another session is steering this home right now, so I'm reading rather than driving. Say the
  > word if you want me to take the helm.*

- It refuses only spawn / steer / teardown / merge, in one plain sentence, **at the moment the
  captain asks for one** — never as a boot-time warning.
- **No banner, no red text, no error string at boot.** `AGENTS.md:160` already prescribes read-only;
  what was missing is the presentation, and that is the actual design work here.
- Takeover: `fm-lock.sh:48` already detects a dead holder (`lock: stale`). Add `--take`, permitted
  only when the holder is provably dead. A live holder is never evicted without the captain's word.

With D2, several sessions on one home is the **normal** case, not a failure case. Anything that
reads as an error would fire constantly and train the captain to ignore it.

---

## 5. Q4 — Cross-repo installation path

### Recommendation: a declared task against **mac-config**, preceded by splitting the script.

Not a firstmate-owned `--install-hook`. I originally favoured the installer; the evidence killed it.
A firstmate-written `~/.claude/settings.json` would be (a) deleted by the next `stone apply`, which
renders only declared keys and **already reports this file as drifted**, (b) blocked by the
permissions deny list, and (c) in violation of three currently-green gates. It would be a change
that silently un-applies itself — the worst possible outcome for a boot path.

**The path has two steps, and the first is the one that matters:**

**Step 1 — split the script so the ban's stated reason no longer applies.**
D-11 objects to *durable file mutation on every session start by a subsystem whose writer is dead*.
That is precisely the REHYDRATE block (`:104-133`: `shutil.move` of the handoff, `os.remove` of the
resume directive), which belongs to the context-watchdog subsystem — whose writer,
`fm-ctx-statusline.sh`, is itself unregistered and therefore genuinely dead.

Ship **`bin/fm-boot-context.sh`: a strictly read-only emitter.** It reads the fleet view and this
home's `state/`, writes nothing, moves nothing, deletes nothing, and holds no lock. The rehydrate
machinery stays out of the hot path until its writer is revived as its own task. The ban's reason is
then retired on the merits, not waived.

**Step 2 — declare it through the control plane.** Four coordinated edits in `mac-config`:

1. `desired/registry.yaml` — add the second hook object under `.claude/settings.json`.
2. `desired/policy.yaml:161` `hook_allowlist` — add an entry matching command and timeout byte-for-byte (V15).
3. `desired/policy.yaml:199` — raise `global_hooks_max` from `1` to `2`.
4. `desired/policy.yaml:266` — remove the `fm-captain-bootstrap` forbidden-substring rule, which
   Step 1 has made obsolete. The new script has a different name, so this is a deletion of a spent
   rule rather than a carve-out.

`mac-config` is a registered `[direct-PR]` project, so this is ordinary fleet work through the
normal lifecycle. Then `stone apply` renders it, and firstmate's live checkout picks it up.

**Cost of the alternative** (hand-write the live file now to get boot working today): it works until
the next apply and then silently reverts, leaving a boot path that is intermittently blind — which
is strictly worse than being reliably blind.

**Note the two-claimant conflict**, which the build brief must not trip over: `~/.claude/settings.json`
is tracked by the `claude-global-config` repo *and* rendered destructively by mac-config's plane.
A commit in the former is not a change in the latter. **mac-config is the effective owner**; declare
there, and let the render land in `~/.claude`.

**Trap, named by the council and confirmed:** `tests/fm-captain-bootstrap-digest.test.sh` asserts by
invoking the script directly. A gate of that shape goes green while a real session still boots blind.
See gate **m1**.

---

## 6. Q5 — Shared fleet view

| Property | Decision |
|---|---|
| **Location** | `~/.local/state/firstmate/fleet/` — absolute, outside every home, survives any home's teardown, untouched by the tracked-file sweep that fast-forwards homes |
| **Shape** | One file per home: `<home-id>.json` |
| **Writer** | **That home's watcher**, once per poll. `fm-watch.sh:181` already touches its beacon every 15 s — same loop, no new process. Plus one immediate write on spawn and on teardown |
| **Race-freedom** | **By construction: exactly one writer per file, ever.** No file has two writers, so no lock exists to contend. Writes are temp-file + `rename(2)` (atomic), so a reader never sees a partial file |
| **Readers** | Glob the directory. Never write, never lock |
| **Staleness** | `now − mtime`. Over 90 s (6 polls) renders as `watcher stale <age>`; the peer is still shown, never dropped |
| **GC** | A home's teardown removes its own file. Orphans older than 7 days are unlinked by any watcher — safe, because a returning writer simply rewrites its own file |
| **Authority** | **Advisory.** Truth remains tmux plus each home's `state/`. This is a boot cache; anything acted on is re-read from the owning home — the same contract the existing disclaimer already carries |

Per-peer required fields — the minimum that answers *what is the fleet doing*: home id, in-flight
count, needs-decision/blocked count, watcher state, staleness age. ~55 chars per peer.

Not under the primary home: that would make one peer structurally special and couple the shared view
to that home's lifecycle. The task specifies "outside any one home", and that is correct.

---

## 7. Q6 — Boot budget at N peers

| Budget | Value | Basis |
|---|---|---|
| **Total hook wall-clock ceiling** | **1.5 s hard** | Declared timeout is 10 s; 1.5 s is 6× headroom. Measured today: 0.13 s |
| **Per-peer exec budget** | **ZERO** | File reads: 0.66 ms for 12 peers vs 373 ms for 12 execs |
| **Own-home helpers** | 2 execs, timeout **2 s each** (down from 5 s) | Measured 0.07 s and 0.02 s — a 25× margin |
| **Output ceiling** | **under 10,000 chars** (see §1 on provenance) | Today's block is 10,188 — **already over** |
| **Degradation** | An unreadable or stale peer yields **exactly one marker line**, never a stall | A file read cannot hang; absent/corrupt → `- <id> [unreadable]` |
| **Failure visibility** | Emit `## Reconciliation digest — UNAVAILABLE (<reason>)` | `:287`'s bare `except` swallows the whole digest: **a boot that lost all context looks identical to a healthy one** |

### Reconciling with `DIGEST_CAP = 2000`

"Full digest" and "capped" cannot both hold at N peers. **Replace one cap with two tiers**, split by
whether the session is actually steering.

**Tier 1 — universal, every session, never elided.** Measured prototype:

```
# firstmate — fleet (injected at boot; no tool calls needed)
You are a firstmate. Home: ~/firstmate (steering). Manual: ~/firstmate/AGENTS.md

## Fleet (4 instances)
- primary      [3 in flight, 1 need a decision] watcher healthy
- afs-sm       [2 in flight, 0 need a decision] watcher healthy
- cellarsky-sm [1 in flight, 1 need a decision] watcher stale 42m
- hermes-sm    [0 in flight, 0 need a decision] watcher healthy
To act on another instance's work, ask it — do not reach into its home.
Snapshot at boot — run bin/fm-wake-drain.sh before acting.
```

**540 chars (~135 tokens) at 4 peers; ~1,004 chars (~250 tokens) at 12.**

**Tier 2 — only for the session holding the lock:** spawn lifecycle, backlog, per-task detail.
Capped, `… (+N more)` permitted here.

### Does an elision marker still satisfy "zero tool calls"?

**Yes for task detail; no for peers.** The rule:

> **A peer is never elided. Per-task detail may be.**

D3's test is whether the session can answer *what is the fleet doing* with zero tool calls. Tier 1
answers that completely for every peer, always. Dropping a **peer** would break D3; dropping a task
**detail line** does not, because drilling into one task was always going to cost a call.

### The D2 cost, cut by ~90%

D2 was accepted with its cost stated. Measured, that cost is **2,550 tokens** per incidental session.
Tiering brings it to **~135–250 tokens**, with the full block paid only where it is used — and it
brings the output back under the 10,000-char cap it currently exceeds. This honours D2 exactly as
decided while removing most of its price. The largest single win is dropping the 4,108-char verbatim
`data/projects.md` dump (40% of the block) to generated one-liners in Tier 2 only.

---

## 8. Q7 — Provisioning entry point

**One command: `bin/fm-home-new.sh <id> [--projects a,b | --all]`** — creates the home, registers it,
creates the workspace, launches it.

It reuses `fm-home-seed.sh`, which already does the hard parts: `treehouse get --lease --lease-holder
<id>` for a home that survives with no live process (`:468`); a validation gauntlet (7 path refusals,
operational-dir containment, symlink checks); and **transactional rollback** with 6 explicit refusal
guards on every destructive path. Generalise its `.fm-secondmate-home` marker to `.fm-home` carrying
`id` and `kind=peer|secondmate`.

**One deliberate divergence: `projects/` is fleet-global, not per-home.** `fm-home-seed.sh` re-clones
each project into the new home. For a *peer* that is wrong — 17 clones × N peers, and it contradicts
D1's "one fleet". Peers set `FM_PROJECTS_OVERRIDE=<primary>/projects`. Safe, because firstmate never
writes to `projects/` (prime directive #1), crewmates take isolated treehouse worktrees from the
shared pool, and that pool already serves concurrent consumers (worktrees 1–8 of one firstmate pool
exist right now). It also means `fm-fleet-sync` runs once, not N times. Subordinate secondmates keep
their scoped clones — that is a deliberate access boundary, and peers are not subordinate.

### Decision: the mux seam GAINS a workspace verb

`fm_mux_ensure_workspace <label> <cwd>` → opaque handle, and `fm_mux_new_window` finally honours the
session argument its herdr driver currently discards (`fm-mux-lib.sh:104`, where `$1` is never bound
and the signature comment admits it).

| Driver | Analogue | Command |
|---|---|---|
| tmux | a **session** | `tmux has-session -t <label> \|\| tmux new-session -d -s <label>` — literally the two lines already at `fm-spawn.sh:358` |
| herdr | a **workspace** | `herdr workspace create --cwd <path> --label <label> --no-focus`, keyed on `workspace_id` from `workspace list` |

Two herdr facts the build must respect. Workspace creation is verified non-interactive and returns
`.result.workspace` plus `.result.root_pane`, but there is **no create-and-launch in one call** — it
is a strict two-call minimum (`workspace create` → `pane run` / `agent start --pane`). And **labels
are not unique**: two workspaces labelled `archify` are live right now, so idempotency must key on
`workspace_id`, never the label. (`fm-herdr-workspaces.sh:70` currently matches labels with `grep -qw`
against raw JSON, and `:45` builds agent names containing `/` while herdr's own contract requires
`[a-z][a-z0-9_-]{0,31}` — two latent bugs worth fixing while nearby.)

**Why add the verb rather than scope it out.** The seam has **zero production callers today** —
`fm-spawn.sh` sources `fm-tmux-lib.sh`, not `fm-mux-lib.sh`. A seventh unused verb would be
speculative; but `fm-home-new.sh` becomes its **first real caller**, which is exactly what turns a
speculative seam into a used one. It pays a second dividend: **one workspace per peer home** dissolves
the shared-session namespace merge that causes three of the four leaks in §9.

**Cost of the alternative** (scope workspace creation out): `fm-home-new.sh` carries `FM_MUX`
conditionals internally, and firstmate gains a *third* place that knows how to place a pane — after
`fm-spawn.sh`'s raw tmux and `fm-herdr-workspaces.sh`'s direct herdr calls.

---

## 9. Cross-home leaks the build must close

All four trace to **one shared tmux session name**, not to the state layer.

| # | Leak | Where | Effect |
|---|---|---|---|
| 1 | Session name hardcoded | `fm-spawn.sh:358-359` | Every home's `fm-<id>` windows land in one `firstmate` session. Confirmed live for both homes. Also a cross-home spawn DoS: `:364-367` refuses a duplicate window name |
| 2 | Window list hardcoded | `fm-captain-bootstrap.sh:253` (`-t firstmate`) | Home B's captain is shown home A's windows as its own fleet |
| 3 | **"Managed" decided by session name alone** | `fm-ctx-lib.sh:37,85-87` | Every home's context watchdog treats **every** home's panes as managed — and that is the gate on whether it may `/clear` a pane. The most dangerous of the four |
| 4 | Global window scans | `fm-supervise-daemon.sh:559-566`; the non-`fm-*` fallback in `fm-send.sh:46` / `fm-peek.sh:28` | Cross-home first-match resolution and mis-attributed stale escalations |

Per-home workspaces (§8) fix 1–3 directly. #4 needs the fallback scoped to this home's metas.

Recorded, not blocking: `FM_ROOT` is one shared checkout for all homes, so the tangle guard
(`fm-guard.sh:34`), `/updatefirstmate`'s target (`fm-update.sh:53`), and the `no-mistakes` remote in
the shared `.git/config` are global **by design**. Separately, the FM_HOME resolution preamble is
**copy-pasted across 26 scripts** with 3 non-conforming variants — worth extracting into
`fm-ctx-lib.sh` during this build, since this change touches the resolution rule itself.

---

## 10. Q8 — Gates, each red before / green after

Schema requires `observable`, `test_ref`, `mutation_verified`; these are written to fit.

| id | Observable | Red today because |
|---|---|---|
| **m1-hook-registered** | A **real** SessionStart fires it: the rendered `~/.claude/settings.json` invokes the emitter **and** a freshly started session creates `state/.boot-canary` containing that session's id. Asserting on direct invocation is explicitly forbidden by this gate | Not registered; actively banned by `policy.yaml:266` |
| **m2-boot-emitter-is-read-only** | Under `strace`/`fs_usage`-equivalent observation (or a read-only bind of `state/`), a full boot performs **zero** writes, renames, or unlinks | `:125` `shutil.move`, `:131` `os.remove` — the exact D-11 objection |
| **m3-crew-under-captain-env** | Mutation: start the tmux server with `FIRSTMATE_ROLE=captain` in its environment **and** `tmux setenv -g`, then spawn; the crew pane resolves `crew` and emits no captain block | Leak measured (`LEAKED=[captain]`); `fm-spawn.sh:504,514` never sets either role var |
| **m4-boot-budget-hostile** | Every helper stubbed to `sleep 999` via `FM_BOOTSTRAP_BIN`, 12 synthetic peers: wall-clock **< 1.5 s**, valid JSON, output **< 10,000 chars**, degradation markers present, **zero execs on the peer path** | 2 × 5 s timeouts = 10 s ≥ the declared 10 s timeout → zero context; and today's output already exceeds 10,000 chars |
| **m5-digest-never-silent** | Force the digest builder to raise; output contains an explicit `UNAVAILABLE` marker | `:287` bare `except` drops the whole digest silently |
| **m6-peers-never-elide** | 12 synthetic peers: 12 required lines, all five required fields each, total within the Tier-1 budget | No fleet view; `DIGEST_CAP` would elide peers |
| **m7-dead-peer-marker** | Backdate a peer file's mtime: exactly one stale marker line, wall-clock unchanged, no exec attempted against that peer | No fleet view |
| **m8-no-cross-home-leak** | Two homes; write beacon, wake-queue, backlog and meta records in A. B's injected context and B's `state/` contain **zero** of A's records; A appears only as one fleet-view summary line; **and B's watchdog does not classify A's panes as managed** | `fm-ctx-lib.sh:37,85-87` classifies by session name, so today it does |
| **m9-home-scoped-window-list** | No `-t firstmate` literal remains; each home's window enumeration is scoped to its own workspace/session and returns only its own windows | `fm-captain-bootstrap.sh:253` hardcoded |

**Accepted red baseline:** `gate-l2-loop-audit-level` (`gates/LEDGER.md:3`) is unrelated to this work
and is declared an accepted red baseline. The definition of done must read **"no *new* red gates"**,
not "empty drain list", or the build is conscripted into unrelated repair.

---

## 11. Deferred — named, not designed

- **Peer-to-peer work handoff between instances.** Ship the read-only view; transfer is its own task
  with its own atomicity gates (`fm-backlog-handoff.sh` is parent→child and queued-only).
- **Migrating `fm-spawn`'s raw tmux onto the mux seam** — except the one new
  `fm_mux_ensure_workspace` call site `fm-home-new.sh` introduces.
- **The `AGENTS.md` rewrite** — write it in the build, once the seam is approved.
- **Repairing `gate-l2-loop-audit-level`** — accepted red baseline.
- **Reviving the context-watchdog writer** (`fm-ctx-statusline.sh` is unregistered, which is *why*
  D-11 called its writer dead). Out of scope here, but it is the reason the rehydrate block must be
  split out rather than carried along.

---

## 12. Recommendation

**This should ship, and the build is mechanical from here.** No unresolved fork remains.

Slicing, smallest-first, each independently valuable:

1. **Split the emitter** — `bin/fm-boot-context.sh`, strictly read-only (gate m2). Prerequisite for
   everything, and the thing that retires D-11 on the merits.
2. **Register it** — the mac-config task in §5 (gate m1). This alone fixes the stated root cause.
3. **Activation contract** — pane option + `new-window -e` + prefix, resolver precedence, `FM_ROOT`
   fallback fix (gates m3, m8).
4. **Tiered digest and budget** — Tier 1/Tier 2, 2 s helper timeouts, non-silent failure, under the
   10k cap (gates m4, m5).
5. **Shared fleet view** — watcher writes one file per home, emitter reads the glob (gates m6, m7).
6. **Provisioning** — `fm-home-new.sh` + `fm_mux_ensure_workspace` + per-home workspaces (gate m9,
   closing leaks 1–3).

Slices 1–2 are separable from 3–6 and deliver most of the value: they turn a blind boot into an
instant one. Slices 3–6 are what make it correct at N.

**One caution for the build brief.** Two slices touch things outside firstmate's own tree — slice 2
changes machine-level configuration through mac-config's control plane, and slice 6 changes the
tmux/herdr topology the captain is actually looking at. Both are reversible and both go through
normal review, but neither should land silently, and slice 2 must go through mac-config's gates
rather than around them.

---

## Erratum — helper timeout reconciliation (added 2026-08-27, slice 1)

§7 declares two numbers that cannot both hold:

- **Total hook wall-clock ceiling: 1.5 s hard** (row 1 of the §7 budget table), which
  gate **m4** asserts directly (`wall-clock < 1.5 s` with every helper stubbed to hang).
- **Own-home helpers: 2 execs, timeout 2 s each** (row 3).

Two serial 2 s timeouts is 4 s, which exceeds the 1.5 s ceiling by 2.7x. With every
helper stubbed to hang — exactly m4's condition — the design as written fails its own
gate.

**Resolution: the 1.5 s total is authoritative; the per-helper timeout drops to 0.6 s.**

Rationale:

1. The 1.5 s total is the number with external justification — it is derived from the
   declared `"timeout": 10` hook convention (6x headroom) and is the number m4 asserts.
   It is also the number that protects the actual failure mode: exceeding the declared
   hook timeout yields *zero* injected context.
2. The 2 s per-helper figure carries no independent justification. §7 states its own
   basis as "measured 0.07 s and 0.02 s — a 25x margin"; it is a safety factor, not a
   requirement. At 0.6 s the margin over the slowest measured helper (0.07 s) is still
   8.5x.
3. 2 x 0.6 s = 1.2 s worst case, leaving ~0.3 s of the 1.5 s ceiling for the emitter's
   own file reads (measured in §1 at sub-millisecond for 12 peers).

The emitter additionally enforces a **shared deadline**, not just a per-helper cap: each
helper is granted `min(per-helper cap, budget remaining before the ceiling)`, and a
helper whose remaining budget has been exhausted is skipped and rendered as an explicit
degradation marker rather than run. Per-helper caps alone would not bound the total if a
helper were ever added; the shared deadline does.

Both numbers are overridable for testing: `FM_BOOT_TOTAL_BUDGET` (default `1.5`) and
`FM_BOOT_HELPER_TIMEOUT` (default `0.6`).

---

## END-GOAL condition 2: what is proven, and what is not (added 2026-08-28)

END-GOAL condition 2 reads:

> Boot injects the fleet picture in **under a second**, with no synchronous network sweep,
> and degrades to an explicit marker rather than silently reporting an empty fleet.

END-GOAL also says all five conditions must be **machine-checked, not asserted**. Two of
condition 2's three clauses are. The third is not, and this section says so rather than
letting a gate's prose imply otherwise.

### Machine-checked

- **No synchronous network sweep.** Gate `m4-boot-budget-hostile`, normal path: the boot runs
  with `curl`, `wget`, `nc` and `ssh` shimmed to log and fail, and the log must stay empty.
  Reinforced structurally: at most two helper execs for the whole boot however many peers
  exist, and none attributable to a peer - the peer path is file reads, so it cannot reach the
  network by construction.
- **Degrades to an explicit marker rather than silently reporting an empty fleet.** Gate
  `m5-digest-never-silent`, which covers a raising section, an absent home, an unreadable
  `state/`, an unreadable wake queue, an unreadable status file, and a malformed budget - and
  which also asserts that ordinary absence still reads as plain absence, so the marker keeps
  its meaning.

### NOT machine-checked: the "under a second" figure

It is measured, and it is reported on every gate run, but it is not a pass/fail condition.

Measured on the development host, same code throughout:

| condition | boot latency |
|---|---|
| normal path, live primary home | **0.23s** |
| normal path, gate fixture | 0.39-1.06s |
| hostile path (every helper wedged), ambient load ~150 | 0.55-1.11s |
| hostile path, load ~205 | 1.41-4.49s |
| hostile path, 8-way CPU saturation (40 samples) | p50 1.178s, p90 2.385s, max 2.761s |

The reason it is not gated: elapsed wall clock here is dominated by CPU availability, which no
budget logic can bound. The same unchanged emitter measures 0.55s and 4.5s depending only on
what else the machine is doing. A sub-second assertion would therefore be a claim about the
host, not about this code, and gating it produced exactly the flakiness that took three
verification rounds to diagnose - a gate that fails ~30% of the time teaches everyone to
ignore it, which is worse than no gate.

What `m4` asserts instead are the properties that *determine* latency and are immune to load:
the helper deadline is enforced, the two helpers run concurrently rather than serially, the
peer path costs zero execs, and no network call is made. If those hold, the boot is fast
whenever the machine has capacity; if the machine has no capacity, nothing in this repository
can make it fast.

### A related finding worth recording

On a host at load ~130, the **normal** boot can spend its entire 1.5s budget on interpreter
startup and skip both helpers, rendering watcher state and steering as `UNAVAILABLE`. That is
the degradation contract working correctly and it is never silent - but it means the design's
1.5s budget is tight enough that an ordinary boot degrades on a busy machine. Raising it
would trade injected detail against the declared 10s hook timeout. That trade is the
captain's to make and is deliberately not made here.
