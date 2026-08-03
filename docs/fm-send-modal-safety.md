# `fm-send` modal safety

## Security invariant

`fm-send` may begin a Herdr text submission only after Firstmate positively identifies the target as an empty agent composer at its preflight.
A permission modal, pending composer, unreadable pane, malformed capture, missing composer row, or unrecognized detector result that is present at that boundary must stop Firstmate before it stages text or presses a key.
The refusal reports an explicit blocker instead of treating UNKNOWN as successful delivery.
The remaining-race section below owns the later transition window that this preflight cannot cover.

This protects the distinction that matters at the terminal boundary: a composer awaiting text is not a modal awaiting consent.

## Confirmed incident mechanism

The legacy Herdr send path staged text and then retried Enter until a turn started or composer inspection ended the loop.
A deterministic permission-modal TUI showed the first Enter approving the modal without starting a turn and the second Enter submitting the already-staged steer.
The pre-fix modal event stream was `text`, `enter`, `modal-approved`, `enter`, `turn-started`.
The ordinary empty-composer control was `text`, `enter`, `turn-started` and contained no approval event.

This establishes a live security defect in Firstmate's input automation without invoking a real provider or granting a real capability.

## Guard definition

- Scope: every text submission routed by `bin/fm-send.sh` to the Herdr backend.
- Representation: the existing structural `empty|pending|unknown` composer classification, derived from the rendered agent-composer row rather than permission-dialog wording or a human pane inspection.
- Observed layer: the real production `fm-send.sh` to `fm_backend_composer_state` to Herdr pane-read boundary immediately before literal staging begins.
- Retirement criterion: retire this preflight only when the Herdr transport offers an atomic semantic composer-submit operation or the Herdr adapter owns an equally fail-closed check immediately before every Enter and all callers use it.

The guard does not match a permission prompt's spelling.
It positively proves the safe representation instead: a structurally recognized empty composer.
This makes novel modal wording and malformed screens conservative refusals rather than false permissions.

## Outcome classes

| Observation | Action | Boundary evidence |
|---|---|---|
| `empty` | Stage text and allow the backend's verified submission flow. | The stub records one text event, one Enter, and one started turn. |
| `pending` | Refuse before staging or Enter. | Existing text remains byte-for-byte unchanged and the stub records no event. |
| `unknown` from an already-open permission modal | Refuse before staging or Enter. | The modal remains unapproved and the stub records no event. |
| `unknown` from an unreadable or failed capture | Refuse before staging or Enter. | The stub records no event and `fm-send` returns a blocker. |
| Malformed or unrecognized classifier output | Treat as UNKNOWN and refuse. | The shell `case` permits only the literal `empty` success value. |

The quantifier is every Herdr text send through `fm-send.sh`, not merely sends whose pane happens to contain a known Codex permission string.

## Violation and refusal proof

The controllable TUI in `tests/fixtures/herdr-permission-tui.py`, now driven by `tests/fm-send-permission-modal-probe.sh` from the existing strict send suite, first ran manually against the unmodified production path.
Its modal was approved and the staged text was submitted, proving the violation was reachable at the boundary.

The same modal then ran after the guard was added.
The guard returned non-zero, the TUI stayed in modal mode with `approved=false`, and its event list remained empty.
This proves the guard fired on the exact behaviour it exists to prevent rather than merely returning a reassuring internal value.

The positive control still ran end to end after the guard.
An empty composer received the staged text and exactly one Enter and reported a started turn.

## Layered dispatch-profile design

The permission preflight closes an already-open modal before staging, but it is not the complete dispatch-profile fidelity fix.
The remaining implementation must preserve requested policy separately from provider observation, check observation at every profile-changing boundary, and stop before a second Enter after a provider transition.

Metadata must retain `requested_model` and `requested_effort` independently from `observed_model`, `observed_effort`, `observed_at`, `observed_session_id`, and `observed_source`.
No observation may overwrite the requested profile.

Spawn, recovery, resume, and every steering submission attempt must read the provider-owned current settings.
A missing session id, absent row, stale generation, partial record, malformed record, ambiguous candidate, or read timeout is UNKNOWN and blocks managed submission.

The Herdr retry owner must compare the provider profile after an Enter that did not start a turn and before sending another Enter.
A transition away from the requested profile must record the observation, append a mismatch wake event, and return without submitting the staged text.

Provider transitions must retain distinct causes: approaching-limit nudge, hard `usage_limit_exceeded`, service-side reroute, interactive `/model`, resume-time settings replay, and unavailable observation.
Neither a failed premium request nor an observed cheaper profile proves that a usable fallback exists.

Managed Codex account preparation must set `notice.hide_rate_limit_model_nudge=true` as defense in depth.
The account-2 hard-limit incident proves that setting cannot replace boundary observation or the retry guard.

## Remaining race and ownership boundary

The released `fm-send.sh` preflight protects a modal that is already rendered when steering begins.
A modal or provider-profile transition that appears after preflight but before an Enter can be closed only at the retry owner inside `bin/backends/herdr.sh`.
The modal-between-Enters atomic per-Enter check in `bin/backends/herdr.sh` is explicitly deferred to task `steer-modal-atomic-layers`.
The requested-versus-observed metadata split in `bin/fm-spawn.sh` is explicitly deferred to task `steer-modal-atomic-layers`.
Neither deferred implementation path is part of this change.
a real Codex permission prompt approved END TO END was never run, so the composite case is inferred rather than observed.
