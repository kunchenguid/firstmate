# Kimi Code

Verified on 2026-09-25 with Kimi Code CLI 2.1.1 (earlier passes recorded 2.0.0 on 2026-09-17).

## Operating facts

| Fact | Value |
|---|---|
| Binary | Absolute executable resolved from `PATH`, then executable `$HOME/.kimi-code/bin/kimi`; spawning refuses if neither exists. |
| Launch | Bare interactive TUI with `--auto`, followed by readiness-gated pointer delivery; positional prompts are rejected. |
| Models | Observed default `kimi-code/kimi-for-coding`, `kimi-code/kimi-for-coding-highspeed`, `kimi-code/k3`, and `kimi-code/k3-256k`; use `kimi provider list --json` for current configuration. |
| Busy state | Standalone Kimi is unknown pending a live-verified semantic source, preferring Wire's `prompt` lifetime then documented hooks including `Interrupt`; Kimi behind Pi uses Pi lifecycle, and the moon-phase spinner is never a state source. |
| Exit command | `/exit`. |
| Interrupt | Single Escape, which prints `Interrupted by user`. |
| Skill invocation | `/<skill>`, for example `/no-mistakes`; Firstmate skills are discovered. |
| Autonomy | `--auto` is the `Never Ask` tier; `-y` and `--yolo` now select the distinct, weaker `Ask When Needed` tier and are not used. |
| Trust dialog | A fresh worktree shows `Trust this folder?` with `Trust this folder` pre-selected; spawn reads the visible pane, recognizes the complete dialog (its title, both navigation-hint tokens `↑↓ navigate` and `Enter select` - matched separately so a hint wrapped in a narrow pane still counts - the selected `❯ Trust this folder`, and `Don't trust`), sends Enter on every poll the complete dialog is still there, verifies that a later visible-pane capture no longer contains it, and then continues the ordinary readiness gate. Trust is never pre-registered in `config.toml`; the dialog is answered live. |
| Slash submission | One Enter submits, with no popup swallow or settle hazard. |
| Environment marker | None; identity comes from process ancestry command name `kimi`, which `../../../bin/fm-harness.sh` keeps a retained foreign marker from overriding. |
| Composer | Bordered box with a bare `>` prompt glyph and no observed ghost or placeholder text. 2.1.1 draws its permission-tier status row and right-anchored `context: N%` meter as two contiguous rows directly below the box; `../../../bin/fm-composer-lib.sh` owns them as kimi footer furniture, without which every cursorless verdict reads `unknown`. |
| Effort | `kimi provider list --json` exposes per-model `supportEfforts` values `low`, `high`, and `max` plus a `defaultEffort`; the launch flag and mapping remain unverified, so spawn records and omits requested effort per `references/common/model-and-effort.md`. |

## Readiness-gated start

`../../../bin/fm-spawn.sh` launches Kimi bare, handles the complete trust dialog when it appears (its 2.0.0 markers are unchanged through 2.1.1), waits for the composer box or `Welcome to Kimi Code!`, sends only `Read the brief at <absolute-path> and follow it exactly.`, and requires a cleared composer plus either the echoed `✨` submission or nonzero context before accepting delivery.
Every trust predicate reads `fm_backend_visible_capture` - the viewport with no scrollback - never the 120-line history read the delivery gate uses: the dialog is a TUI frame, and a history-backed capture would keep reporting it after Kimi redrew past it, storming Enter into a live composer and then failing an already trusted spawn. That primitive is implemented on tmux (`capture-pane -p -S -0`), herdr (`pane read <pane> --source visible`, verified against Herdr 0.8.0 in `docs/verification/runtime-backends.md`) and zellij (`action dump-screen --pane-id`, no `--full`), and `FM_BACKEND_VISIBLE_CAPTURE` in `bin/fm-backend.sh` is the one list of them. orca has only a history read; cmux's `read-screen` without `--scrollback` plausibly reads just the viewport but has not been live-verified. A Kimi spawn on either is therefore refused at preflight, before the worktree or pane exists, naming the backend and the missing verified viewport capability, pending that verification for cmux. There is no fallback to the scrollback read. A viewport read that exits nonzero fails readiness immediately with the backend named, rather than being mistaken for a blank screen. A successful but blank viewport read is absence of evidence, not evidence of a cleared dialog: it costs that poll, restarts the two-capture ready count below, and leaves the trust diagnostics where they were. The trust answer is retried until the dialog clears - Kimi swallows keypresses during its startup window, so a single Enter can be dropped - and the re-send is gated on the complete dialog still being on that visible pane, so it cannot fire once the dialog cleared. Trust is accepted only after a later visible-pane capture proves that the dialog cleared; a stuck dialog fails with the observed dialog signals and the answer count in the diagnostic.
Any single marker of the dialog on that visible pane - `Trust this folder` or the negative `Don't trust` option - withholds the ready verdict, because a capture caught mid-redraw and a capture that has painted only the box title both miss the complete dialog while the banner above it would otherwise read as ready. The banner also prints before the dialog paints at all, which no single capture can distinguish from a ready pane, so the verdict additionally requires two consecutive captures that are each ready and free of dialog text; a capture that is not ready, and a blank one, restarts that count, which is what keeps the pre-banner boot captures and redraw frames from spending it.
This launch-then-send shape is mandatory because Kimi rejects positional instructions as an unknown command.
The path must be absolute because the instructions live outside the task worktree and Kimi reads them there without `--add-dir`.

Sending before readiness was reproduced as a silent drop with zero exit status, an empty composer, `context: 0%`, no echoed user message, and a healthy-looking idle pane.
The startup input-readiness window is the established cause; the banner is not.
An early Enter can expand the composer to multiple content rows, leaving pointer text on the first row and the cursor on an empty later row.
The shared tmux reader therefore locates the complete bordered composer and treats real text on any content row as positive evidence that submission remains pending.
No rendering signal proves Kimi will accept input during this window, and the window can outlive the submit core's whole Enter-retry budget: on 2.0.2, and again reproduced on 2.1.1 behind herdr, readiness passed, the pointer sat wrapped in the composer, every budgeted Enter was dropped, and a single later Enter submitted instantly.
The delivery wait therefore re-sends Enter - never retypes - on every poll the shared composer classifier still proves the composer holds the pointer, until the `FM_KIMI_DELIVERY_POLLS` budget is spent, and never sends into an empty or unclassifiable composer, so a confirmed or in-flight delivery is never followed by a stray Enter; the postcondition verification stays exactly as strict rather than readiness being relaxed.
A gate failure after the pane and local copy exist rolls the provisional task record back so the backlog row stays queued; the stranded pane, local copy, slot claim, and hook token have no owner yet (separately filed work), and `../../../tests/fm-kimi-delivery-resend-live-e2e.test.sh` cleans them up itself.

Observed spinner captures had optional leading whitespace, a moon-phase glyph, whitespace around `·`, and rotating tip text, including during tool execution.
The delivery-only matcher requires the observed whitespace, deliberately excludes the unobserved zero-whitespace form, and does not require trailing tip text.
Kimi's footer tip can show `ctrl+c: cancel` while idle, and its idle bar can contain lowercase `thinking` as an effort label.
Neither is a busy-state source.
The delivery-only spinner match covers the full moon-phase glyph set but remains locale- and emoji-font-sensitive because Kimi exposes no stable ASCII busy token.

## Crew turn-end hook and primary limit

Kimi is outside the primary turn-end guard scope.
`../../../docs/turnend-guard.md` owns its separate global hook surface and captain-approved crew wake integration.

`../../../bin/fm-spawn.sh` installs one marker-delimited Firstmate entry in `$HOME/.kimi-code/config.toml`, one silent always-zero hook script, and one private token registry under `$HOME/.kimi-code/fm-turn-end.d/`.
Each Kimi worker worktree receives a gitignored `.fm-kimi-turnend` pointer.
The global hook touches `state/<id>.turn-ended` only when the Stop payload's `cwd`, pointer, and registry entry all agree.
A guarded silent hook cannot be verified from absence of effect, so prove invocation with an unguarded probe before concluding it did not fire.
The guarded turn-end signal remains a wake notification.
Standalone Kimi has no busy-state source until one is live-verified.
