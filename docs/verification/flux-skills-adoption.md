# Flux CD agent skills adoption

This record supports the guarded adoption of `gitops-knowledge` and `gitops-repo-audit` from `fluxcd/agent-skills` and the Firstmate `flux-classic-gitops` amendment.

## Pinned upstream

- Source: https://github.com/fluxcd/agent-skills (`fluxcd/agent-skills`)
- License: Apache-2.0
- Tag: `v0.2.0`
- Commit: `9b05787530a3e200a9ac031fc8a477566e0b7adc`
- Adopted skills: `gitops-knowledge`, `gitops-repo-audit`
- Excluded skill: `gitops-cluster-debug` (not vendored or exposed)

## Verification commands

```sh
bin/fm-flux-skills-verify.sh
bin/fm-test-run.sh tests/flux-skills-adoption.test.sh
```

Expected `fm-flux-skills-verify.sh` output line:

```text
fm-flux-skills-verify: ok fluxcd/agent-skills v0.2.0 (9b05787530a3e200a9ac031fc8a477566e0b7adc); skills: gitops-knowledge gitops-repo-audit
```

## Maintainer refresh

Re-verify upstream identity and regenerate the vendor tree only through:

```sh
bin/fm-flux-skills-vendor.sh --tag v0.2.0
bin/fm-flux-skills-verify.sh
bin/fm-test-run.sh tests/flux-skills-adoption.test.sh
```

Update this record, `skills/vendor/fluxcd-agent-skills/MANIFEST`, and `CHECKSUMS.sha256` together when the pin changes.
