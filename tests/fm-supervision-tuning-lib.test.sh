#!/usr/bin/env bash
# Unit test for bin/fm-supervision-tuning-lib.sh: the home-local supervision
# tuning loader.
#
# The contract: KEY=VALUE, integers only, unknown keys ignored, nothing is
# evaluated as shell, an environment variable of the same name always wins, and
# an absent file leaves every knob at the shipped default.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/bin/fm-supervision-tuning-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

# shellcheck source=/dev/null
. "$LIB"

# 1. An absent file changes nothing.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
FM_HOME="$tmp" FM_CONFIG_OVERRIDE="$tmp/config"
FM_WEDGE_MAX_ESCALATIONS='' FM_ESCALATE_BATCH_SECS='' FM_IDLE_POLL='' FM_STALE_ESCALATE_SECS='' FM_MAX_FIX_ROUNDS=''
mkdir -p "$tmp/config"
fm_supervision_tuning_load
[ -z "${FM_WEDGE_MAX_ESCALATIONS:-}" ] || fail "absent file set FM_WEDGE_MAX_ESCALATIONS"
ok "absent file leaves every knob unset"

# 2. A well-formed file sets the named knobs.
cat > "$tmp/config/supervision-tuning" <<'EOF'
# a comment line
wedge_max_escalations=2
escalate_batch_secs=180
idle_poll_secs=300
stale_escalate_secs=240
max_fix_rounds=2
EOF
fm_supervision_tuning_load
[ "$FM_WEDGE_MAX_ESCALATIONS" = 2 ] || fail "wedge_max_escalations not set: $FM_WEDGE_MAX_ESCALATIONS"
[ "$FM_ESCALATE_BATCH_SECS" = 180 ] || fail "escalate_batch_secs not set"
[ "$FM_IDLE_POLL" = 300 ] || fail "idle_poll_secs not set"
[ "$FM_STALE_ESCALATE_SECS" = 240 ] || fail "stale_escalate_secs not set"
[ "$FM_MAX_FIX_ROUNDS" = 2 ] || fail "max_fix_rounds not set"
ok "a well-formed file sets every named knob"

# 3. An environment variable wins over the file.
FM_IDLE_POLL=42
fm_supervision_tuning_load
[ "$FM_IDLE_POLL" = 42 ] || fail "the file overrode the environment: $FM_IDLE_POLL"
FM_IDLE_POLL=''
ok "an environment variable wins over the file"

# 4. A non-numeric value is ignored, and an unknown key is ignored.
cat > "$tmp/config/supervision-tuning" <<'EOF'
idle_poll_secs=not-a-number
wedge_max_escalations=; rm -rf /
unknown_key=5
EOF
FM_IDLE_POLL='' FM_WEDGE_MAX_ESCALATIONS='' FM_MAX_FIX_ROUNDS=''
fm_supervision_tuning_load
[ -z "${FM_IDLE_POLL:-}" ] || fail "a non-numeric value was accepted: $FM_IDLE_POLL"
[ -z "${FM_WEDGE_MAX_ESCALATIONS:-}" ] || fail "an empty value was accepted"
[ -z "${FM_MAX_FIX_ROUNDS:-}" ] || fail "an unknown key leaked into another knob"
ok "a non-numeric value, an empty value and an unknown key are all ignored"

# 5. The validator falls back for anything that is not a digit string.
[ "$(fm_supervision_tuning_int "" 2)" = 2 ] || fail "empty value did not fall back"
[ "$(fm_supervision_tuning_int "12x" 2)" = 2 ] || fail "a non-digit value did not fall back"
[ "$(fm_supervision_tuning_int 7 2)" = 7 ] || fail "a valid value was not returned"
ok "the integer validator falls back for a non-digit value"

# 6. The loader never evaluates the file as shell.
marker="$tmp/evaluated"
cat > "$tmp/config/supervision-tuning" <<EOF
idle_poll_secs=\$(touch $marker)
EOF
FM_IDLE_POLL=''
fm_supervision_tuning_load
[ ! -e "$marker" ] || fail "the tuning file was evaluated as shell"
[ -z "${FM_IDLE_POLL:-}" ] || fail "a command substitution was accepted as a value"
ok "the file is never evaluated as shell"

echo "PASS: fm-supervision-tuning-lib"
