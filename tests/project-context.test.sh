#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/config" "$scratch/worker"
printf 'actual worker Python rules\n' > "$scratch/worker/CLAUDE.md"
printf 'owner checks\n' > "$scratch/worker/AGENTS.md"
mkdir -p "$scratch/backend" "$scratch/frontend" "$scratch/product-rules" "$scratch/child/config"
for repo in backend frontend; do
  git init -q "$scratch/$repo"
  git -C "$scratch/$repo" remote add origin "git@github.com:UseRialto/rialto-$repo.git"
  printf '%s CLAUDE rules\n' "$repo" > "$scratch/$repo/CLAUDE.md"
  printf '%s AGENTS rules\n' "$repo" > "$scratch/$repo/AGENTS.md"
done
printf 'shared product safety\n' > "$scratch/product-rules/AGENTS.md"
render_rialto() { "$root/bin/fm-project-context.sh" "$scratch/backend" "$scratch/worker" "${1:-$scratch/config}"; }
if render_rialto > "$scratch/output" 2> "$scratch/error"; then echo 'Rialto accepted missing manifest' >&2; exit 1; fi
[ ! -s "$scratch/output" ]
grep -q -- '--prepare-rialto' "$scratch/error"
"$root/bin/fm-project-context.sh" --prepare-rialto "$scratch/backend" "$scratch/frontend" "$scratch/product-rules/AGENTS.md" > "$scratch/config/rialto-project-context.paths"
. "$root/bin/fm-config-inherit-lib.sh"
propagate_inheritable_config "$scratch/config" "$scratch/child/config"
render_rialto "$scratch/child/config" > "$scratch/output"
for expected in 'backend CLAUDE rules' 'backend AGENTS rules' 'frontend CLAUDE rules' 'frontend AGENTS rules' 'shared product safety' 'actual worker Python rules' 'owner checks'; do
  grep -q "$expected" "$scratch/output"
done
cp "$scratch/output" "$scratch/first-output"
render_rialto > "$scratch/output"
cmp "$scratch/output" "$scratch/first-output"
digest=$(shasum -a 256 "$scratch/worker/CLAUDE.md")
grep -Fq "SHA-256: ${digest%% *}" "$scratch/output"
grep -Fq "Required instruction source: $scratch/worker/CLAUDE.md" "$scratch/output"
printf 'new worker rules\n' > "$scratch/worker/CLAUDE.md"
render_rialto > "$scratch/output"
grep -q 'new worker rules' "$scratch/output"
if grep -q 'actual worker Python rules' "$scratch/output"; then exit 1; fi
rm "$scratch/worker/AGENTS.md"
if render_rialto > "$scratch/output" 2>/dev/null; then echo 'Rialto accepted missing checkout instructions' >&2; exit 1; fi
[ ! -s "$scratch/output" ]
printf 'owner checks\n' > "$scratch/worker/AGENTS.md"
rm "$scratch/frontend/CLAUDE.md"
if render_rialto "$scratch/child/config" > "$scratch/output" 2>/dev/null; then echo 'child accepted missing paired context' >&2; exit 1; fi
[ ! -s "$scratch/output" ]
printf 'frontend CLAUDE rules\n' > "$scratch/frontend/CLAUDE.md"
git -C "$scratch/frontend" remote set-url origin https://github.com/unrelated/rialto-frontend.git
if "$root/bin/fm-project-context.sh" --prepare-rialto "$scratch/backend" "$scratch/frontend" "$scratch/product-rules/AGENTS.md" > "$scratch/output" 2>/dev/null; then echo 'unverified paired repository accepted' >&2; exit 1; fi
[ ! -s "$scratch/output" ]
git -C "$scratch/backend" remote set-url origin https://github.com/unrelated/rialto-backend.git
[ -z "$("$root/bin/fm-project-context.sh" "$scratch/backend" "$scratch/worker" "$scratch/child/config")" ]
printf 'PASS: required Rialto configuration, verified pairs, child inheritance, missing sources\n'
