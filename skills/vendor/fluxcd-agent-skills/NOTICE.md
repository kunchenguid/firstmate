# Third-party notice: fluxcd/agent-skills

This directory vendors a subset of the official Flux CD agent skills from
[fluxcd/agent-skills](https://github.com/fluxcd/agent-skills) at tag `v0.2.0` (commit `9b05787530a3e200a9ac031fc8a477566e0b7adc`).

- License: Apache-2.0
- Adopted skills: gitops-knowledge gitops-repo-audit
- Excluded skills: gitops-cluster-debug (not installed or exposed by firstmate)

Retain this notice and the upstream license when refreshing the vendor tree.
The authoritative adoption record is `MANIFEST`; routine verification uses
`bin/fm-flux-skills-verify.sh`.
