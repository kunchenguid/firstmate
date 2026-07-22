#!/usr/bin/env bash
# Provider-outage supervision regression for bin/fm-watch.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export FM_HOME="$TMP/home"
export FM_STATE_OVERRIDE="$FM_HOME/state"
mkdir -p "$FM_STATE_OVERRIDE"

# shellcheck source=bin/fm-watch.sh
. "$ROOT/bin/fm-watch.sh"

fail() { echo "not ok - $1"; exit 1; }
pass() { echo "ok - $1"; }

fm_wake_append() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$TMP/wake"; }
mark_surfaced() { :; }
triage_log() { :; }
wake() { printf '%s\n' "$1" > "$TMP/surfaced"; }

cat > "$FM_STATE_OVERRIDE/t1.meta" <<'EOF'
harness=codex
model=gpt-5.6-sol
EOF

provider_outage_scan 'tmux:%1' t1 'usage limit exceeded retry in 10 seconds' '' 'tmux__1'
grep -q 'provider-outage' "$TMP/surfaced" || fail "verified outage did not surface immediately"
[ -f "$FM_STATE_OVERRIDE/.provider-outage-tmux__1" ] || fail "outage dedupe marker missing"
pass "OpenAI outage evidence surfaces before stale triage"

: > "$TMP/surfaced"
provider_outage_scan 'tmux:%1' t1 'usage limit exceeded retry in 20 seconds' '' 'tmux__1'
[ ! -s "$TMP/surfaced" ] || fail "normalized duplicate outage surfaced twice"
pass "provider outage evidence is deduplicated"

cat > "$FM_STATE_OVERRIDE/t1.meta" <<'EOF'
harness=claude
model=claude-fable-5
EOF
provider_outage_scan 'tmux:%1' t1 'usage limit exceeded' '' 'tmux__1'
[ ! -e "$FM_STATE_OVERRIDE/.provider-outage-tmux__1" ] || fail "outage marker survived route change"
pass "route change clears provider outage state"

pass "all fm-watch provider-outage tests passed"
