---
name: openfoam-multipass-runtime
description: Agent-only procedure for transferring sanitized MachRack handoffs and generated cases to an existing Multipass OpenFOAM VM and validating Foundation v14 runs.
user-invocable: false
metadata:
  internal: true
---

# openfoam-multipass-runtime

Load this skill before transferring a sanitized MachRack handoff or generated case to a Multipass OpenFOAM VM, running Foundation v14 preprocessing or a solver, validating results, or diagnosing or repeating such a run.

This skill owns the conditional runtime procedure, while the converter and application repositories own their input schemas, command help, and scientific acceptance criteria.

## Preconditions and safety

Use only an existing Multipass instance explicitly authorized by the captain for this run.

Discover the candidate instances with `multipass list`, select one deliberately, and never infer its identity from a remembered name or address.

Confirm the selected instance, operating system, Foundation version, CPU, RAM, swap, and readability of `/opt/openfoam14/etc/bashrc` with `multipass exec` before transferring anything.

Use an inspection shaped like the following, without `set -u`, because the Foundation shell setup may reference optional shell variables.

```sh
multipass exec "$VM" -- bash -lc '. /opt/openfoam14/etc/bashrc; . /etc/os-release; printf "os=%s %s\\n" "$NAME" "$VERSION_ID"; printf "foundation=%s\\n" "${WM_PROJECT_VERSION:-unknown}"; printf "foam_run=%s\\n" "${FOAM_RUN:-unknown}"; printf "bashrc="; test -r /opt/openfoam14/etc/bashrc && echo readable || echo missing; printf "cpu="; nproc; printf "ram="; awk "/MemTotal:/ {print \\$2 \" kB\"}" /proc/meminfo; printf "swap="; awk "/SwapTotal:/ {print \\$2 \" kB\"}" /proc/meminfo'
```

Run the inspection in a shell that sources `/opt/openfoam14/etc/bashrc`, and treat any missing or contradictory prerequisite as a stop rather than a reason to alter the instance.

Never create, destroy, restart, or resize an instance as part of routine validation.

Never use the captain's private project files or the canonical port-5174 application data as input.

Use only sanitized handoffs, generated cases, and explicitly approved supporting inputs whose provenance is recorded.

Define run-specific values without embedding VM state in a committed procedure.

```text
VM=<selected existing instance>
VM_RUN_ROOT=<OpenFOAM run root discovered or supplied for this VM>
RUN_ID=<unique disposable identifier>
VM_RUN_DIR=$VM_RUN_ROOT/$RUN_ID
VM_CASE_DIR=$VM_RUN_DIR/case
EVIDENCE_DIR=<local task-owned evidence directory>
HANDOFF=<local sanitized handoff path>
CASE_DIR=<local generated case path>
CASE_MANIFEST=$CASE_DIR/case-manifest.json
CASE_IDENTITY=$CASE_DIR/case-identity.json
```

## Input identity and generation

Validate the exact handoff with the authoritative converter before transfer.

Record the handoff format, format version, converter profile, source IDs, provenance, and digest from the converter's validation output.

Use the converter's documented command help rather than inventing flags, and stop if the converter cannot validate the exact input without modification.

Generate the case through the converter from that validated handoff and record the generated case manifest and case identity.

Never hand-edit a generated handoff, case, mesh, field, manifest, identity file, or result artifact.

Before transfer, calculate and record hashes for the handoff, case manifest, and case identity with the repository's approved digest algorithm, normally `sha256sum`.

Keep the converter validation and generation records with the local evidence, including the exact input and output paths and all source IDs.

## Transfer

Create only the unique task-owned disposable run directory under the VM's OpenFOAM run root after the preconditions and identity checks pass.

Confirm that `RUN_ID` is new for this VM and create only its input and case directories with a v14-sourced `multipass exec` command.

Use `multipass transfer` for sanitized inputs and generated cases only, quote every path, and keep host and VM paths explicit in the evidence.

A directory transfer may use the recursive form supported by the installed `multipass transfer --help`, but it must name the exact generated case directory rather than a broad home directory.

```sh
multipass exec "$VM" -- bash -lc '. /opt/openfoam14/etc/bashrc; mkdir -p -- "$1/input" "$2"' bash "$VM_RUN_DIR" "$VM_CASE_DIR"
multipass transfer "$HANDOFF" "$VM:$VM_RUN_DIR/input/handoff"
multipass transfer --recursive "$CASE_DIR/." "$VM:$VM_CASE_DIR/"
```

Calculate and record the host hashes before transfer, and then calculate the same paths under `VM_CASE_DIR` with `multipass exec` after transfer.

```sh
sha256sum "$HANDOFF" "$CASE_MANIFEST" "$CASE_IDENTITY" | tee "$EVIDENCE_DIR/host-hashes.txt"
multipass exec "$VM" -- bash -lc '. /opt/openfoam14/etc/bashrc; sha256sum "$1" "$2/case-manifest.json" "$2/case-identity.json"' bash "$VM_RUN_DIR/input/handoff" "$VM_CASE_DIR" | tee "$EVIDENCE_DIR/vm-hashes.txt"
```

Compare the transferred handoff, case manifest, and case identity hashes with the recorded host hashes before execution.

Preserve source IDs, converter provenance, and the host-to-VM path mapping in the evidence.

Transfer logs and complete result artifacts back with `multipass transfer` into the local evidence directory after execution, using the VM-prefixed source form and exact artifact paths.

```sh
multipass transfer --recursive "$VM:$VM_RUN_DIR/evidence/logs/." "$EVIDENCE_DIR/logs/"
multipass transfer --recursive "$VM:$VM_CASE_DIR/<complete-result-artifact>/." "$EVIDENCE_DIR/results/"
```

Do not copy secrets, credentials, private project material, or broad home-directory contents in either direction.

## Stage execution

Run every required Foundation stage as a separate `multipass exec` invocation so the first failing stage remains identifiable.

Source `/opt/openfoam14/etc/bashrc` in every VM shell, change to the exact VM-side case path, and record the VM-side path before running the command.

Capture each stage's stdout and stderr, exact command, return code, elapsed time, peak resource data when available, and any warnings in a stage-specific evidence record.

Use a task-owned local log for each invocation and preserve the raw logs outside the repository unless a sanitized excerpt is needed for review.

A stage invocation has this shape, with the stage command represented as one command name plus its exact arguments.

```sh
run_stage() {
  stage=$1
  shift
  start_epoch=$(date +%s)
  {
    printf 'stage=%s\nvm=%s\nvm_case_dir=%s\ncommand=' "$stage" "$VM" "$VM_CASE_DIR"
    printf '%q ' "$@"
    printf '\n'
  } | tee "$EVIDENCE_DIR/$stage.meta"
  set +e
  multipass exec "$VM" -- bash -lc '. /opt/openfoam14/etc/bashrc; cd -- "$1"; shift; "$@"' bash "$VM_CASE_DIR" "$@" >"$EVIDENCE_DIR/$stage.log" 2>&1
  rc=$?
  set -e
  elapsed=$(( $(date +%s) - start_epoch ))
  printf 'return_code=%s\nelapsed_seconds=%s\n' "$rc" "$elapsed" >>"$EVIDENCE_DIR/$stage.meta"
  return "$rc"
}

run_stage blockMesh blockMesh
run_stage snappyHexMesh snappyHexMesh -overwrite
run_stage checkMesh checkMesh -allTopology -allGeometry
run_stage foamRun foamRun -solver fluid
```

Prefer `/usr/bin/time -v` or an equivalent VM-supported measurement around the single stage when available, and record that peak resource data separately from the solver's scientific output.

Run `blockMesh` when the generated case requires it.

Run `snappyHexMesh -overwrite` only when the generated case requires it.

Run `createBaffles -overwrite` only when the generated case requires it.

Run `checkMesh -allTopology -allGeometry` for mesh and topology validation.

Run `foamRun -solver fluid` for the Foundation v14 fluid solver when the generated case specifies that solver path.

Run `paraFoam -touch` only after a complete result artifact exists.

Run a headless ParaView reader only after a complete result artifact exists, and record the reader version, loaded file or case path, and any warnings or errors.

Do not combine preprocessing, mesh checks, solver execution, and result reading into one shell command or one status claim.

## Evidence interpretation

Keep separate verdicts for contract validation, generated-input validity, topology and mesh quality, solver startup and completion, final-time output, residuals and continuity, nonlinear convergence, thermophysical bounds, terminal flux closure, and ParaView loading or visual evidence.

A successful converter validation does not prove generated-input validity, mesh quality, solver completion, convergence, physical balance, or visual loading.

SIGKILL or OOM, a timeout, missing time directories, incomplete result files, or a process exit without final-time evidence are not passes.

A short bounded run may establish execution and startup behavior only, and never establishes convergence or scientific validity.

Treat the solver return code as one evidence item rather than a substitute for final-time, residual, continuity, convergence, bounds, and flux checks.

Report warnings from `checkMesh`, missing or degenerate fields, unstable residuals, violated thermophysical bounds, and unmatched terminal fluxes separately.

A visual result is not established by file existence alone, and a reader that loads metadata but cannot load the complete result is not a visual pass.

## Diagnosis and rerun

Begin every diagnosis from the observed user-visible failure and record the trigger, masking condition, and symptom in the evidence.

Compare the failing run with a proven path, locate the earliest divergence, identify the smallest counterfactual that could distinguish causes, and seek disconfirming evidence.

Do not replace a user-visible failure with a later symptom caused by an earlier failed stage.

When a code defect is proven, fix the converter or application source, add a regression test, regenerate the handoff and case from scratch, and rerun every affected stage.

When testing resource or solver controls, change one supported variable at a time, retain the exact handoff and provenance, and never silently weaken fidelity or acceptance criteria.

Keep raw logs out of commits.

Commit only concise sanitized evidence when needed, including versions, hashes, commands, stage results, corrections, reruns, and limitations.

## Runtime completion

Report the exact final time and the identity of the result artifact.

Report residuals and continuity, mesh checks and warnings, terminal or passive flux accounting, thermophysical bounds, and reader evidence.

State explicitly whether the run is executable, mesh-valid, solver-complete, converged, physically balanced, and visually loaded.

Do not claim acceptance when any required boundary is unproven.

## Cleanup

Preserve the evidence and verify its completeness before cleanup.

Remove only task-owned disposable VM run directories and local temporary logs after the evidence is safely retained.

Never broadly delete VM data, stop shared applications, or perform destructive cleanup without explicit captain authorization.

## Maintainer verification

Maintainer verification confirmed that `multipass list` and a v14-sourced `multipass exec` inspection are available on the current host, but this observation is not a guarantee about any future VM, resource allocation, address, or tool version.
