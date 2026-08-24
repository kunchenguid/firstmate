#!/usr/bin/env bash
# Tests for fm-hplan-guard.sh, the world-readable inventory-copy guardian.
#
# The incident this guard exists for: four times in two days, copies of the real
# HPlan database - 229 hall bookings with real names and phone numbers - were
# found world-readable (/tmp strays via docker cp, stale working-copy leftovers),
# and on 2026-08-24 the running production database itself stood at 644.
# A filename-based detector would have caught none of the general case, so every
# detection case here plants the signature under a name that shares nothing with
# the known finds.
#
# Cases pin the whole acceptance contract:
#   - content signature (belegung table + filled uebungsleiter column, row-count
#     threshold; byte-marker fallback; SQL text dumps; orphan WALs), never names
#   - counter-samples stay silent (mode 600 signed copy; world-readable copy
#     without the signature)
#   - no content ever reaches stdout, stderr, or any state file
#   - the guard modifies nothing it scans
#   - an unreadable file, an unreachable server, and a torn time budget are
#     ordinary named partial states, never aborts: the chaos case burns every
#     failure mode at once and the run still finishes bounded, exit 0, naming
#     each partial cause - because the supervision cycle this runs in must never
#     go down with the detector
#   - arm/disarm produce a watcher-dispatchable trusted shim
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-hplan-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-hplan-guard)

SENTINEL_NAME=LEAKWACHE-NAME-7
SENTINEL_PHONE=LEAKWACHE-0176-42

# --- fixture builders -------------------------------------------------------

# py_stdin helper: run python with a heredoc and forwarded args.
py_run() {
  python3 - "$@"
}

make_signed_db() { # <path> [rows] [with_sentinels]
  py_run "$1" "${2:-229}" "${3:-yes}" "$SENTINEL_NAME" "$SENTINEL_PHONE" <<'PY'
import sqlite3, sys
path, rows, sentinels = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "yes"
sname, sphone = sys.argv[4], sys.argv[5]
con = sqlite3.connect(path)
con.execute("CREATE TABLE belegung (id INTEGER PRIMARY KEY, hall TEXT, zeit TEXT,"
            " uebungsleiter TEXT, telefon TEXT)")
for i in range(rows):
    name = f"{sname}-{i}" if sentinels else f"Uebungsperson-{i}"
    phone = f"{sphone}-{i}" if sentinels else f"0000-{i}"
    con.execute("INSERT INTO belegung VALUES (?,?,?,?,?)", (i, f"Halle-{i%3}",
               f"slot-{i}", name, phone))
con.commit()
con.close()
PY
}

make_unsigned_db() { # <path>: unrelated schema, none of the marker words anywhere
  py_run "$1" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE notizen (id INTEGER PRIMARY KEY, text TEXT)")
for i in range(400):
    con.execute("INSERT INTO notizen VALUES (?,?)", (i, f"Einkaufszettel Zeile {i}"))
con.commit()
con.close()
PY
}

make_partial_marker_db() { # <path>: word belegung present, uebungsleiter absent
  py_run "$1" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE protokoll (id INTEGER PRIMARY KEY, text TEXT)")
for i in range(400):
    con.execute("INSERT INTO protokoll VALUES (?,?)",
                (i, f"Raumbelegung Nummer {i} ohne Namen"))
con.commit()
con.close()
PY
}

make_signed_dump() { # <path> [rows]: plain SQL text, no sqlite magic, big enough
  py_run "$1" "${2:-500}" <<'PY'
import sys
path, rows = sys.argv[1], int(sys.argv[2])
lines = ["CREATE TABLE belegung (id INTEGER, uebungsleiter TEXT);"]
for i in range(rows):
    lines.append(f"INSERT INTO belegung VALUES ({i}, 'Trainierende-{i}',"
                 f" '0{700000000 + i:07d}');")
with open(path, "w") as f:
    f.write("\n".join(lines) + "\n")
PY
}

make_wal_blob() { # <path>: raw bytes carrying both markers, padded past the floor
  py_run "$1" <<'PY'
import sys
head = b"\x37\x7f\x06\x82\x5d\x8c\x27\x88" + b"\x00" * 16
schema = b"CREATE TABLE belegung (id INTEGER, uebungsleiter TEXT);"
body = head + schema + b"\x00" * (48 * 1024)
with open(sys.argv[1], "wb") as f:
    f.write(body)
PY
}

make_small_file() { # <path>: small world-readable file below every floor
  printf 'kurze notiz\n' > "$1"
}

make_tree() { # <dir> <count>: many tiny world-readable files, walk filler
  py_run "$1" "${2:-3000}" <<'PY'
import os, sys
root, count = sys.argv[1], int(sys.argv[2])
os.makedirs(root, exist_ok=True)
blob = b"x" * 9000
for i in range(count):
    d = os.path.join(root, f"p{i % 37}")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, f"f{i}"), "wb") as f:
        f.write(blob)
PY
}

new_scope() { # <name>: fresh scope dir printed
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  printf '%s\n' "$d"
}

scan_in() { # <scope> [extra env assignments passed through environment]
  HPLAN_GUARD_SERVER=off HPLAN_GUARD_SCOPES="$1" "$CHECK" scan 2>/dev/null
}

check_in() { # <scope>
  HPLAN_GUARD_SERVER=off HPLAN_GUARD_SCOPES="$1" "$CHECK" check 2>/dev/null
}

finding_paths() { # extract the path field of all FINDING lines
  awk -F'\t' '$1 == "FINDING" { print $2 }'
}

# --- detection: the signature hangs on content -----------------------------

test_finds_differently_named_copy() {
  local scope out
  scope=$(new_scope DetectionScope)
  make_signed_db "$scope/urlaubsplanung-2027.sqlite" 229 yes
  out=$(scan_in "$scope")
  assert_contains "$out" "$(printf 'FINDING\t%s/urlaubsplanung-2027.sqlite\t644\t' "$scope")" \
    "signed copy under an unknown name is reported"
  assert_contains "$out" "sqlite-struktur" "structured tier names the evidence kind"
  assert_contains "$out" "zeilen=229" "row count evidence is metadata, not content"
}

test_row_threshold_holds() {
  local scope out
  scope=$(new_scope ThresholdScope)
  make_signed_db "$scope/kleine-probe.sqlite" 40 no
  out=$(scan_in "$scope")
  assert_not_contains "$out" "FINDING" "a 40-row copy stays under the reporting threshold"
}

test_silent_on_600_signed_copy() {
  local scope out
  scope=$(new_scope Quiet600)
  make_signed_db "$scope/privat.sqlite" 229 yes
  chmod 0600 "$scope/privat.sqlite"
  out=$(scan_in "$scope")
  assert_not_contains "$out" "FINDING" "a mode-600 signed copy is nobody's find"
}

test_silent_on_unsigned_world_readable() {
  local scope out
  scope=$(new_scope QuietUnsigned)
  make_unsigned_db "$scope/einkaufs-notizen.sqlite"
  out=$(scan_in "$scope")
  assert_not_contains "$out" "FINDING" "world-readable sqlite without the signature stays quiet"
}

test_silent_on_partial_marker_word() {
  local scope out
  scope=$(new_scope QuietPartialWord)
  make_partial_marker_db "$scope/raum-protokoll.sqlite"
  out=$(scan_in "$scope")
  assert_not_contains "$out" "FINDING" "one marker word alone is not the inventory"
}

test_reports_renamed_text_dump() {
  local scope out
  scope=$(new_scope DumpScope)
  make_signed_dump "$scope/alte-notizen.txt"
  out=$(scan_in "$scope")
  assert_contains "$out" "FINDING" "a signed SQL dump under a text name is reported"
  assert_contains "$out" "dump-signatur" "dump tier names the evidence kind"
}

test_reports_orphan_wal() {
  local scope out
  scope=$(new_scope WalScope)
  make_wal_blob "$scope/x.sqlite-wal"
  out=$(scan_in "$scope")
  assert_contains "$out" "$(printf 'FINDING\t%s/x.sqlite-wal\t' "$scope")" \
    "an orphaned WAL carrying the markers is reported"
  assert_contains "$out" "byte-signatur" "WAL tier is the byte signature"
}

test_companions_flagged_with_base() {
  local scope out
  scope=$(new_scope CompanionScope)
  make_signed_db "$scope/bestand.sqlite" 229 no
  make_wal_blob "$scope/bestand.sqlite-wal"
  py_run "$scope/bestand.sqlite-shm" <<'PY'
import sys
with open(sys.argv[1], "wb") as f:
    f.write(b"\x00" * (40 * 1024))
PY
  out=$(scan_in "$scope")
  assert_contains "$out" "bestand.sqlite"$'\t'"644" "the flagged base is reported"
  assert_contains "$out" "bestand.sqlite-wal" "world-readable WAL beside a find is listed"
  assert_contains "$out" "bestand.sqlite-shm" "world-readable SHM beside a find is listed"
  assert_contains "$out" "begleiter" "companions carry their own tier label"
}

# --- safety contract --------------------------------------------------------

test_no_content_leaves_the_scanner() {
  local scope out cout rec
  scope=$(new_scope LeakScope)
  make_signed_db "$scope/tarnname-gesamt.sqlite" 229 yes
  rec="$TMP_ROOT/no-leak-home/state/.hplan-guard"
  out=$(HPLAN_GUARD_SCOPES="$scope" "$CHECK" scan 2>"$TMP_ROOT/scan-stderr.txt")
  assert_not_contains "$out" "$SENTINEL_NAME" "scan output carries no personal name"
  assert_not_contains "$out" "$SENTINEL_PHONE" "scan output carries no phone data"
  assert_no_grep "$SENTINEL_NAME" "$TMP_ROOT/scan-stderr.txt" "scan stderr carries no personal name"
  cout=$(FM_STATE_OVERRIDE="$TMP_ROOT/no-leak-home/state" check_in "$scope")
  assert_not_contains "$cout" "$SENTINEL_NAME" "check output carries no personal name"
  if [ -f "$rec" ]; then
    assert_no_grep "$SENTINEL_NAME" "$rec" "the record carries no personal name"
    assert_no_grep "$SENTINEL_PHONE" "$rec" "the record carries no phone data"
  fi
}

test_scanner_changes_nothing() {
  local scope before after
  scope=$(new_scope Untouched)
  make_signed_db "$scope/fund-a.sqlite" 229 no
  make_signed_dump "$scope/fund-b.sql" 500
  make_unsigned_db "$scope/ruhig.sqlite"
  before=$(cd "$scope" && sha256sum -- * 2>/dev/null | sort; stat -c '%a %n' -- *)
  scan_in "$scope" >/dev/null
  check_in "$scope" >/dev/null
  after=$(cd "$scope" && sha256sum -- * 2>/dev/null | sort; stat -c '%a %n' -- *)
  [ "$before" = "$after" ] || fail "scanner modified files it only looks at"
  pass "scanner changes nothing"
}

test_unreadable_file_is_ordinary() {
  local scope out status
  scope=$(new_scope Unreadable)
  make_signed_db "$scope/sichtbar.sqlite" 229 no
  make_small_file "$scope/geheim.txt"
  chmod 000 "$scope/geheim.txt"
  out=$(scan_in "$scope")
  status=$?
  expect_code 0 "$status" "unreadable neighbour does not abort the scan"
  assert_contains "$out" "sichtbar.sqlite" "readable find is still reported"
  if [ "$(id -u)" -ne 0 ]; then
    assert_contains "$out" "$(printf 'COVER\t%s\tok\t' "$scope")" \
      "coverage line reports the completed scope"
  fi
  chmod 600 "$scope/geheim.txt"
}

# --- the cycle must survive the guardian ------------------------------------

make_slow_ssh() { # <dir>: an ssh that hangs forever when called
  mkdir -p "$1"
  cat > "$1/hplan-slowssh" <<SH
#!/usr/bin/env bash
sleep 90
SH
  chmod 0755 "$1/hplan-slowssh"
}

test_chaos_run_names_partials_and_stays_bounded() {
  local scope fakebin out started elapsed status
  scope=$(new_scope ChaosZone)
  make_tree "$scope/streu" 3000
  fakebin=$(fm_fakebin "$TMP_ROOT/chaos-fakebin")
  make_slow_ssh "$fakebin"
  started=$SECONDS
  out=$(HPLAN_GUARD_SERVER=on HPLAN_GUARD_SCOPES="$scope" \
    HPLAN_GUARD_SSH_CMD="$fakebin/hplan-slowssh" \
    HPLAN_GUARD_BUDGET_SECS=4 HPLAN_GUARD_SSH_SECS=4 \
    FM_STATE_OVERRIDE="$TMP_ROOT/chaos-state" \
    "$CHECK" check 2>/dev/null)
  status=$?
  elapsed=$((SECONDS - started))
  expect_code 0 "$status" "chaos run exits clean"
  [ "$elapsed" -lt 25 ] || fail "chaos run took ${elapsed}s; it must never hang the cycle"
  local_lines=$(printf '%s\n' "$out" | grep -c . || true)
  [ "$local_lines" -le 1 ] || fail "check printed $local_lines lines; the watcher contract is one"
  assert_contains "$out" "unvollstaendig" "chaos run names its incomplete state"
  assert_contains "$out" "Server" "server unreachability is named as today-not-checked"
  assert_contains "$out" "Zeitgrenze" "torn time budget is named"
}

test_server_failure_is_not_fatal() {
  local scope fakebin out
  scope=$(new_scope ServerDown)
  make_signed_db "$scope/offen Kopie.sqlite" 229 no
  fakebin=$(fm_fakebin "$TMP_ROOT/down-fakebin")
  printf '#!/usr/bin/env bash\nexit 255\n' > "$fakebin/hplan-failssh"
  chmod 0755 "$fakebin/hplan-failssh"
  out=$(HPLAN_GUARD_SERVER=on HPLAN_GUARD_SCOPES="$scope" \
    HPLAN_GUARD_SSH_CMD="$fakebin/hplan-failssh" \
    HPLAN_GUARD_REMOTE_ROOTS="/nonexistent-volumen" \
    FM_STATE_OVERRIDE="$TMP_ROOT/down-state" \
    "$CHECK" check 2>/dev/null)
  expect_code 0 $? "server failure keeps exit clean"
  assert_contains "$out" "offen Kopie.sqlite" "local finding survives a dead server"
  assert_contains "$out" "Server" "dead server is named as a partial state"
}

# --- remote leg and backup exclusion ----------------------------------------

make_local_ssh() { # <dir>: an ssh stub that runs the piped snippet locally
  mkdir -p "$1"
  cat > "$1/hplan-localssh" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  chmod 0755 "$1/hplan-localssh"
}

test_remote_leg_respects_backup_exclusion() {
  local rroot fakebin out
  rroot="$TMP_ROOT/remote-root/volumen-nachbau"
  mkdir -p "$rroot/schutzordner" "$rroot/offen"
  make_signed_db "$rroot/schutzordner/sicherung-eins.sqlite" 500 no
  chmod 0644 "$rroot/schutzordner/sicherung-eins.sqlite"
  make_signed_db "$rroot/offen/live-kopie.sqlite" 500 no
  fakebin=$(fm_fakebin "$TMP_ROOT/remote-fakebin")
  make_local_ssh "$fakebin"
  out=$(HPLAN_GUARD_SERVER=on HPLAN_GUARD_SCOPES="$TMP_ROOT/empty-nowhere" \
    HPLAN_GUARD_SSH_CMD="$fakebin/hplan-localssh" \
    HPLAN_GUARD_REMOTE_ROOTS="$rroot" \
    HPLAN_GUARD_REMOTE_EXCLUDE="$rroot/schutzordner" \
    HPLAN_GUARD_BYTE_MIN_BYTES=8192 \
    FM_STATE_OVERRIDE="$TMP_ROOT/remote-state" \
    "$CHECK" check 2>/dev/null)
  expect_code 0 $? "remote leg completes cleanly"
  assert_contains "$out" "live-kopie.sqlite" "world-readable copy outside backups is reported via server leg"
  assert_not_contains "$out" "schutzordner" "excluded backup folder is never reported"
}

# --- watcher integration ----------------------------------------------------

test_check_dedupes_and_nag_works() {
  local scope first second third
  scope=$(new_scope DedupeZone)
  make_signed_db "$scope/dauerfund.sqlite" 229 no
  first=$(FM_STATE_OVERRIDE="$TMP_ROOT/dd-state" check_in "$scope")
  second=$(FM_STATE_OVERRIDE="$TMP_ROOT/dd-state" check_in "$scope")
  third=$(HPLAN_GUARD_RE_NAG_SECS=0 FM_STATE_OVERRIDE="$TMP_ROOT/dd-state" check_in "$scope")
  assert_contains "$first" "dauerfund.sqlite" "first sweep reports the finding"
  assert_not_contains "$second" "hplan-waechter" "unchanged fleet stays silent"
  assert_contains "$third" "dauerfund.sqlite" "re-nag setting reports again"
}

test_bad_config_is_named_never_fatal() {
  local scope out status
  scope=$(new_scope ConfigZone)
  out=$(HPLAN_GUARD_MIN_ROWS=banana HPLAN_GUARD_SERVER=off HPLAN_GUARD_SCOPES="$scope" \
    "$CHECK" check 2>/dev/null)
  status=$?
  expect_code 0 "$status" "bad configuration never breaks the cycle"
  assert_contains "$out" "falsch konfiguriert" "bad configuration is named in the report line"
  HPLAN_GUARD_MIN_ROWS=banana HPLAN_GUARD_SERVER=off HPLAN_GUARD_SCOPES="$scope" \
    "$CHECK" scan >/dev/null 2>&1
  expect_code 2 $? "manual scan refuses loudly on bad configuration"
}

test_arm_disarm_roundtrip() {
  local home out
  home="$TMP_ROOT/armhome"
  mkdir -p "$home/state"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$CHECK" arm >/dev/null || fail "arm failed"
  assert_present "$home/state/hplan-guard.check.sh" "arm writes the check shim"
  [ "$(stat -c '%a' "$home/state/hplan-guard.check.sh")" = 700 ] || fail "shim is not private"
  # shellcheck source=bin/fm-pr-lib.sh
  . "$ROOT/bin/fm-pr-lib.sh"
  # shellcheck source=bin/fm-check-lib.sh
  . "$ROOT/bin/fm-check-lib.sh"
  fm_custom_check_registered "$home/state" hplan-guard || fail "shim bytes are not trust-bound"
  local shim_scope out2
  shim_scope=$(new_scope ShimScope)
  make_signed_db "$shim_scope/schluessel-fund.sqlite" 229 no
  out2=$(HPLAN_GUARD_SERVER=off HPLAN_GUARD_SCOPES="$shim_scope" \
    timeout 30 bash "$home/state/hplan-guard.check.sh" 2>/dev/null </dev/null)
  assert_contains "$out2" "schluessel-fund.sqlite" \
    "shim executes under a hard timeout and reports through the one-line contract"
  [ "$(printf '%s\n' "$out2" | grep -c .)" -le 1 ] || fail "shim check printed more than one line"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$CHECK" disarm >/dev/null || fail "disarm failed"
  assert_absent "$home/state/hplan-guard.check.sh" "disarm removes the shim"
  assert_absent "$home/state/hplan-guard.check-trust" "disarm removes the trust binding"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$CHECK" disarm >/dev/null 2>&1
  expect_code 0 $? "disarm is idempotent"
}

test_pool_covered_each_sweep_and_ledger_silences_repeats() {
  local pool out1 out2 out3 st
  pool="$TMP_ROOT/ganzgebiet"
  mkdir -p "$pool/ort-eins" "$pool/ort-zwei"
  make_signed_db "$pool/ort-eins/fund-ort-eins.sqlite" 229 no
  make_signed_db "$pool/ort-zwei/fund-ort-zwei.sqlite" 229 no
  st="$TMP_ROOT/pool-state"
  out1=$(HPLAN_GUARD_SERVER=off HPLAN_GUARD_SCOPES="$pool" \
    FM_STATE_OVERRIDE="$st" "$CHECK" check 2>/dev/null)
  out2=$(HPLAN_GUARD_SERVER=off HPLAN_GUARD_SCOPES="$pool" \
    FM_STATE_OVERRIDE="$st" "$CHECK" check 2>/dev/null)
  out3=$(HPLAN_GUARD_SERVER=off HPLAN_GUARD_SCOPES="$pool" \
    HPLAN_GUARD_RE_NAG_SECS=0 FM_STATE_OVERRIDE="$st" \
    "$CHECK" check 2>/dev/null)
  assert_contains "$out1" "fund-ort-eins.sqlite" "the first find is reported"
  assert_contains "$out1" "fund-ort-zwei.sqlite" \
    "a second find elsewhere is reported in the same sweep"
  assert_not_contains "$out2" "hplan-waechter" \
    "an unchanged fleet stays silent"
  assert_contains "$out3" "fund-ort-eins.sqlite" \
    "the re-nag window brings standing findings back"
  assert_contains "$out3" "fund-ort-zwei.sqlite" \
    "the re-nag window covers every finding"
}

# --- cost discipline ---------------------------------------------------------

test_scan_stays_fast() {
  local scope started elapsed
  scope=$(new_scope SpeedZone)
  make_tree "$scope/masse" 2000
  make_signed_db "$scope/fund.sqlite" 229 no
  started=$SECONDS
  scan_in "$scope" >/dev/null
  elapsed=$((SECONDS - started))
  [ "$elapsed" -lt 10 ] || fail "a 2000-file scope took ${elapsed}s; the sweep is too heavy"
  pass "moderate scope sweeps inside seconds (${elapsed}s)"
}

# --- runner ------------------------------------------------------------------

for t in test_finds_differently_named_copy \
  test_row_threshold_holds \
  test_silent_on_600_signed_copy \
  test_silent_on_unsigned_world_readable \
  test_silent_on_partial_marker_word \
  test_reports_renamed_text_dump \
  test_reports_orphan_wal \
  test_companions_flagged_with_base \
  test_no_content_leaves_the_scanner \
  test_scanner_changes_nothing \
  test_unreadable_file_is_ordinary \
  test_chaos_run_names_partials_and_stays_bounded \
  test_server_failure_is_not_fatal \
  test_remote_leg_respects_backup_exclusion \
  test_check_dedupes_and_nag_works \
  test_bad_config_is_named_never_fatal \
  test_pool_covered_each_sweep_and_ledger_silences_repeats \
  test_arm_disarm_roundtrip \
  test_scan_stays_fast; do
  "$t"
  pass "$t"
done
