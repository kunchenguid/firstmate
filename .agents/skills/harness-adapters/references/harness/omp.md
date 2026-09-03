# OMP on Herdr: provisional

OMP is an experimental ship-and-scout adapter pending a recorded live run of both Mist profiles.
It is never eligible for ordinary dispatch, config selection, a fallback, or secondmate work.
A captain-supervised trial must explicitly invoke `../../../bin/fm-spawn.sh <id> <project> --scout --harness omp --profile personal|sf --backend herdr` with `FM_OMP_HERDR_EXPERIMENTAL=1`.

## Ownership boundary

Mist owns OMP installation, profiles, authentication, providers, models, and environment shaping.
Firstmate invokes the installed zsh functions without importing or binding a Mist checkout.
The personal profile uses the fixed argv-safe command `/bin/zsh -lic 'omp "$@"' fm-omp`.
The Salesforce profile uses the fixed argv-safe command `/bin/zsh -lic 'ompp "$@"' fm-omp`.
Firstmate forwards no profile, model, effort, config, alias, arbitrary environment, or launch argument into either wrapper.
Direct raw commands rooted at `omp` or `ompp` remain unverified operator escape hatches recorded as `harness=raw-omp`; they never claim this adapter.

## Launch and processing

Firstmate keeps OMP in the same Herdr pane for its whole lifecycle.
After submitting the fixed wrapper, Firstmate requires Herdr's native `agent wait <pane> --until idle` followed by `agent get <pane>` reporting `agent=omp` and `agent_status=idle`.
It then sends the encoded brief as one argv value through Herdr's native `agent prompt` command.
Terminal text is not readiness, processing, cancellation, or exit evidence.

## Control and recovery

Interrupt sends one Escape and reports `cancel=unconfirmed` because OMP and Herdr expose no structured cancellation acknowledgement accepted by Firstmate.
Exit sends `/quit` and requires the existing structured Herdr agent-state postcondition.
Relaunch reuses the exact recorded Herdr pane, defaults to the recorded Mist profile, and accepts only an explicit personal-or-Salesforce profile change.
Every failure after endpoint metadata publication either proves the exact fresh pane gone before removing metadata or leaves a private endpoint-bound cleanup-recovery record.
A failed relaunch always retains transaction-bound replacement recovery, even when endpoint removal is proven.

## Verification state

Hermetic launch, injection, boundary, recovery, interruption-capability, exit, relaunch, and snapshot tests are required for code changes.
The live candidate and exact opt-in command are recorded in `../../../docs/verification/runtime-backends.md`.
Do not describe OMP as verified until that document records a successful bounded run for both profiles.
