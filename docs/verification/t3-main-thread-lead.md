# T3 main-thread lead verification

Behavioral coverage lives in `tests/fm-t3-delegation.test.sh`.
Run:

```bash
bash bin/fm-test-run.sh tests/fm-t3-delegation.test.sh
```

The suite uses isolated temporary homes and fixture git worktrees; it does not call T3 MCP tools.

Evidence includes ownership mismatch refusal, idempotent intent and import, uncertain dispatch recovery, terminal failure and cancellation mapping, nested live work, isolation refusal, status and wake publication, and credential exclusion from persisted records.
