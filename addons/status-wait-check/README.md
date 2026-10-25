# status-wait-check

`bin/status-wait-check <verb> <text>` is the shared write-time guard for the fork's status append path. It exits 1 for a blocked line whose text declares a wait, prints `use paused: ...`, and exits 0 for other verbs and genuine blocker causes (including failing checks, missing credentials, errors, and decisions).

Fork hook (`bin/fm-secondmate-report.sh`): immediately before appending a status line, call `"${FM_ADDONS_DIR:-$FM_HOME/projects/firstmate-addons}/status-wait-check/status-wait-check" "$verb" "$text" || return 1` (use the function's actual verb/text variable names). Refused append must not write the status line.

When `config/owner-rules` is enabled, all verbs first use the [owner-rules publication check](../owner-rules/README.md#lavish-refusal-secondmate-notes-and-merge-card-posts).

Test: `bash status-wait-check/tests/status-wait-check.test.sh`.
