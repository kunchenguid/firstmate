# agy (VERIFIED LEAN 2026-08-28, Antigravity CLI 1.1.22, Gemini harness)

Lean-registered crewmate/scout adapter only; no secondmate claim. Busy/composer remain UNKNOWN until a dedicated probe (adapters may register with unknown classification — muse precedent). Herdr already detects kind agy via `herdr:antigravity_cli` (`agent=agy`, `agent_status` idle/working); firstmate reuses it.

| Fact | Value |
|---|---|
| Launch | `agy --model <model> -i "<brief>"` prompt-interactive (`-i`/`--prompt-interactive`); brief delivered via space-free `TASK_TMP/brief.md` copy (`/tmp/fm-<id>/brief.md`) so the HOME space (`⭐️ Jala-firstmate`) never appears in the quoted `$(__OPINPUT__ encode launch-brief < __AGY_BRIEF__)` path. `--dangerously-skip-permissions` parallels claude/grok unattended. Model/effort flags are threaded from dispatch. |
| Models | `--model <model>` Gemini family (e.g. `gemini-3.7-flash-medium/high`, `gemini-3.6-flash-*`, `gemini-3.5-flash-*`, `gemini-3.1-pro-*`) plus cross-provider ids visible via `agy models` (verified live `agy 1.1.22` lists gemini, claude, gpt-oss). Validate against `agy models`. |
| Effort | `--effort low|medium|high` (verified via `agy --help` on 1.1.22). `xhigh`/`max` omitted (no verified flag). |
| Herdr detection | kind `agy`, source `herdr:antigravity_cli`, `agent_status` idle/working (observed w4W:p1 Lia, w53:p1 sprite-studio). |
| Busy state | UNKNOWN — no dedicated probe yet; deferred by design (see Occam removable step). Classification waits for `bin/fm-busy-lib.sh` probe. |
| Composer | UNKNOWN — no dedicated shape probe yet; deferred (see `bin/fm-composer-lib.sh`). |
| Exit / Interrupt | Exit: `/exit` (verified clean exit to shell, Pane `unknown`); Interrupt: not yet probed — do not assume. |
| Secondmate | Not claimed — `bin/fm-spawn.sh` refuses `--secondmate` on agy (no primary supervision protocol). |
| Environment marker | None — detection via process ancestry `comm` name `agy` (`bin/fm-harness.sh`). No `AGY_*`/`ANTIGRAVITY_*` marker observed on live panes (OBSERVE only). |

Empirical minimum 2026-08-28 isolated Herdr lab `fm-lab-agy-lean-registe-40230-19967` w1:p1: `herdr agent start --kind agy --pane w1:p1 -- --model gemini-3.7-flash-medium -i "hello"` → `interactive_ready true`, idle; `agent prompt` accepted input (`HELLO_OK`); `/exit` returned to shell prompt (`agent_status unknown`), clean. Ctrl-C/D exit not needed.
