#!/usr/bin/env bash
# tests/fm-emulator-qa.test.sh - behavior tests for bin/fm-emulator-qa.sh.
#
# The two failure modes this script exists for were both rediscovered by hand on
# 2026-10-04, so the assertions here pin the decisions a lane must not get to
# re-derive under an emulator:
#   - an ABI set that cannot load on the AVD's image is named before anything is
#     booted, and the printed unblock is the scratch init script, not a product
#     build-file edit
#   - an instrumentation failure that names some other registration is retried
#     exactly once through a clean reinstall of BOTH packages, and the second hit
#     stops rather than starting a third attempt
#   - a failure that does name the requested runner is not treated as stale
#     registration at all, so no reinstall churn is spent on a real failure
#
# Everything runs against a fixture APK zip, a fixture AVD config, and a stub adb:
# no emulator, no SDK, and no model tokens. The two things a stub cannot prove are
# named in the script header as hand-integration-only.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-emulator-qa)
trap fm_test_cleanup EXIT

QA="$ROOT/bin/fm-emulator-qa.sh"

# The script reads an APK with unzip, and the fixture APKs are built with python3;
# neither is guaranteed inside BASE_PATH on every host, so resolve both from the
# invoking environment and put their own directories on the fixture PATH.
UNZIP=$(command -v unzip || true)
PY3=$(command -v python3 || command -v python || true)
if [ -z "$UNZIP" ] || [ -z "$PY3" ]; then
  printf 'skip: live: unzip or python3 absent\n'
  exit 0
fi
EXTRA_PATH="$(dirname "$UNZIP"):$(dirname "$PY3")"
RUN_PATH="$EXTRA_PATH:$BASE_PATH"

# No ambient aapt may leak into the zip-listing cases.
if PATH="$RUN_PATH" command -v aapt >/dev/null 2>&1 || PATH="$RUN_PATH" command -v aapt2 >/dev/null 2>&1; then
  printf 'skip: live: an aapt on PATH would decide the ABI read, not this fixture\n'
  exit 0
fi

# make_apk <path> <abis-or-empty>: a real zip carrying lib/<abi>/*.so, which is
# the only part of an APK the preflight read depends on.
make_apk() {
  local path=$1 abis=$2 abi
  "$PY3" - "$path" <<'PY'
import sys, zipfile
zf = zipfile.ZipFile(sys.argv[1], 'w')
zf.writestr('AndroidManifest.xml', b'\x03\x00\x00\x00fake-manifest')
zf.writestr('classes.dex', b'dex\n035')
zf.close()
PY
  # shellcheck disable=SC2086 # intentional word split of the ABI list
  for abi in $abis; do
    "$PY3" - "$path" "$abi" <<'PY'
import sys, zipfile
zf = zipfile.ZipFile(sys.argv[1], 'a')
zf.writestr('lib/%s/libnative.so' % sys.argv[2], b'\x7fELF')
zf.close()
PY
  done
}

# make_avd <avd-home> <name> <abi-type-line-or-empty> [sysdir]
make_avd() {
  local home=$1 name=$2 abi_line=$3 sysdir=${4:-}
  mkdir -p "$home/$name.avd"
  {
    printf 'avd.ini.encoding=UTF-8\n'
    printf 'path=%s/%s.avd\n' "$home" "$name"
    [ -n "$abi_line" ] && printf 'abi.type=%s\n' "$abi_line"
    [ -n "$sysdir" ] && printf 'image.sysdir.1=%s\n' "$sysdir"
    printf 'hw.cpu.arch=x86_64\n'
  } >"$home/$name.avd/config.ini"
}

APK_DIR="$TMP_ROOT/apks"
mkdir -p "$APK_DIR"
ARM_ONLY="$APK_DIR/arm-only.apk"
ARM_X86="$APK_DIR/arm-and-x86_64.apk"
NO_NATIVE="$APK_DIR/no-native.apk"
make_apk "$ARM_ONLY" 'arm64-v8a armeabi-v7a'
make_apk "$ARM_X86" 'arm64-v8a x86_64'
make_apk "$NO_NATIVE" ''

AVD_HOME="$TMP_ROOT/avd"
make_avd "$AVD_HOME" qa-x86_64 x86_64
make_avd "$AVD_HOME" qa-arm64 arm64-v8a
# An AVD whose config names no abi.type, only the system-image directory: this is
# how a lane's `qa2` was identified on 2026-10-04 after the direct field was absent.
make_avd "$AVD_HOME" qa-noabi '' 'system-images/android-34/google_apis/x86_64/'

# --- preflight: the ABI mismatch is named before anything boots ---------------

OUT="$TMP_ROOT/preflight-mismatch.out"
STATUS=0
PATH="$RUN_PATH" "$QA" preflight "$ARM_ONLY" qa-x86_64 --avd-home "$AVD_HOME" \
  --recipe-out "$TMP_ROOT/scratch-init.gradle" >"$OUT" 2>&1 || STATUS=$?
expect_code 2 "$STATUS" "an arm-only APK on an x86_64 image must not pass preflight"
assert_grep 'PREFLIGHT fail reason=arm_only_apk_on_x86_64_image' "$OUT" \
  "the mismatch must be named by reason: $(cat "$OUT")"
assert_grep 'abis=arm64-v8a armeabi-v7a' "$OUT" \
  "the shipped ABI set must be read from the APK's own lib/ tree: $(cat "$OUT")"
assert_grep 'finalizeDsl' "$OUT" \
  "the printed unblock must be the scratch init script: $(cat "$OUT")"
assert_grep "abiFilters.addAll(['x86_64', 'arm64-v8a'])" "$OUT" \
  "the recipe must replace the defaultConfig filters, not only a buildType's: $(cat "$OUT")"
assert_present "$TMP_ROOT/scratch-init.gradle" \
  '--recipe-out must leave the init script on disk for gradlew -I'
assert_grep 'androidComponents.finalizeDsl' "$TMP_ROOT/scratch-init.gradle" \
  'the written init script must be the same recipe the failure printed'
pass "an arm-only APK against an x86_64 image stops with the named reason and the scratch recipe"

# The recipe is a scratch artifact: shipping it must not require touching a
# product build file, which is the boundary the ruling on 2026-10-04 held.
assert_no_grep 'build.gradle.kts' "$TMP_ROOT/scratch-init.gradle" \
  'the recipe file must not instruct a product build-file edit'

STATUS=0
PATH="$RUN_PATH" "$QA" preflight "$ARM_X86" qa-x86_64 --avd-home "$AVD_HOME" \
  >"$TMP_ROOT/preflight-ok.out" 2>&1 || STATUS=$?
expect_code 0 "$STATUS" "an APK carrying x86_64 native libs is loadable on an x86_64 image"
OUT_OK=$(cat "$TMP_ROOT/preflight-ok.out")
assert_contains "$OUT_OK" 'PREFLIGHT ok reason=abi_compatible' 'a compatible APK must say so'
assert_not_contains "$OUT_OK" 'finalizeDsl' \
  'a passing preflight must not spend the lane on the recipe'
pass "a compatible ABI set passes without dragging the recipe along"

STATUS=0
PATH="$RUN_PATH" "$QA" preflight "$NO_NATIVE" qa-x86_64 --avd-home "$AVD_HOME" \
  >"$TMP_ROOT/preflight-nonative.out" 2>&1 || STATUS=$?
expect_code 0 "$STATUS" "a pure-Java APK cannot hit the translation crash"
assert_grep 'PREFLIGHT ok reason=no_native_code' "$TMP_ROOT/preflight-nonative.out" \
  'a pure-Java APK must be reported as such, not as an empty ABI match'
pass "an APK with no native libraries passes preflight"

STATUS=0
PATH="$RUN_PATH" "$QA" preflight "$ARM_ONLY" qa-arm64 --avd-home "$AVD_HOME" \
  >"$TMP_ROOT/preflight-arm-image.out" 2>&1 || STATUS=$?
expect_code 0 "$STATUS" "an arm-only APK on an arm64 image is the normal case, not a blocker"
pass "the arm-only check does not fire against an ARM image"

STATUS=0
PATH="$RUN_PATH" "$QA" preflight "$ARM_ONLY" qa-noabi --avd-home "$AVD_HOME" \
  >"$TMP_ROOT/preflight-sysdir.out" 2>&1 || STATUS=$?
expect_code 2 "$STATUS" "an AVD naming its ABI only through image.sysdir.1 must still be classified"
assert_grep 'image_abi=x86_64' "$TMP_ROOT/preflight-sysdir.out" \
  "the image ABI must fall back to the system-image path: $(cat "$TMP_ROOT/preflight-sysdir.out")"
pass "an AVD with no abi.type line is classified from its system-image directory"

STATUS=0
PATH="$RUN_PATH" "$QA" preflight "$TMP_ROOT/nope.apk" qa-x86_64 --avd-home "$AVD_HOME" \
  >"$TMP_ROOT/preflight-noapk.out" 2>&1 || STATUS=$?
expect_code 1 "$STATUS" "a missing APK is a bad input, not a blocker signature"
assert_grep 'nope.apk' "$TMP_ROOT/preflight-noapk.out" \
  'a missing APK must be named: '"$(cat "$TMP_ROOT/preflight-noapk.out")"
pass "a missing APK stops preflight by name instead of reporting a compatible build"

STATUS=0
PATH="$RUN_PATH" "$QA" preflight "$ARM_ONLY" qa-missing --avd-home "$AVD_HOME" \
  >"$TMP_ROOT/preflight-noavd.out" 2>&1 || STATUS=$?
expect_code 1 "$STATUS" "an unknown AVD is a bad input"
assert_grep 'qa-missing' "$TMP_ROOT/preflight-noavd.out" \
  'the AVD that could not be found must be named'
pass "an AVD with no config.ini stops preflight by name rather than passing unchecked"

# --- preflight: aapt wins when one is reachable ------------------------------
#
# The SDK's aapt is not on a lane's PATH, so a lane inside the container gets the
# authoritative read and a lane outside it gets the zip read. The fake below
# reports x86_64 while the fixture zip carries only ARM, so the two sources are
# genuinely distinguishable.
FAKE_AAPT="$TMP_ROOT/fake-aapt"
cat >"$FAKE_AAPT" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  dump) printf "package: name='com.shapescale.qa' versionCode='1'\n"
        printf 'native-code: arm64-v8a x86_64\n' ;;
esac
exit 0
SH
chmod +x "$FAKE_AAPT"
STATUS=0
PATH="$RUN_PATH" "$QA" preflight "$ARM_ONLY" qa-x86_64 --avd-home "$AVD_HOME" \
  --aapt "$FAKE_AAPT" >"$TMP_ROOT/preflight-aapt.out" 2>&1 || STATUS=$?
expect_code 0 "$STATUS" "aapt reporting an x86_64 library must override the ARM-only zip listing"
assert_grep 'abis=arm64-v8a x86_64' "$TMP_ROOT/preflight-aapt.out" \
  'the ABI read must come from the aapt that was passed in'
pass "preflight uses aapt when one is reachable and falls back to the zip listing when not"

# --- instrument: the two-hit stop --------------------------------------------

make_fake_adb() {  # <path>
  local path=$1
  cat >"$path" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_QA_ADB_LOG"
case "$*" in
  *'am instrument'*)
    n=0
    [ -f "$FM_QA_RUN_COUNT" ] && n=$(cat "$FM_QA_RUN_COUNT")
    n=$((n + 1))
    printf '%s' "$n" > "$FM_QA_RUN_COUNT"
    case "$FM_QA_ADB_MODE" in
      stale-then-ok)
        if [ "$n" -eq 1 ]; then
          printf 'INSTRUMENTATION_FAILED: com.shapescale.qa.test/androidx.test.runner.ImageExportInstrumentation\n'
        else
          printf 'INSTRUMENTATION_RESULT: stream=\nOK (3 tests)\n'
        fi
        ;;
      always-stale)
        printf 'INSTRUMENTATION_FAILED: com.shapescale.qa.test/androidx.test.runner.ImageExportInstrumentation\n'
        ;;
      real-failure)
        printf 'INSTRUMENTATION_FAILED: com.shapescale.qa.test/com.shapescale.qa.ScanAssemblyInstrumentation\n'
        ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$path"
}

ADDBIN="$TMP_ROOT/adb"
make_fake_adb "$ADDBIN"
TEST_APK="$APK_DIR/test.apk"
APP_APK="$APK_DIR/app.apk"
make_apk "$TEST_APK" 'x86_64'
make_apk "$APP_APK" 'x86_64'

run_instrument() {  # <mode> <evidence-file>  -> sets I_STATUS and I_OUT (captured output)
  local mode=$1 evidence=$2
  export FM_QA_ADB_MODE="$mode"
  : >"$FM_QA_ADB_LOG"
  rm -f "$FM_QA_RUN_COUNT"
  local out_file="$TMP_ROOT/instrument.$mode.out"
  I_STATUS=0
  PATH="$RUN_PATH" "$QA" instrument emulator-5554 "$TEST_APK" "$APP_APK" \
    com.shapescale.qa.ScanAssemblyInstrumentation \
    --adb "$ADDBIN" --app-package com.shapescale.qa --test-package com.shapescale.qa.test \
    --evidence-file "$evidence" >"$out_file" 2>&1 || I_STATUS=$?
  I_OUT=$(cat "$out_file")
}

FM_QA_ADB_LOG="$TMP_ROOT/adb.log"
FM_QA_RUN_COUNT="$TMP_ROOT/runs"
export FM_QA_ADB_LOG FM_QA_RUN_COUNT

rm -f "$TMP_ROOT/evidence-stale.txt"
run_instrument stale-then-ok "$TMP_ROOT/evidence-stale.txt"
expect_code 0 "$I_STATUS" "a stale runner that clears after one clean reinstall is not a blocker"
assert_contains "$I_OUT" 'INSTRUMENTATION ok serial=emulator-5554 component=com.shapescale.qa.test/com.shapescale.qa.ScanAssemblyInstrumentation' \
  'a completed run must report the explicit component it used'
inst_attempts=$(grep -c 'am instrument' "$FM_QA_ADB_LOG")
[ "$inst_attempts" = 2 ] || fail "one reinstall and one retry means exactly 2 instrumentation runs, got $inst_attempts: $(cat "$FM_QA_ADB_LOG")"
first_run_line=$(grep -n 'am instrument' "$FM_QA_ADB_LOG" | head -1 | cut -d: -f1)
uninstall_app_line=$(grep -n 'uninstall com.shapescale.qa$' "$FM_QA_ADB_LOG" | head -1 | cut -d: -f1)
uninstall_test_line=$(grep -n 'uninstall com.shapescale.qa.test$' "$FM_QA_ADB_LOG" | head -1 | cut -d: -f1)
[ -n "$uninstall_app_line" ] && [ -n "$uninstall_test_line" ] ||
  fail "both packages must be uninstalled, not just the app: $(cat "$FM_QA_ADB_LOG")"
[ "$uninstall_app_line" -lt "$first_run_line" ] && [ "$uninstall_test_line" -lt "$first_run_line" ] ||
  fail "both uninstalls must precede the instrumentation run: $(cat "$FM_QA_ADB_LOG")"
grep -q 'install -r -t '"$APP_APK" "$FM_QA_ADB_LOG" ||
  fail "the app package must be reinstalled: $(cat "$FM_QA_ADB_LOG")"
grep -q 'am instrument -w com.shapescale.qa.test/com.shapescale.qa.ScanAssemblyInstrumentation' "$FM_QA_ADB_LOG" ||
  fail "the run must name the component explicitly instead of trusting registered-runner discovery: $(cat "$FM_QA_ADB_LOG")"
pass "a stale runner is cleared by reinstalling both packages and running the explicit component"

rm -f "$TMP_ROOT/evidence-blocked.txt"
run_instrument always-stale "$TMP_ROOT/evidence-blocked.txt"
expect_code 2 "$I_STATUS" "a second hit on the stale-runner signature is the two-hit stop"
assert_contains "$I_OUT" 'hits=2 action=skip_this_width' \
  'the stop must be recorded as a signature with the action, not as another retry'
assert_contains "$I_OUT" 'seen=com.shapescale.qa.test/androidx.test.runner.ImageExportInstrumentation' \
  'the stale record must name the registration the emulator actually used'
inst_attempts=$(grep -c 'am instrument' "$FM_QA_ADB_LOG")
[ "$inst_attempts" = 2 ] ||
  fail "the two-hit rule forbids a third attempt, got $inst_attempts: $(cat "$FM_QA_ADB_LOG")"
assert_grep 'INSTRUMENTATION_STALE_RUNNER' "$TMP_ROOT/evidence-blocked.txt" \
  'the blocker signature must reach the lane evidence file, not only the terminal'
pass "the second hit stops at exit 2 and records the signature instead of trying again"

run_instrument real-failure "$TMP_ROOT/evidence-real.txt"
expect_code 1 "$I_STATUS" "a failure naming the requested runner is a real failure, not stale registration"
assert_not_contains "$I_OUT" 'INSTRUMENTATION_STALE_RUNNER' \
  'a genuine test failure must not be relabelled as a registration problem'
inst_attempts=$(grep -c 'am instrument' "$FM_QA_ADB_LOG")
[ "$inst_attempts" = 1 ] ||
  fail "a real failure must not spend a reinstall round: $inst_attempts attempts\n$(cat "$FM_QA_ADB_LOG")"
pass "a failure that names the requested runner stops immediately without reinstall churn"

# --- instrument: fail-closed on the tools and names it depends on -------------

STATUS=0
PATH="$RUN_PATH" "$QA" instrument emulator-5554 "$TEST_APK" "$APP_APK" \
  com.shapescale.qa.ScanAssemblyInstrumentation --adb "$TMP_ROOT/not-adb" \
  >"$TMP_ROOT/instrument-nosuchadb.out" 2>&1 || STATUS=$?
expect_code 1 "$STATUS" 'an unusable adb path is a bad input, not an instrumentation result'
assert_grep 'not-adb' "$TMP_ROOT/instrument-nosuchadb.out" 'the unusable adb path must be named'
pass "instrument refuses an adb path it cannot execute"

if ! PATH="$BASE_PATH" command -v adb >/dev/null 2>&1; then
  STATUS=0
  PATH="$BASE_PATH" "$QA" instrument emulator-5554 "$TEST_APK" "$APP_APK" \
    com.shapescale.qa.ScanAssemblyInstrumentation \
    >"$TMP_ROOT/instrument-noadb.out" 2>&1 || STATUS=$?
  expect_code 1 "$STATUS" 'no adb anywhere is a blocker the lane must be told about'
  assert_grep 'adb' "$TMP_ROOT/instrument-noadb.out" 'the missing tool must be named'
  pass "instrument reports a missing adb instead of reporting an instrumentation result"
fi

STATUS=0
PATH="$RUN_PATH" "$QA" instrument emulator-5554 "$TEST_APK" "$APP_APK" \
  com.shapescale.qa.ScanAssemblyInstrumentation --adb "$ADDBIN" \
  >"$TMP_ROOT/instrument-nopkg.out" 2>&1 || STATUS=$?
expect_code 1 "$STATUS" 'package names must not be guessed from a file name'
assert_grep '--app-package' "$TMP_ROOT/instrument-nopkg.out" \
  'the refusal must name the flags that would supply the packages'
pass "instrument refuses to guess package names when no aapt can read them"

# --- evidence-dir ------------------------------------------------------------

WT="$TMP_ROOT/lane-worktree"
mkdir -p "$WT"
DIR=$(PATH="$RUN_PATH" "$QA" evidence-dir fm-demo-lane --worktree "$WT")
[ "$DIR" = "$WT/build/evidence/fm-demo-lane" ] ||
  fail "evidence-dir must print the lane's per-task evidence path, got $DIR"
[ -d "$DIR" ] || fail "evidence-dir must create the directory it prints"
pass "evidence-dir creates and prints build/evidence/<task-id> in the lane's copy"

DIR=$(PATH="$RUN_PATH" "$QA" evidence-dir fm-demo-lane --worktree "$WT" --flat)
[ "$DIR" = "$WT/build/evidence" ] ||
  fail "--flat must print the flat layout the 2026-10-04 lanes used, got $DIR"
pass "the flat evidence layout stays available for the recorded file names"

STATUS=0
PATH="$RUN_PATH" "$QA" evidence-dir fm-demo-lane --worktree "$TMP_ROOT/no-such-tree" \
  >"$TMP_ROOT/evidence-dir.out" 2>&1 || STATUS=$?
expect_code 1 "$STATUS" 'an unusable worktree path must stop the command'
pass "evidence-dir refuses a worktree path that does not exist"

echo "# fm-emulator-qa.test.sh: all assertions passed"
