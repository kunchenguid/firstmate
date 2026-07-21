#!/usr/bin/env bash
# Tests for bin/fm-tool-versions.sh: read-only fleet tool inventory, version
# classification, and exit codes with network/nix/agentic probes mocked via PATH
# and FM_TOOL_VERSIONS_* overrides.
#
# Guarantees under test:
#   - --help exits 0; unknown options exit 2
#   - never mutates the system (no writes under a fixture root)
#   - installed-only mode reports installed versions without network
#   - classification: current / behind / ahead / unknown / error
#   - exit 0 when all current or soft-unknown
#   - exit 1 when any harness row is behind
#   - exit 3 when a required upstream probe fails (partial offline)
#   - agentic section invokes the dotfiles check script when present
#   - locked nixpkgs versions come from flake.lock rev + nix eval (mocked)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-tool-versions.sh"
TMP_ROOT=$(fm_test_tmproot fm-tool-versions)

assert_present "$TOOL" "bin/fm-tool-versions.sh is missing"
[ -x "$TOOL" ] || fail "bin/fm-tool-versions.sh must be executable"

# --- fixtures ---------------------------------------------------------------

# Write a minimal fake harness CLI that prints a fixed --version line.
fake_tool_version() {
  local fakebin=$1 name=$2 version_line=$3
  cat > "$fakebin/$name" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ] || [ "\${1:-}" = "-V" ]; then
  printf '%s\n' '$version_line'
  exit 0
fi
printf 'fake %s: unexpected args\n' '$name' >&2
exit 1
SH
  chmod +x "$fakebin/$name"
}

# npm stub: only supports "view @anthropic-ai/claude-code version"
write_npm_stub() {
  local path=$1 claude_ver=$2 mode=${3:-ok}
  cat > "$path" <<SH
#!/usr/bin/env bash
if [ "\$1" = "view" ] && [ "\$2" = "@anthropic-ai/claude-code" ] && [ "\$3" = "version" ]; then
  if [ "$mode" = fail ]; then
    exit 1
  fi
  printf '%s\n' '$claude_ver'
  exit 0
fi
printf 'npm stub: unexpected: %s\n' "\$*" >&2
exit 1
SH
  chmod +x "$path"
}

# gh stub: supports api repos/<owner>/<repo>/releases --jq ...
# VERSION map is encoded as lines owner/repo=version in a companion file.
write_gh_stub() {
  local path=$1 mapfile=$2 mode=${3:-ok}
  cat > "$path" <<SH
#!/usr/bin/env bash
if [ "\$1" != "api" ]; then
  printf 'gh stub: only api supported\n' >&2
  exit 1
fi
repo=\$2
# strip leading path noise; expect repos/owner/repo/releases
repo=\${repo#repos/}
repo=\${repo%/releases}
if [ "$mode" = fail ]; then
  exit 1
fi
ver=\$(grep -F "\$repo=" "$mapfile" | head -1 | cut -d= -f2-)
if [ -z "\$ver" ]; then
  # empty release list -> empty jq result
  exit 0
fi
# Emit a tag that normalize_version can parse (codex uses rust-v prefix upstream).
case "\$repo" in
  openai/codex) printf 'rust-v%s\n' "\$ver" ;;
  *) printf 'v%s\n' "\$ver" ;;
esac
exit 0
SH
  chmod +x "$path"
}

# nix stub: github:NixOS/nixpkgs/<rev>#<pkg>.version
write_nix_stub() {
  local path=$1 mapfile=$2 mode=${3:-ok}
  cat > "$path" <<SH
#!/usr/bin/env bash
if [ "$mode" = fail ]; then
  exit 1
fi
# Find the github:NixOS/nixpkgs/...#pkg.version arg
arg=""
for a in "\$@"; do
  case "\$a" in
    github:NixOS/nixpkgs/*#*.version) arg=\$a ;;
  esac
done
if [ -z "\$arg" ]; then
  printf 'nix stub: no eval target\n' >&2
  exit 1
fi
pkg=\${arg##*#}
pkg=\${pkg%.version}
ver=\$(grep -F "\$pkg=" "$mapfile" | head -1 | cut -d= -f2-)
if [ -z "\$ver" ]; then
  exit 1
fi
printf '%s\n' "\$ver"
exit 0
SH
  chmod +x "$path"
}

# Minimal dotfiles fixture with flake.lock nixpkgs rev and optional agentic check.
make_dotfiles() {
  local dir=$1 rev=${2:-abc123def456}
  mkdir -p "$dir/scripts"
  cat > "$dir/flake.nix" <<'NIX'
{
  description = "fixture";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { ... }: { };
}
NIX
  cat > "$dir/flake.lock" <<LOCK
{
  "nodes": {
    "nixpkgs": {
      "locked": {
        "lastModified": 1,
        "narHash": "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "owner": "NixOS",
        "repo": "nixpkgs",
        "rev": "$rev",
        "type": "github"
      },
      "original": {
        "owner": "NixOS",
        "ref": "nixos-unstable",
        "repo": "nixpkgs",
        "type": "github"
      }
    },
    "root": {
      "inputs": {
        "nixpkgs": "nixpkgs"
      }
    }
  },
  "root": "root",
  "version": 7
}
LOCK
}

# Common PATH of fake harness binaries at fixed "installed" versions.
setup_fake_harness() {
  local fakebin=$1
  # Optional overrides: claude_ver codex_ver ...
  local claude_ver=${2:-2.1.214}
  local codex_ver=${3:-0.144.4}
  local grok_ver=${4:-0.2.93}
  local opencode_ver=${5:-1.18.3}
  local pi_ver=${6:-0.80.10}
  local nm_ver=${7:-1.40.1}
  fake_tool_version "$fakebin" claude "$claude_ver (Claude Code)"
  fake_tool_version "$fakebin" codex "codex-cli $codex_ver"
  fake_tool_version "$fakebin" grok "grok $grok_ver (deadbeef) [stable]"
  fake_tool_version "$fakebin" opencode "$opencode_ver"
  fake_tool_version "$fakebin" pi "$pi_ver"
  fake_tool_version "$fakebin" no-mistakes "no-mistakes version $nm_ver (abc) 2026-01-01T00:00:00Z"
}

run_tool() {
  # Usage: run_tool <fakebin> <npm> <gh> <nix> <dotfiles> -- script args...
  local fakebin=$1 npm=$2 gh=$3 nix=$4 dotfiles=$5
  shift 5
  env -u FM_DOTFILES \
    PATH="$fakebin:$PATH" \
    FM_HOME="$TMP_ROOT/home-empty" \
    FM_TOOL_VERSIONS_NPM="$npm" \
    FM_TOOL_VERSIONS_GH="$gh" \
    FM_TOOL_VERSIONS_NIX="$nix" \
    "$TOOL" --dotfiles "$dotfiles" "$@"
}

# --- tests ------------------------------------------------------------------

test_help_and_usage() {
  local out ec
  out=$("$TOOL" --help 2>&1) || true
  assert_contains "$out" "Read-only inventory" "help should print ownership header"
  assert_contains "$out" "Exit codes" "help should document exit codes"
  set +e
  out=$("$TOOL" --not-a-flag 2>&1)
  ec=$?
  set -e
  expect_code 2 "$ec" "unknown option"
  set +e
  out=$("$TOOL" --json 2>&1)
  ec=$?
  set -e
  expect_code 2 "$ec" "unimplemented --json"
  pass "help exits 0; bad usage exits 2"
}

test_installed_only_exit_0_soft_unknown() {
  local w fakebin out ec
  w="$TMP_ROOT/installed-only"
  mkdir -p "$w"
  fakebin=$(fm_fakebin "$w")
  setup_fake_harness "$fakebin"
  set +e
  out=$(PATH="$fakebin:$PATH" FM_HOME="$w/nohome" "$TOOL" --installed-only 2>&1)
  ec=$?
  set -e
  expect_code 0 "$ec" "installed-only with soft unknown tips"
  assert_contains "$out" "claude" "lists claude"
  assert_contains "$out" "2.1.214" "prints installed claude version"
  assert_contains "$out" "0.144.4" "prints installed codex version"
  assert_contains "$out" "(skipped)" "upstream skipped without network"
  assert_contains "$out" "unknown" "status soft-unknown without tip"
  pass "installed-only reports versions and exits 0"
}

test_behind_exit_1() {
  local w fakebin npm gh nix map_gh map_nix out ec df
  w="$TMP_ROOT/behind"
  mkdir -p "$w"
  fakebin=$(fm_fakebin "$w")
  setup_fake_harness "$fakebin" 2.1.214 0.144.4 0.2.93 1.18.3 0.80.10 1.40.1
  df="$w/dotfiles"
  make_dotfiles "$df" deadbeef01
  # agentic check: all current so harness behind drives exit 1 alone
  cat > "$df/scripts/agentic-tools-check-updates.sh" <<'SH'
#!/usr/bin/env bash
printf 'All checked agentic pins are current.\n'
exit 0
SH
  chmod +x "$df/scripts/agentic-tools-check-updates.sh"

  npm="$w/npm"
  gh="$w/gh"
  nix="$w/nix"
  map_gh="$w/gh.map"
  map_nix="$w/nix.map"
  # Upstream newer than installed for claude/codex/opencode
  printf 'openai/codex=0.144.6\nanomalyco/opencode=1.18.4\nbadlogic/pi-mono=0.80.10\n' > "$map_gh"
  printf '%s\n' \
    'claude-code=2.1.214' \
    'codex=0.144.4' \
    'opencode=1.18.3' \
    'pi-coding-agent=0.80.10' \
    'grok-build=0.2.93' > "$map_nix"
  write_npm_stub "$npm" 2.1.216
  write_gh_stub "$gh" "$map_gh"
  write_nix_stub "$nix" "$map_nix"

  set +e
  out=$(run_tool "$fakebin" "$npm" "$gh" "$nix" "$df" 2>&1)
  ec=$?
  set -e
  expect_code 1 "$ec" "behind tools must exit 1"
  assert_contains "$out" "behind" "status behind present"
  assert_contains "$out" "2.1.216" "upstream claude tip"
  assert_contains "$out" "0.144.6" "upstream codex tip"
  assert_contains "$out" "1.18.4" "upstream opencode tip"
  # Ensure we did not claim all current
  assert_not_contains "$out" "All compared tools are current" "must not claim all current when behind"
  pass "behind harness rows exit 1 and show tips"
}

test_current_exit_0() {
  local w fakebin npm gh nix map_gh map_nix out ec df
  w="$TMP_ROOT/current"
  mkdir -p "$w"
  fakebin=$(fm_fakebin "$w")
  setup_fake_harness "$fakebin" 2.1.216 0.144.6 0.2.93 1.18.4 0.80.10 1.40.1
  df="$w/dotfiles"
  make_dotfiles "$df"
  cat > "$df/scripts/agentic-tools-check-updates.sh" <<'SH'
#!/usr/bin/env bash
printf 'All checked agentic pins are current.\n'
exit 0
SH
  chmod +x "$df/scripts/agentic-tools-check-updates.sh"
  npm="$w/npm"; gh="$w/gh"; nix="$w/nix"
  map_gh="$w/gh.map"; map_nix="$w/nix.map"
  printf 'openai/codex=0.144.6\nanomalyco/opencode=1.18.4\nbadlogic/pi-mono=0.80.10\n' > "$map_gh"
  printf '%s\n' \
    'claude-code=2.1.216' \
    'codex=0.144.6' \
    'opencode=1.18.4' \
    'pi-coding-agent=0.80.10' \
    'grok-build=0.2.93' > "$map_nix"
  write_npm_stub "$npm" 2.1.216
  write_gh_stub "$gh" "$map_gh"
  write_nix_stub "$nix" "$map_nix"
  set +e
  out=$(run_tool "$fakebin" "$npm" "$gh" "$nix" "$df" 2>&1)
  ec=$?
  set -e
  expect_code 0 "$ec" "all current exits 0"
  assert_contains "$out" "current" "status current present"
  assert_not_contains "$out" $'\tbehind' "no tab-behind"
  # STATUS column word behind should not appear as a status when all current;
  # summary may still say behind=0
  assert_contains "$out" "behind=0" "summary behind=0"
  pass "matching installed and upstream exits 0"
}

test_upstream_error_exit_3() {
  local w fakebin npm gh nix map_gh map_nix out ec df
  w="$TMP_ROOT/offline"
  mkdir -p "$w"
  fakebin=$(fm_fakebin "$w")
  setup_fake_harness "$fakebin"
  df="$w/dotfiles"
  make_dotfiles "$df"
  cat > "$df/scripts/agentic-tools-check-updates.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$df/scripts/agentic-tools-check-updates.sh"
  npm="$w/npm"; gh="$w/gh"; nix="$w/nix"
  map_gh="$w/gh.map"; map_nix="$w/nix.map"
  printf 'openai/codex=0.144.6\n' > "$map_gh"
  printf '%s\n' \
    'claude-code=2.1.214' \
    'codex=0.144.4' \
    'opencode=1.18.3' \
    'pi-coding-agent=0.80.10' \
    'grok-build=0.2.93' > "$map_nix"
  write_npm_stub "$npm" 2.1.216 fail
  write_gh_stub "$gh" "$map_gh" fail
  write_nix_stub "$nix" "$map_nix"
  set +e
  out=$(run_tool "$fakebin" "$npm" "$gh" "$nix" "$df" 2>&1)
  ec=$?
  set -e
  expect_code 3 "$ec" "unreachable upstream probes exit 3"
  assert_contains "$out" "error" "error status for failed probes"
  assert_contains "$out" "(unreachable)" "unreachable marker"
  pass "partial offline upstream probes exit 3"
}

test_agentic_behind_counts() {
  local w fakebin npm gh nix map_gh map_nix out ec df
  w="$TMP_ROOT/agentic-behind"
  mkdir -p "$w"
  fakebin=$(fm_fakebin "$w")
  # Installed matches upstream so only agentic drives exit 1
  setup_fake_harness "$fakebin" 2.1.216 0.144.6 0.2.93 1.18.4 0.80.10 1.40.1
  df="$w/dotfiles"
  make_dotfiles "$df"
  cat > "$df/scripts/agentic-tools-check-updates.sh" <<'SH'
#!/usr/bin/env bash
printf 'no-mistakes  v1.40.1  v1.40.2  update-available\n'
printf '1 tool(s) behind upstream.\n'
exit 1
SH
  chmod +x "$df/scripts/agentic-tools-check-updates.sh"
  npm="$w/npm"; gh="$w/gh"; nix="$w/nix"
  map_gh="$w/gh.map"; map_nix="$w/nix.map"
  printf 'openai/codex=0.144.6\nanomalyco/opencode=1.18.4\nbadlogic/pi-mono=0.80.10\n' > "$map_gh"
  printf '%s\n' \
    'claude-code=2.1.216' \
    'codex=0.144.6' \
    'opencode=1.18.4' \
    'pi-coding-agent=0.80.10' \
    'grok-build=0.2.93' > "$map_nix"
  write_npm_stub "$npm" 2.1.216
  write_gh_stub "$gh" "$map_gh"
  write_nix_stub "$nix" "$map_nix"
  set +e
  out=$(run_tool "$fakebin" "$npm" "$gh" "$nix" "$df" 2>&1)
  ec=$?
  set -e
  expect_code 1 "$ec" "agentic behind exits 1"
  assert_contains "$out" "Agentic pins" "agentic section header"
  assert_contains "$out" "update-available" "relays agentic output"
  pass "agentic check behind folds into exit 1"
}

test_agentic_error_takes_precedence() {
  local w fakebin npm gh nix map_gh map_nix out ec df
  w="$TMP_ROOT/agentic-err"
  mkdir -p "$w"
  fakebin=$(fm_fakebin "$w")
  setup_fake_harness "$fakebin" 2.1.214 0.144.4 0.2.93 1.18.3 0.80.10 1.40.1
  df="$w/dotfiles"
  make_dotfiles "$df"
  cat > "$df/scripts/agentic-tools-check-updates.sh" <<'SH'
#!/usr/bin/env bash
printf 'firstmate  (unreachable)  error\n'
exit 3
SH
  chmod +x "$df/scripts/agentic-tools-check-updates.sh"
  npm="$w/npm"; gh="$w/gh"; nix="$w/nix"
  map_gh="$w/gh.map"; map_nix="$w/nix.map"
  # Also behind so we can prove 3 wins over 1
  printf 'openai/codex=0.144.6\nanomalyco/opencode=1.18.4\nbadlogic/pi-mono=0.80.10\n' > "$map_gh"
  printf '%s\n' \
    'claude-code=2.1.214' \
    'codex=0.144.4' \
    'opencode=1.18.3' \
    'pi-coding-agent=0.80.10' \
    'grok-build=0.2.93' > "$map_nix"
  write_npm_stub "$npm" 2.1.216
  write_gh_stub "$gh" "$map_gh"
  write_nix_stub "$nix" "$map_nix"
  set +e
  out=$(run_tool "$fakebin" "$npm" "$gh" "$nix" "$df" 2>&1)
  ec=$?
  set -e
  expect_code 3 "$ec" "agentic error exit 3 beats harness behind"
  pass "exit 3 takes precedence over behind"
}

test_ahead_status() {
  local w fakebin npm gh nix map_gh map_nix out ec df
  w="$TMP_ROOT/ahead"
  mkdir -p "$w"
  fakebin=$(fm_fakebin "$w")
  setup_fake_harness "$fakebin" 2.1.300 0.144.6 0.2.93 1.18.4 0.80.10 1.40.1
  df="$w/dotfiles"
  make_dotfiles "$df"
  cat > "$df/scripts/agentic-tools-check-updates.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$df/scripts/agentic-tools-check-updates.sh"
  npm="$w/npm"; gh="$w/gh"; nix="$w/nix"
  map_gh="$w/gh.map"; map_nix="$w/nix.map"
  printf 'openai/codex=0.144.6\nanomalyco/opencode=1.18.4\nbadlogic/pi-mono=0.80.10\n' > "$map_gh"
  printf '%s\n' \
    'claude-code=2.1.216' \
    'codex=0.144.6' \
    'opencode=1.18.4' \
    'pi-coding-agent=0.80.10' \
    'grok-build=0.2.93' > "$map_nix"
  write_npm_stub "$npm" 2.1.216
  write_gh_stub "$gh" "$map_gh"
  write_nix_stub "$nix" "$map_nix"
  set +e
  out=$(run_tool "$fakebin" "$npm" "$gh" "$nix" "$df" 2>&1)
  ec=$?
  set -e
  expect_code 0 "$ec" "ahead is not behind"
  assert_contains "$out" "ahead" "status ahead for newer installed claude"
  pass "installed newer than tip classifies ahead"
}

test_no_mutation() {
  local w fakebin df stamp
  w="$TMP_ROOT/nomut"
  mkdir -p "$w"
  fakebin=$(fm_fakebin "$w")
  setup_fake_harness "$fakebin"
  df="$w/dotfiles"
  make_dotfiles "$df"
  cat > "$df/scripts/agentic-tools-check-updates.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$df/scripts/agentic-tools-check-updates.sh"
  stamp=$(find "$df" -type f -print0 | sort -z | xargs -0 sha256sum)
  PATH="$fakebin:$PATH" FM_HOME="$w" \
    FM_TOOL_VERSIONS_NPM=/bin/false \
    FM_TOOL_VERSIONS_GH=/bin/false \
    FM_TOOL_VERSIONS_NIX=/bin/false \
    "$TOOL" --dotfiles "$df" --no-network --skip-nix >/dev/null 2>&1 || true
  [ "$(find "$df" -type f -print0 | sort -z | xargs -0 sha256sum)" = "$stamp" ] \
    || fail "dotfiles fixture files mutated"
  pass "read-only: fixture files unchanged"
}

test_skill_and_agents_trigger() {
  local skill="$ROOT/.agents/skills/update-tools/SKILL.md"
  assert_present "$skill" "update-tools skill missing"
  assert_grep "name: update-tools" "$skill" "skill name"
  assert_grep "user-invocable: true" "$skill" "skill must be captain-invocable"
  assert_grep "  internal: true" "$skill" "skill must be internal"
  assert_grep "/update-tools" "$skill" "slash form"
  assert_grep "bin/fm-tool-versions.sh" "$skill" "inventory script pointer"
  assert_grep "updatefirstmate" "$skill" "cross-link firstmate updater"
  assert_grep "agentic-tools-bump" "$skill" "agentic bump pointer"
  assert_grep "nixpkgs" "$skill" "nixpkgs harness ownership"
  assert_grep "When the captain invokes \`/update-tools\`" "$ROOT/AGENTS.md" \
    "AGENTS.md must load update-tools on captain language"
  assert_grep '/update-tools' "$ROOT/README.md" "README skills table lists update-tools"
  assert_grep 'nixpkgs-owned' "$ROOT/CONTRIBUTING.md" "CONTRIBUTING notes harness ownership"
  pass "skill metadata, AGENTS trigger, README, CONTRIBUTING wired"
}

# --- run --------------------------------------------------------------------

test_help_and_usage
test_installed_only_exit_0_soft_unknown
test_behind_exit_1
test_current_exit_0
test_upstream_error_exit_3
test_agentic_behind_counts
test_agentic_error_takes_precedence
test_ahead_status
test_no_mutation
test_skill_and_agents_trigger

printf 'All fm-tool-versions tests passed.\n'
