# Kimi Code composer captures

These files own the real Kimi Code screens replayed by `test_matrix_kimi_footer_zone` in `../../fm-composer-lib.test.sh` and `test_kimi_herdr_footer_readiness_and_delivery` in `../../fm-kimi-harness.test.sh`.
They were captured on 2026-10-14 with Kimi Code CLI 2.1.1 (`kimi --model kimi-code/k3 --auto`) on Herdr 0.9.3, macOS 26, in a guarded Herdr lab session (`bin/fm-herdr-lab.sh`) whose pane was 40 rows high.
The working directory was the scratch directory `/private/tmp/fm-kimi-capture`, which Kimi had been told to trust in the same session.

## Capture provenance

Each file is unchanged stdout from `herdr pane read <pane> --source visible --format ansi`, the styled viewport read behind `fm_backend_herdr_composer_state`.
The only edit is in `exited.ansi`, where the session ID Kimi printed in its resume hint is replaced by zeros of the same length.
Herdr omits the blank rows below the last drawn row, so each file ends at Kimi's `context:` row or, after exit, at the shell prompt.
Herdr's native `agent get` reported `agent_status` `idle` at every one of these captures, including `working.ansi`.

| File | Observed state |
| --- | --- |
| `idle.ansi` | Fresh session, empty composer, `context: 0% (0/256k)` |
| `typed.ansi` | `Reply with exactly KIMIPONG and nothing else.` typed into the composer and not yet submitted |
| `working.ansi` | 0.3 seconds after Enter: the echoed `✨` message and moon-phase spinner above an empty composer |
| `settled.ansi` | The finished reply above an empty composer, `context: 9% (22.6k/256k)` |
| `exited.ansi` | After `/exit`: the last composer and footer above `Bye!` and a login-shell prompt |

The live guard `../../fm-kimi-herdr-delivery-live-e2e.test.sh` drives the same Kimi and Herdr surfaces through the delivery path and refreshes these facts after a Kimi or Herdr upgrade.
