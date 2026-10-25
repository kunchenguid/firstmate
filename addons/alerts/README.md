# alerts

The model-outage alerts add-on — the observation that notices a lane stopped by
a model or provider outage and raises one grouped wake to the home. It is the
fork's `bin/fm-model-outage-lib.sh`, refreshed to the fork's current copy (with
the parked-homes guard) and made to run from this directory: its sibling
libraries (`fm-timeout-lib.sh`, `fm-composer-lib.sh`) are read from the fork's
`bin/` (`$SCRIPT_DIR`, else `$FM_HOME/bin`), and `fm_parked_meta` is the
watcher's if defined, else "never parked".

## Step-B hook (fork `bin/fm-watch.sh`)

Replace the fork's `. "$SCRIPT_DIR/fm-model-outage-lib.sh"` with the optional source
`[ ! -r "${FM_ADDONS_DIR:-$FM_HOME/projects/firstmate-addons}/alerts/bin/fm-model-outage-lib.sh" ] || . "${FM_ADDONS_DIR:-$FM_HOME/projects/firstmate-addons}/alerts/bin/fm-model-outage-lib.sh"`
and the per-cycle call with
`if declare -F fm_model_outage_tick >/dev/null; then fm_model_outage_tick || triage_log "model-error observation failed"; fi`.
Absent add-on = kun behavior. `tests/model-outage-hook-e2e.sh` (with
`FM_TEST_FORK` set to a Firstmate checkout) proves both cases over fixture lanes.

The same library defines `fm_alerts_push_suppress <task>`, which the fork's
`handle_push_transition` calls (when defined) instead of its old inline check: it
returns 0 for a cursor-harness task or one with an open captain call, non-zero
otherwise or when the watcher's `fm_meta_get`/`task_captain_call_open` are absent.

## Layout

- `bin/fm-model-outage-lib.sh` — the observer, plus the push-transition hook
  described above. `fm_model_outage_tick` reads each
  recorded lane once per 60-second scan, before the watcher's stale suppression,
  matches explicit provider/harness outage banners in a lane's visible viewport,
  and appends one grouped wake naming every lane failing with the same
  normalized error. `fm_model_outage_text` normalizes one error to a single
  printable line.
- `tests/model-outage-scan-e2e.sh` — the scan behaviour over fixture lanes (union wake,
  recovered/unreadable lanes, hung verdict, wrapped banner, usage-limit banner once,
  banner above the composer or in scrollback); run with `FM_TEST_FORK` set to a Firstmate checkout.
- `tests/fm-model-outage-live-e2e.test.sh` — the opt-in credentialed live
  journey. Moved verbatim and **never run from here**: it drives live agents
  (see the proof note).

## Frozen contract (identical to the fork)

- Interface the watcher uses: `bin/fm-watch.sh` sources the library from its own
  `bin/` directory and calls `fm_model_outage_tick` with no arguments once per
  cycle, before stale suppression. A non-zero return means the scan could not be
  recorded; the watcher logs one line and continues the cycle, it never aborts.
- The library sources its two sibling helper libraries (`fm-timeout-lib.sh` and
  `fm-composer-lib.sh`) from its own directory, and reads the composer library's
  usage-limit banner pattern rather than re-declaring it, so the outage alert
  cannot drift from the composer furniture. Those sibling files did not move, so
  the dormant copy only runs with the fork `bin/` tree beside it.
- It reads the watcher's `STATE` directory and the watcher-provided helpers for
  lane metadata, busy state, bounded backend reads, visible capture, composer
  normalization, pane hashing, and wake-queue append (`fm_busy_token_valid`,
  `fm_backend_target_of_meta`, `fm_backend_of_meta`, `fm_meta_get`,
  `fm_busy_current_gen`, `fm_run_timed`, `fm_backend_agent_state`,
  `task_captain_call_open` (push-transition hook only),
  `fm_backend_visible_capture_supported`, `fm_backend_visible_capture`,
  `fm_composer_normalize_trim_var`, `_fm_composer_leftbar_floor_row`,
  `hash_pane`, `fm_wake_append`, `wake`). It owns no settings, model changes, or
  recovery: the existing blocked/wait escalation owns later attention.
- Scope and cadence: only lanes whose meta names the `opencode` harness are
  observed, each read bounded to 3 seconds; a scan runs at most once per 60
  seconds. A mid-turn lane is matched against the usage-limit banner alone
  (the one outage that persists while a limited lane sits retrying); every other
  banner is named only once the lane is idle.
- Alert line appended to the wake queue, one per normalized error episode:
  `check: model outage affected=[<id>,<id>,...]: <normalized error>` under wake
  key `model-outage-<hash>`; a lane joining an alerted episode sends one updated
  grouped wake, a recovered lane leaves the record, and a lane whose endpoint is
  dead or missing is dropped without an alert.
- State under `$STATE/.model-outages/`, names unchanged: reads and writes
  `.scan-at`, `lane-<id>` (`<target>|<gen>|<hash>`), and `alert-<hash>`; a
  symlinked directory disables the observer, so a second monitor is never
  started.
