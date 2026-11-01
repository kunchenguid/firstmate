# Local runtime validation

- Installed pinned checksum-verified hc 0.1.14 with `bin/fm-install-hc.sh "$PWD/.live-test/tools"`; no system installation.
- Executed the existing hc app-detection smoke through a disposable copy, retained as `spawn-smoke-driver.sh`. Adaptations: short `fm-hclab-s` session and evidence-local socket/app paths to fit macOS's 103-byte socket ceiling; isolated HOME/TMPDIR; lab shell `.zshrc` to suppress new-user onboarding; retained spawn notices, metadata and real core label output. Added explicit CLI precedence and default-metadata checks on a private `fm-lab` tmux socket. Final exit: 0.
- Executed `python3 .live-test/live-boundaries.py` (retained driver) against real hc 0.1.14 and real backend resolver/away daemon. Final exit: 0. The deliberately absent-jq PATH retained other needed system utilities. Real core terminal environment independently supplied supervisor identity.
- Executed `HOME="$PWD/.live-test/home" TMPDIR="$PWD/.live-test/tmp" bash tests/fm-backend.test.sh`; exit 0. This supplementary fake-boundary regression file is not classified as live proof.

Oracle: the supplied Stage 3 intent, as narrowed by recorded decisions. Expected selections, exact provenance fields, opt-out notices, worker labels, absence of default/explicit provenance, and hc supervisor refusal come from that contract, not implementation-source matching.

Scope: live local product execution using synthetic labels/marker inputs and a synthetic Unix app-control listener. No native Herdr app was started or inspected; logs prove detection and core label persistence, not GUI rendering. No graphical source changed, so CLI transcripts are the reviewer-visible evidence rather than screenshots. Classic Herdr precedence was exercised as resolver input only, not as a fleet session launch. Previously declined endpoint-binding and preflight-race concerns were not reopened.

Initial setup attempts encountered long socket paths and zsh new-user onboarding; reruns with the above disposable configuration passed. Both hc labs completed guarded teardown with unchanged fleet tripwires. Private tmux server was killed and a final socket query confirmed no server; retained server PIDs were absent. No background check remains.
