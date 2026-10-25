# fleet-contract-check
Runs each real cross-repo call with the installed versions in a throwaway HOME and FM_HOME, so a tool release cannot break a caller unnoticed.

- `fleet-contract-check [caller...]` prints `ok <caller>` or `FAIL <caller>: <cause>` per caller and exits 1 when any fails (2 on a usage error). `FM_MAIN_HOME` names the fork checkout it reads (default `$FM_HOME`, else `~/firstmate`); it never writes there.
- Callers: `dispatch-resolve` (the fork's `bin/fm-dispatch-resolve.sh` on the live `config/crew-dispatch.json`, offline), `owner-guard` (the binary the live `config/merge-gate` execs is installed), `checks-lint` (the add-on lint on a passing report), `limit-prompt-move` (installs the add-on into a scratch install root with its `install.sh` and runs the installed quota mover on a fixture home with no core `fm-account-pool-lib.sh`; a package that omits a library it loads fails).
- Not yet covered, queued as later slices: `fm-captain-hold.sh hold` to sign-off raise (red today: `bin/fm-procevent-signoff.sh` must pass `--ask-ref <hold task id>` to `sign-off-axi raise`; fix lands in the fork), `merge-card post`, the done-done receipt and gate.
- Wire-in (later slices): fm-update and fleet-tool publishes run it first and stop on a non-zero exit; fleet-pulse runs it on its cadence.
- `bash tests/fleet-contract-check.test.sh` covers a healthy fixture fleet and a broken caller being named.
