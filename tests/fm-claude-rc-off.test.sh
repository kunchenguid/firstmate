#!/usr/bin/env bash
# Exercise launch argument preservation and fail-closed process verification.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-claude-rc-off)
mkdir -p "$LAB/bin"
export RC_ARGS="$LAB/args.json" RC_INFO="$LAB/info.json" RC_CALL="$LAB/call.json"
cat > "$LAB/bin/claude" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  echo "${RC_VERSION:-2.1.263 (Claude Code)}"
else
  printf '%s\0' "$@" | jq -Rs 'split("\u0000")[:-1]' > "$RC_ARGS"
fi
SH
cat > "$LAB/bin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" | jq -Rs 'split("\u0000")[:-1]' > "$RC_CALL"
cat "$RC_INFO"
SH
chmod +x "$LAB/bin/claude" "$LAB/bin/herdr"
export PATH="$LAB/bin:$PATH"
HELPER="$ROOT/bin/fm-claude-rc-off.sh"

"$HELPER" launch --settings '{"feedbackDrafts":"off","disableRemoteControl":false}' --model 'a model' 'literal $(touch nope)'
jq -e '.[0] == "--settings" and (.[1] | fromjson | .disableRemoteControl == true and .feedbackDrafts == "off") and .[2:] == ["--model","a model","literal $(touch nope)"]' "$RC_ARGS" >/dev/null || fail 'launch lost settings or changed arguments'
pass 'launch enforces RC-off and preserves literal arguments'

printf '{"env":{"PRESERVE":"yes"},"disableRemoteControl":false}\n' > "$LAB/settings file.json"
"$HELPER" launch --settings "$LAB/settings file.json" -- --settings=prompt-text
jq -e '(.[1] | fromjson | .env.PRESERVE == "yes" and .disableRemoteControl == true) and .[2:] == ["--","--settings=prompt-text"]' "$RC_ARGS" >/dev/null || fail 'file settings or end-of-options not preserved'
"$HELPER" launch --settings='{"feedbackDrafts":"off"}' --settings '{"env":{"K":"V"}}'
jq -e '.[1] | fromjson | .feedbackDrafts == "off" and .env.K == "V" and .disableRemoteControl == true' "$RC_ARGS" >/dev/null || fail 'repeated settings not merged'
for version in '2.1.127 (Claude Code)' 'vendor changed banner'; do
  if RC_VERSION="$version" "$HELPER" launch >/dev/null 2>&1; then fail 'unsupported version accepted'; fi
done
if "$HELPER" launch --settings '{bad' >/dev/null 2>&1; then fail 'malformed settings accepted'; fi
if "$HELPER" launch --settings >/dev/null 2>&1; then fail 'missing settings value accepted'; fi
pass 'settings files, option boundaries, and refusal paths'

snapshot() {
  jq -n --argjson argv "$1" '{result:{process_info:{pane_id:"w1:p2",foreground_processes:[{pid:42,argv:$argv}]}}}' > "$RC_INFO"
}
snapshot '["/opt/bin/claude","--settings","{\"disableRemoteControl\":true}"]'
jq '.result.process_info.foreground_processes += [{pid:43,argv:[]},{pid:44}]' "$RC_INFO" > "$LAB/extra.json"
mv "$LAB/extra.json" "$RC_INFO"
"$HELPER" verify named w1:p2 | grep -q 'RC-off launch policy verified' || fail 'enforced live policy not verified'
jq -e '. == ["pane","process-info","--pane","w1:p2","--session","named"]' "$RC_CALL" >/dev/null || fail 'session scope lost'
for argv in \
  '["bash","--settings","{\"disableRemoteControl\":true}"]' \
  '["claude","--settings","{\"disableRemoteControl\":false}"]' \
  '["claude","--settings","/some/settings.json"]' \
  '["claude","--","--settings","{\"disableRemoteControl\":true}"]' \
  '["claude","--settings","{\"disableRemoteControl\":true}","--settings={\"disableRemoteControl\":false}"]'; do
  snapshot "$argv"
  if "$HELPER" verify named w1:p2 >/dev/null 2>&1; then fail "unsafe process accepted: $argv"; fi
done
snapshot '["claude","--settings={\"disableRemoteControl\":true}"]'
if "$HELPER" verify named w1:p3 >/dev/null 2>&1; then fail 'wrong pane accepted'; fi
jq '.result.process_info.foreground_processes |= (. + .)' "$RC_INFO" > "$LAB/two.json"
mv "$LAB/two.json" "$RC_INFO"
if "$HELPER" verify named w1:p2 >/dev/null 2>&1; then fail 'ambiguous Claude processes accepted'; fi
printf '{}\n' > "$RC_INFO"
if "$HELPER" verify named w1:p2 >/dev/null 2>&1; then fail 'empty response accepted'; fi
pass 'verification rejects missing, ambiguous, stale, and unprotected process state'
