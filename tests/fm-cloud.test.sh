#!/usr/bin/env bash
# Behavior tests for the cloud-kick bridge (holen, annahme, senden).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ANNAHME="$ROOT/bin/fm-cloud-annahme.sh"
HOLEN="$ROOT/bin/fm-cloud-holen.sh"
SENDEN="$ROOT/bin/fm-cloud-senden.sh"
TMP_ROOT=$(fm_test_tmproot fm-cloud)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

write_bruecke() {
  local home=$1
  cat > "$home/state/bruecke.env" <<'ENV'
BRUECKE_KICK=test-kick-topic
BRUECKE_BERICHT=test-bericht-topic
ENV
}

write_kick() {
  printf '%s\n' "$2" > "$1/state/cloud-kick.md"
}

kick_hash() {
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$ROOT/bin/fm-cloud-lib.sh" >/dev/null 2>&1 || true
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1/state/cloud-kick.md" | awk '{print $1}'
  else
    sha256sum "$1/state/cloud-kick.md" | awk '{print $1}'
  fi
}

wake_payloads() {
  awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null
}

test_annahme_silent_without_bridge() {
  local home
  home=$(make_home no-bridge)
  write_kick "$home" 'Neuer Auftrag'
  FM_HOME="$home" "$ANNAHME" >/dev/null
  [ ! -f "$home/state/.wake-queue" ] \
    || fail 'annahme without bruecke.env must not enqueue a wake'
  pass 'cloud: annahme stays silent when the bridge is not configured'
}

test_annahme_silent_when_kick_unchanged() {
  local home hash
  home=$(make_home unchanged)
  write_bruecke "$home"
  write_kick "$home" 'Gleicher Kick'
  hash=$(kick_hash "$home")
  printf '%s\n' "$hash" > "$home/state/cloud-kick.done"
  FM_HOME="$home" "$ANNAHME" >/dev/null
  [ ! -f "$home/state/.wake-queue" ] \
    || fail 'unchanged kick must not enqueue a wake'
  pass 'cloud: annahme ignores an already accepted kick'
}

test_annahme_queues_wake_for_new_kick() {
  local home out hash
  home=$(make_home fresh)
  write_bruecke "$home"
  write_kick "$home" 'Frischer Cloud-Kick'
  out=$(FM_HOME="$home" "$ANNAHME")
  assert_contains "$out" 'cloud-kick angenommen' 'annahme should confirm acceptance'
  assert_present "$home/state/.wake-queue" 'new kick must enqueue a wake'
  assert_contains "$(wake_payloads "$home")" 'check: cloud-kick neu' \
    'wake payload must name the cloud kick'
  hash=$(kick_hash "$home")
  assert_grep "$hash" "$home/state/cloud-kick.done" \
    'done marker must record the accepted hash'
  pass 'cloud: annahme queues one check wake for a new kick'
}

test_annahme_idempotent_after_done() {
  local home
  home=$(make_home idempotent)
  write_bruecke "$home"
  write_kick "$home" 'Einmaliger Kick'
  FM_HOME="$home" "$ANNAHME" >/dev/null
  FM_HOME="$home" "$ANNAHME" >/dev/null
  count=$(wc -l < "$home/state/.wake-queue" | tr -d ' ')
  [ "$count" = 1 ] || fail "expected one wake row, got $count"
  pass 'cloud: annahme does not re-announce an already accepted kick'
}

test_holen_writes_kick_and_announces() {
  local home fakebin curl_log
  home=$(make_home holen)
  write_bruecke "$home"
  fakebin="$TMP_ROOT/fakebin"
  mkdir -p "$fakebin"
  curl_log="$TMP_ROOT/holen-curl.log"
  cat > "$fakebin/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' '{"event":"message","message":"Kick aus der Wolke"}' | tee -a '$curl_log'
exit 0
SH
  chmod +x "$fakebin/curl"
  PATH="$fakebin:$PATH" FM_HOME="$home" "$HOLEN" once >/dev/null
  assert_grep 'Kick aus der Wolke' "$home/state/cloud-kick.md" \
    'holen must write the polled message'
  assert_contains "$(wake_payloads "$home")" 'check: cloud-kick neu' \
    'holen must announce through annahme'
  pass 'cloud: holen writes a kick and accepts it immediately'
}

test_senden_posts_bericht() {
  local home fakebin body_log
  home=$(make_home senden)
  write_bruecke "$home"
  printf '%s\n' 'Erster Satz.' > "$home/state/cloud-bericht.md"
  printf '%s\n' 'Zweiter Satz.' >> "$home/state/cloud-bericht.md"
  fakebin="$TMP_ROOT/sendbin"
  mkdir -p "$fakebin"
  body_log="$TMP_ROOT/senden-body.log"
  cat > "$fakebin/curl" <<SH
#!/usr/bin/env bash
while [ \$# -gt 0 ]; do
  case "\$1" in
    -d) printf '%s' "\$2" > '$body_log'; shift 2 ;;
    *) shift ;;
  esac
done
printf 'ok\n'
exit 0
SH
  chmod +x "$fakebin/curl"
  BODY_LOG="$body_log" PATH="$fakebin:$PATH" FM_HOME="$home" "$SENDEN" >/dev/null
  assert_grep 'Erster Satz.' "$body_log" 'senden must post the bericht body'
  assert_grep 'Zweiter Satz.' "$body_log" 'senden must post the full bericht'
  pass 'cloud: senden posts cloud-bericht.md to ntfy'
}

test_senden_refuses_empty_body() {
  local home status=0
  home=$(make_home empty-send)
  write_bruecke "$home"
  : > "$home/state/cloud-bericht.md"
  FM_HOME="$home" "$SENDEN" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'empty bericht must be refused'
  pass 'cloud: senden refuses an empty report'
}

test_annahme_silent_without_bridge
test_annahme_silent_when_kick_unchanged
test_annahme_queues_wake_for_new_kick
test_annahme_idempotent_after_done
test_holen_writes_kick_and_announces
test_senden_posts_bericht
test_senden_refuses_empty_body
