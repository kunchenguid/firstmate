# ADR 0001: Handoff presence (not SessionStart `source`) triggers rehydrate

## Decision

The rehydrate path in `fm-captain-bootstrap.sh` injects the leave-off doc whenever
`state/handoff-<window>.md` exists, regardless of the SessionStart `source` value.
`source` is recorded in the injected block for traceability but is not gated on.

## Why

The recon flagged `source:"clear"` as documented-but-unverified for the installed
Claude Code. A handoff file only ever exists because the watchdog ran its
checkpoint→/clear cycle for this exact window, so the file's presence is itself an
unambiguous, harness-independent "this is a watchdog restart" signal. Keying on it
sidesteps the unverified `source` string entirely, and the archive-on-inject step
guarantees it fires exactly once. Without a handoff, behavior is byte-for-byte the
prior bootstrap (verified by G3's no-regression assertion).

This qualifies as an ADR: it is hard to reverse (other components assume the
presence-trigger contract), surprising without context (a reader expects a
`source=="clear"` branch), and the result of a real trade-off (robustness to an
unverified harness string vs. an explicit source check).
