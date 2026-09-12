#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/config/project-context" "$scratch/worker" "$scratch/project"
render() { "$root/bin/fm-project-context.sh" "$scratch/project" "$scratch/worker" "$scratch/config"; }
[ -z "$(render)" ]
printf 'paired.md\n' > "$scratch/config/project-context/project.paths"
printf 'actual worker Python rules\n' > "$scratch/worker/CLAUDE.md"
printf 'owner checks\n' > "$scratch/worker/AGENTS.md"
if render > "$scratch/output" 2>/dev/null; then echo 'missing required source accepted' >&2; exit 1; fi
[ ! -s "$scratch/output" ]
printf 'frontend standards\n' > "$scratch/worker/paired.md"
render > "$scratch/output"
grep -q 'actual worker Python rules' "$scratch/output"
grep -q 'frontend standards' "$scratch/output"
grep -q 'SHA-256:' "$scratch/output"
printf 'new worker rules\n' > "$scratch/worker/CLAUDE.md"
render > "$scratch/output"
grep -q 'new worker rules' "$scratch/output"
if grep -q 'actual worker Python rules' "$scratch/output"; then exit 1; fi
printf 'PASS: absent opt-in, missing source, actual checkout, paired context, refreshed source\n'
