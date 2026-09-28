#!/usr/bin/env bash
# Credentialed behavior regression for the agent-owned profile-array-dispatch skill.
#
# This drives the public Pi skill-loading interface and puts a refusing
# quota-axi executable on PATH.
# Selection must use the supplied task-fit, model, authentication, and runtime
# evidence without consulting quota or silently falling through a refusal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PROFILE_ARRAY_DISPATCH_LIVE_E2E pi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER="$ROOT/.agents/skills/profile-array-dispatch/SKILL.md"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v pi >/dev/null 2>&1 || fail "pi not found"
[ -f "$OWNER" ] || fail "profile-array-dispatch skill not found"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-profile-array-dispatch-live.XXXXXX")
PROJECT="$LAB/project"
FAKEBIN="$LAB/fakebin"
CALLS="$LAB/quota-axi.calls"

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$PROJECT/.agents/skills/profile-array-dispatch" "$FAKEBIN"
cp "$OWNER" "$PROJECT/.agents/skills/profile-array-dispatch/SKILL.md"
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${QUOTA_AXI_CALLS:?}"
printf 'quota-axi must not be called\n' >&2
exit 97
SH
chmod +x "$FAKEBIN/quota-axi"

run_case() {
  local label=$1 expected=$2 prompt=$3 out
  : > "$CALLS"
  out=$(
    cd "$PROJECT" &&
      PATH="$FAKEBIN:$PATH" QUOTA_AXI_CALLS="$CALLS" \
        pi --print --approve --no-session --no-context-files --no-extensions \
          --no-skills --skill .agents/skills --tools bash \
          --model openai-codex/gpt-5.6-sol --thinking high \
          "$prompt"
  ) || fail "$label: Pi skill run failed: $out"
  [ ! -s "$CALLS" ] || fail "$label: quota-axi was invoked: $(cat "$CALLS")"
  printf '%s\n' "$out" | grep -Fxq "$expected" \
    || fail "$label: expected final line $expected, got: $out"
  printf 'ok - %s\n' "$label"
}

run_case \
  "configured order chooses the first verified task-fit profile" \
  "SELECTED=TraeX/gpt-5.6-sol/high" \
  "Load profile-array-dispatch and resolve this ordered array: TraeX/gpt-5.6-sol/high, then Codex/gpt-5.6-sol/high. Both meet the required task fit and reasoning class. Current authoritative account-reaching catalog and authentication checks prove both configured models supported and both selected authentication surfaces usable. The Herdr runtime supports both harnesses and both effort values. Return exactly one final line SELECTED=<profile>. Do not run any commands or modify files."

run_case \
  "task fit excludes an earlier profile before configured-order selection" \
  "SELECTED=Codex/gpt-5.6-sol/xhigh" \
  "Load profile-array-dispatch and resolve this ordered array: Pi/default/low, then Codex/gpt-5.6-sol/xhigh. The task requires the strongest available reasoning class, so Pi/default/low does not meet task fit. Current authoritative account-reaching catalog and authentication checks prove Codex/gpt-5.6-sol supported and its selected authentication surface usable. The runtime supports Codex and xhigh. Return exactly one final line SELECTED=<profile>. Do not run any commands or modify files."

run_case \
  "unavailable authentication is reported concretely" \
  "REFUSED=TraeX/gpt-5.6-sol/high|reason=authentication-unavailable" \
  "Load profile-array-dispatch and resolve this one-profile ordered array: TraeX/gpt-5.6-sol/high. It meets task fit and its model is catalog-supported, but the authoritative TraeX login check reports that the selected credential is unavailable. Return exactly one final line REFUSED=TraeX/gpt-5.6-sol/high|reason=authentication-unavailable. Do not run any commands or modify files."

run_case \
  "runtime incompatibility is reported concretely" \
  "REFUSED=Codex/gpt-5.6-sol/high|reason=runtime-incompatible" \
  "Load profile-array-dispatch and resolve this one-profile ordered array: Codex/gpt-5.6-sol/high. It meets task fit, its model is catalog-supported, and its selected authentication is usable, but the resolved runtime backend cannot launch Codex. Return exactly one final line REFUSED=Codex/gpt-5.6-sol/high|reason=runtime-incompatible. Do not run any commands or modify files."

run_case \
  "selected provider refusal is reported without fallback" \
  "DECISION=REFUSE" \
  "Load profile-array-dispatch and handle this post-selection launch result. The ordered array was TraeX/gpt-5.6-sol/high, then Codex/gpt-5.6-sol/high. Both met task fit, both models were catalog-supported, and both selected authentication surfaces passed verification. TraeX was selected and its actual launch was attempted, but the provider refused it. No new Firstmate selection has been made. Return exactly one final line DECISION=<REFUSE|CODEX>. Do not run any commands or modify files."

printf '# all profile-array-dispatch live behavior tests passed\n'
