#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-verify-test.XXXXXXXX")" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/repo" "$tmp/config" "$tmp/mock" "$tmp/remote/home/.local/bin"
git -C "$tmp/repo" init -q
printf 'committed\n' > "$tmp/repo/kept.txt"
printf 'deleted\n' > "$tmp/repo/deleted.txt"
mkdir -p "$tmp/repo/tools/build"
printf 'generator\n' > "$tmp/repo/tools/build/gen.sh"
git -C "$tmp/repo" add kept.txt deleted.txt tools/build/gen.sh
git -C "$tmp/repo" -c user.name=Test -c user.email=test@example.test commit -qm initial
git -C "$tmp/repo" worktree add -qb verify "$tmp/tree"
rm "$tmp/tree/deleted.txt"
printf 'SECRET=hidden\n' > "$tmp/tree/.env"
mkdir -p "$tmp/tree/node_modules/pkg"
printf 'dependency\n' > "$tmp/tree/node_modules/pkg/index.js"

if "$root/bin/fm-remote-verify.sh" >"$tmp/out" 2>&1; then
  printf 'missing arguments succeeded\n' >&2; exit 1
fi
grep -q 'usage:' "$tmp/out"

if FM_CONFIG_OVERRIDE="$tmp/config" "$root/bin/fm-remote-verify.sh" "$tmp/tree" true >"$tmp/out" 2>&1; then
  printf 'missing config succeeded\n' >&2; exit 1
fi
grep -q 'remote verify is not configured' "$tmp/out"

printf 'runner@example.test\n' > "$tmp/config/remote-verify"
cat > "$tmp/mock/ssh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
while [ "$1" = -o ]; do shift 2; done
shift
# Arguments must reach the host only through stdin, never through the login shell.
[ "$#" -eq 1 ] && [ "$1" = 'bash -s' ] || { printf 'unexpected remote command: %s\n' "$*" >&2; exit 90; }
HOME=$TEST_REMOTE_HOME exec bash -s
MOCK
cat > "$tmp/mock/rsync" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
args=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = -e ]; then shift 2; continue; fi
  case "$1" in
    runner@example.test:*) args+=("${1#runner@example.test:}");;
    *) args+=("$1");;
  esac
  shift
done
exec "$TEST_REAL_RSYNC" "${args[@]}"
MOCK
cat > "$tmp/remote/home/.local/bin/pnpm" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_PNPM_LOG"
MOCK
cat > "$tmp/tree/check.sh" <<'CHECK'
#!/usr/bin/env bash
set -euo pipefail
[ "$(git rev-parse HEAD)" = "$TEST_SOURCE_HEAD" ]
[ "$(git rev-list --count HEAD)" -eq 1 ]
[ -z "$(git remote)" ]
[ -z "$(git status --porcelain -- kept.txt)" ]
[ "$(git status --porcelain -- deleted.txt)" = ' D deleted.txt' ]
if git -c user.name=Test -c user.email=test@example.test commit --allow-empty -qm forbidden >/dev/null 2>&1; then exit 1; fi
if git config --get-regexp '^(credential\..*|remote\..*\.url|push\..*)$' >/dev/null; then exit 1; fi
if git config --get credential.helper >/dev/null; then exit 1; fi
if [ -d .git/hooks ] && [ -n "$(find .git/hooks -type f -print -quit)" ]; then exit 1; fi
[ -f kept.txt ]
[ -f tools/build/gen.sh ]
[ -z "$(git status --porcelain -- tools/build/gen.sh)" ]
[ ! -e node_modules ]
[ ! -e deleted.txt ]
[ ! -e .env ]
CHECK
chmod +x "$tmp/mock/ssh" "$tmp/mock/rsync" "$tmp/remote/home/.local/bin/pnpm" "$tmp/tree/check.sh"
export TEST_REMOTE_HOME="$tmp/remote/home"
TEST_REAL_RSYNC=$(command -v rsync)
export TEST_REAL_RSYNC
export TEST_PNPM_LOG="$tmp/pnpm.log"
TEST_SOURCE_HEAD=$(git -C "$tmp/tree" rev-parse HEAD)
export TEST_SOURCE_HEAD
PATH="$tmp/mock:$PATH" FM_CONFIG_OVERRIDE="$tmp/config" "$root/bin/fm-remote-verify.sh" "$tmp/tree" bash check.sh
[ ! -e "$tmp/pnpm.log" ] || { printf 'pnpm ran without being asked\n' >&2; exit 1; }

# The script installs nothing itself; the command does, with the user bin directory on PATH.
printf '{"packageManager":"pnpm@10.34.3"}\n' > "$tmp/tree/package.json"
printf 'lockfileVersion: 9.0\n' > "$tmp/tree/pnpm-lock.yaml"
PATH="$tmp/mock:$PATH" FM_CONFIG_OVERRIDE="$tmp/config" "$root/bin/fm-remote-verify.sh" "$tmp/tree" bash check.sh
[ ! -e "$tmp/pnpm.log" ] || { printf 'pnpm ran without being asked\n' >&2; exit 1; }
PATH="$tmp/mock:$PATH" FM_CONFIG_OVERRIDE="$tmp/config" "$root/bin/fm-remote-verify.sh" "$tmp/tree" pnpm install --frozen-lockfile
[ "$(cat "$tmp/pnpm.log")" = 'install --frozen-lockfile' ]

# Arguments arrive verbatim and --env sets variables only when asked.
cat > "$tmp/tree/args.sh" <<'CHECK'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 3 ]
[ "$1" = 'a b' ]
[ "$2" = "\$(touch pwned)'\"" ]
[ "$3" = '*' ]
[ ! -e pwned ]
[ "${CUDA_VISIBLE_DEVICES-unset}" = "$EXPECT_CUDA" ]
CHECK
PATH="$tmp/mock:$PATH" FM_CONFIG_OVERRIDE="$tmp/config" "$root/bin/fm-remote-verify.sh" --env EXPECT_CUDA=unset "$tmp/tree" bash args.sh 'a b' "\$(touch pwned)'\"" '*'
PATH="$tmp/mock:$PATH" FM_CONFIG_OVERRIDE="$tmp/config" "$root/bin/fm-remote-verify.sh" --env CUDA_VISIBLE_DEVICES= --env EXPECT_CUDA= "$tmp/tree" bash args.sh 'a b' "\$(touch pwned)'\"" '*'
if PATH="$tmp/mock:$PATH" FM_CONFIG_OVERRIDE="$tmp/config" "$root/bin/fm-remote-verify.sh" --env 'BAD NAME=1' "$tmp/tree" true >"$tmp/out" 2>&1; then
  printf 'invalid --env succeeded\n' >&2; exit 1
fi
grep -q -- '--env needs NAME=VALUE' "$tmp/out"

# Committed .env files are repository content; untracked and ignored secrets stay local.
printf 'MODE=test\n' > "$tmp/tree/.env.test"
git -C "$tmp/tree" add .env.test
git -C "$tmp/tree" -c user.name=Test -c user.email=test@example.test commit -qm committed-env
printf 'ignored.key\n' > "$tmp/tree/.gitignore"
printf 'PRIVATE\n' > "$tmp/tree/ignored.key"
printf 'SECRET=local\n' > "$tmp/tree/.env.local"
printf 'SECRET=\n' > "$tmp/tree/.env.example"
cat > "$tmp/tree/secrets.sh" <<'CHECK'
#!/usr/bin/env bash
set -euo pipefail
[ -f .env.test ]
[ -z "$(git status --porcelain -- .env.test)" ]
[ "$(git log -1 --format=%s)" = committed-env ]
[ -f .env.example ]
[ ! -e .env ]
[ ! -e .env.local ]
[ ! -e ignored.key ]
CHECK
PATH="$tmp/mock:$PATH" FM_CONFIG_OVERRIDE="$tmp/config" "$root/bin/fm-remote-verify.sh" "$tmp/tree" bash secrets.sh

printf 'exit 7\n' > "$tmp/tree/fail.sh"
status=0
PATH="$tmp/mock:$PATH" FM_CONFIG_OVERRIDE="$tmp/config" "$root/bin/fm-remote-verify.sh" "$tmp/tree" bash fail.sh || status=$?
[ "$status" -eq 7 ] || { printf 'remote exit code %s was not propagated\n' "$status" >&2; exit 1; }
printf 'fm-remote-verify: passed\n'
