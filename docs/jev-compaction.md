# Jev park-not-delete trace compaction

Crew harnesses may call [`bin/fm-jev-compaction.sh`](../bin/fm-jev-compaction.sh) to park low-value tool-call / trace segments on disk.

This helper is opt-in and is not wired into spawn or firstmate supervisor core.

## Enablement

Default is off: absent `$FM_HOME/config/jev-compaction` and unset `FM_JEV_COMPACTION` is a no-op exit 0.

`FM_JEV_COMPACTION=off` is also a no-op, even when the presence-flag file exists.

Set `FM_JEV_COMPACTION=on`, or create the presence-flag file `config/jev-compaction`, then invoke the helper on a JSONL trace.

## KV-cache constraint

Do not delete middle messages by default.

Provider prefix KV cache stays valid only when the live prompt prefix is unchanged.

The helper therefore parks only a trailing run of low Jev `keep_value` segments, copying them under `state/<id>/trace-park/` with `index.jsonl`.

Full live-trace rewrite of middle low-value segments is `--cache-busted` only, for traces whose cache is already invalid (model switch or idle return).

Park means keep the bytes on disk. It does not Tamara-style delete.

## Invoke

```
FM_HOME=/path/to/home FM_JEV_COMPACTION=on bin/fm-jev-compaction.sh \
  --task <id> --trace trace.jsonl --out compacted.jsonl
```

Pass `--scores scores.json` in tests to skip the network Jev call.
