# Firstmate feature map

Baseline preconditions: a scratch `FM_HOME` from `scripts/verify-home.sh init`, never the live code-root home.

Launch that home with `scripts/verify-home.sh launch` and pass `doctor` before driving.

Keep `FM_HOME` exported from `scripts/verify-home.sh env` on every command.

Do not set `FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, or `FM_ROOT_OVERRIDE` unless a feature file says so.

Driving conventions: call the shipped `bin/` script named in the feature file.

Observe stdout banners, JSON fields, inbox ids, or watcher status lines.

Do not open a second harness against the same home.

Do not send keys into the live primary pane.

Proof/skip reporting: a proof names the command, the observable, and the evidence file under `$EVIDENCE`.

Skip only when the feature file's harness is absent (for `/ahoy`, a visible Firstmate chat history) and write the skip reason into `$EVIDENCE/skip.txt`.

Feature entry contract: each file is one user-facing surface.

It starts with an H1 and one paragraph of user-visible behavior, then exactly four H2s: Sub-features, How to get to it (user POV), Driving it with the named harness, Gotchas.

Features:

- [session-start](session-start.md) - take the helm and read the ordered digest
- [bearings](bearings.md) - pick up where the fleet left off
- [inbox](inbox.md) - queue an out-of-band note for Firstmate
- [watcher](watcher.md) - arm home-scoped event-driven supervision
- [ahoy](ahoy.md) - recap this session's visible events
