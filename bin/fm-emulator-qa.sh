#!/usr/bin/env bash
# fm-emulator-qa.sh - emulator QA gates a lane runs before it spends an hour
# re-discovering why its emulator evidence will not land.
#
# Two failure modes stopped Android lanes twice on 2026-10-04, and both are
# detectable in seconds rather than in a crash buffer:
#
# 1. An APK shipping only arm64-v8a/armeabi-v7a native libraries installed on an
#    x86_64 AVD. The guest dies with a SIGSEGV under libndk_translation, which
#    reads like an app bug and not like an ABI mismatch. The recorded unblock is a
#    scratch-only Gradle init script that packages the x86_64 native libraries the
#    dependencies already ship; `preflight` prints that recipe rather than applying
#    it, because packaging native code for a QA build is the lane's call.
#    Precedents in the private firstmate home (gitignored, so paths not links):
#      data/android-assembly-followups/ plus the [key=emulator-native-abi] entry in
#        state/android-assembly-followups.status, whose narrative the lane kept at
#        build/evidence/emulator-native-crash.txt in its own worktree.
#      data/fresh-contour-parity-pass-re-run-the-ios-92/report.md steps 1-2: same
#        guest crash, same scratch-init unblock, then host emulator exit 139.
# 2. A stale instrumentation-runner registration carried across screen widths: the
#    emulator reports INSTRUMENTATION_FAILED naming a runner that is not the one
#    just installed. The unblock is a clean uninstall of BOTH packages, a fresh
#    reinstall, and an explicit `am instrument` component instead of registered
#    runner discovery. `instrument` performs exactly that and applies the two-hit
#    stop, so a lane skips a width instead of spending its remaining session on it
#    (recorded as [key=emulator-probe-registration] in the same status file).
#
# Verification: tests/fm-emulator-qa.test.sh drives `preflight` against a fixture
# APK tree and a fixture AVD config, and drives `instrument` against a stub adb, so
# the ABI classification, the two-hit stop, and the exact adb call sequence are all
# covered with no emulator and no SDK. Hand-integration-tested only, because a
# stub cannot prove them and asserting the stub would prove nothing: a real
# `am instrument` run reaching `OK (N tests)` through this path, and a real x86_64
# QA APK assembled with the printed init script.
#
# Tool discovery is PATH-based with explicit overrides (--adb, --aapt,
# --avd-home, ANDROID_AVD_HOME), so this script needs neither a distrobox nor a
# running emulator. A lane whose SDK lives in the droid container passes --adb and
# --aapt pointing at copies reachable from where it runs, or runs this inside the
# container. On zeppola the AVDs live under $HOME/.config/.android/avd, which is
# probed when ANDROID_AVD_HOME is unset, ahead of the plain $HOME/.android/avd.

set -eu

usage() {
  cat <<'USAGE'
Usage:
  fm-emulator-qa.sh preflight <apk> <avd-name>
    [--avd-home <dir>] [--aapt <path>] [--recipe-out <path>]
  fm-emulator-qa.sh instrument <emulator-serial> <test-apk> <app-apk> <runner-class>
    [--adb <path>] [--aapt <path>] [--app-package <id>] [--test-package <id>]
    [--evidence-file <path>]
  fm-emulator-qa.sh evidence-dir <task-id> [--worktree <path>] [--flat]

preflight compares the ABIs the APK ships (aapt when one is reachable, otherwise
its lib/<abi>/ and jni/<abi>/ entries) against the ABI the AVD's system image is
(config.ini abi.type, falling back to the ABI named in image.sysdir.1), and
prints the scratch-init x86_64 recipe when the two cannot intersect.
--recipe-out writes just the init-script body to a task-local path, ready for
`gradlew -I`.

instrument uninstalls the app package and the test package, reinstalls both, and
runs `am instrument -w` against the explicit <test-package>/<runner-class>
component. A failure naming a component other than the requested runner gets one
repeat of the clean reinstall; a second hit on that signature stops with exit 2.
Package names come from --app-package/--test-package, then from aapt, never from
a file name. With --evidence-file the failure signature is appended there too.

evidence-dir prints and creates the lane's evidence path,
<worktree>/build/evidence/<task-id>, or the flat <worktree>/build/evidence with
--flat. The worktree defaults to $PWD or --worktree.

Exit codes, identical for every subcommand:
  0 compatible, or instrumentation ran to completion
  1 unusable input, a missing tool, or a failure a clean reinstall cannot fix
  2 a known blocker signature: record it and move on, do not retry
USAGE
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

# --- ABI reading -------------------------------------------------------------

# apk_abis <apk> <aapt-path-or-empty>: prints one ABI per line, and nothing for a
# pure-Java APK. aapt is authoritative when reachable; the zip listing is the
# fallback, because aapt lives in the SDK and not on a lane's PATH.
apk_abis() {
  local apk=$1 aapt_bin=$2 line
  if [ -n "$aapt_bin" ]; then
    line=$("$aapt_bin" dump badging "$apk" 2>/dev/null | sed -n 's/^native-code: //p' | head -1 || true)
    if [ -n "$line" ]; then
      printf '%s\n' "$line" | tr ' ,' '\n' | sed '/^$/d'
      return 0
    fi
  fi
  unzip -Z1 "$apk" 'lib/*' 'jni/*' 2>/dev/null | awk -F/ '
    ($1 == "lib" || $1 == "jni") && NF >= 3 && $NF ~ /\.so$/ { print $2 }
  ' | sort -u || true
}

# avd_abi <avd-dir>: prints the ABI the AVD's system image is, from abi.type or
# from the ABI named in image.sysdir.1. x86_64 is probed before x86, a substring
# of it.
avd_abi() {
  local dir=$1 val abi
  [ -f "$dir/config.ini" ] || return 1
  val=$(sed -n 's/^[[:space:]]*abi\.type[[:space:]]*=[[:space:]]*//p' "$dir/config.ini" | head -1 | tr -d '[:space:]' || true)
  if [ -n "$val" ]; then
    printf '%s\n' "$val"
    return 0
  fi
  val=$(sed -n 's/^[[:space:]]*image\.sysdir\.[0-9]*[[:space:]]*=[[:space:]]*//p' "$dir/config.ini" | head -1 || true)
  for abi in x86_64 arm64-v8a armeabi-v7a x86; do
    case "$val" in
      *"$abi"*) printf '%s\n' "$abi"; return 0 ;;
    esac
  done
  return 1
}

# abis_supported_by <image-abi>: the ABIs an image of that ABI can load.
abis_supported_by() {
  case "$1" in
    x86_64) printf 'x86_64\nx86\n' ;;
    x86) printf 'x86\n' ;;
    arm64-v8a) printf 'arm64-v8a\narmeabi-v7a\n' ;;
    armeabi-v7a) printf 'armeabi-v7a\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# apks_abis_supported <apk-abis-newline> <supported-abis-newline>: 0 when any
# shipped ABI is loadable on the image.
apks_abis_supported() {
  local apk_abis=$1 supported=$2 abi
  while IFS= read -r abi; do
    [ -n "$abi" ] || continue
    case $'\n'"$supported"$'\n' in
      *$'\n'"$abi"$'\n'*) return 0 ;;
    esac
  done <<<"$apk_abis"
  return 1
}

# find_avd_dir <avd-name> <extra-avd-home-or-empty>: the first AVD directory with
# a config.ini, honouring an explicit home, then ANDROID_AVD_HOME, then this
# fleet's location, then the plain SDK default.
find_avd_dir() {
  local name=$1 extra=$2 home candidate
  for home in "$extra" "${ANDROID_AVD_HOME:-}" "$HOME/.config/.android/avd" "$HOME/.android/avd"; do
    [ -n "$home" ] || continue
    for candidate in "$home/$name" "$home/$name.avd"; do
      if [ -f "$candidate/config.ini" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  done
  return 1
}

# recipe_gradle_body: the scratch init script, in the one form both the printed
# recipe and --recipe-out use. finalizeDsl runs after the app's own build script,
# which is what lets it overwrite the product defaultConfig filters.
recipe_gradle_body() {
  cat <<'GRADLE'
// QA-only ABI override for an x86_64 emulator: packages the x86_64 native
// libraries the dependencies already ship. Not a product change.
gradle.beforeProject { p ->
    p.plugins.withId('com.android.application') {
        p.androidComponents.finalizeDsl { ext ->
            ext.ndk.abiFilters.clear()
            ext.ndk.abiFilters.addAll(['x86_64', 'arm64-v8a'])
        }
    }
}
GRADLE
}

print_recipe() {
  cat <<'RECIPE'

Scratch-only x86_64 packaging recipe (task-local; never a product build file):

Write it to a scratch path in the lane's own copy, e.g.
build/emulator-native.gradle or scratch/emulator-native.gradle, and assemble
through it:
  ./gradlew -I scratch/emulator-native.gradle :app:assembleDebug :app:assembleDebugAndroidTest

RECIPE
  recipe_gradle_body | sed 's/^/  /'
  cat <<'RECIPE'

Three things the lanes that proved this learned the slow way:
  - Overwrite the defaultConfig filters. Setting only debug.ndk.abiFilters left
    the product ARM filters in force and changed nothing.
  - An init script that arrives after the native-merge tasks are up to date has
    no effect. Force the rerun (clean, or --rerun-tasks) instead of trusting an
    incremental build.
  - Check the artifact before booting anything:
      unzip -Z1 app/build/outputs/apk/debug/app-debug.apk 'lib/*'
    If x86_64 native code still SIGSEGVs twice, stop and record it; the fallback
    evidence path is device-captured media plus JVM-only checks.
RECIPE
}

cmd_preflight() {
  local apk=${1:-} avd=${2:-} avd_home='' aapt_bin='' recipe_out=''
  [ -n "$apk" ] && [ -n "$avd" ] || { usage >&2; exit 1; }
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --avd-home) [ $# -ge 2 ] || die '--avd-home needs a directory'; avd_home=$2; shift 2 ;;
      --aapt) [ $# -ge 2 ] || die '--aapt needs a path'; aapt_bin=$2; shift 2 ;;
      --recipe-out) [ $# -ge 2 ] || die '--recipe-out needs a path'; recipe_out=$2; shift 2 ;;
      *) die "preflight: unknown argument: $1" ;;
    esac
  done
  [ -f "$apk" ] || die "no APK at $apk"
  command -v unzip >/dev/null 2>&1 ||
    die 'reading an APK needs unzip (aapt is optional); found neither'

  if [ -z "$aapt_bin" ]; then
    aapt_bin=$(command -v aapt2 || command -v aapt || true)
  fi
  if [ -n "$aapt_bin" ] && [ ! -x "$aapt_bin" ]; then
    die "aapt is not executable: $aapt_bin"
  fi

  local avd_dir image_abi
  avd_dir=$(find_avd_dir "$avd" "$avd_home") ||
    die "no AVD config.ini for '$avd'; pass --avd-home or set ANDROID_AVD_HOME"
  image_abi=$(avd_abi "$avd_dir") ||
    die "cannot read an ABI from $avd_dir/config.ini (abi.type or image.sysdir.1)"

  local abis
  abis=$(apk_abis "$apk" "$aapt_bin" | tr '\n' ' ' | sed 's/ *$//')
  printf 'preflight apk=%s abis=%s\n' "$apk" "${abis:-none}"
  printf 'preflight avd=%s image_abi=%s\n' "$avd" "$image_abi"

  if [ -z "$abis" ]; then
    printf 'PREFLIGHT ok reason=no_native_code\n'
    return 0
  fi

  local supported reason abi arms_only=1
  supported=$(abis_supported_by "$image_abi")
  if apks_abis_supported "$(printf '%s\n' "$abis" | tr ' ' '\n')" "$supported"; then
    printf 'PREFLIGHT ok reason=abi_compatible\n'
    return 0
  fi

  # The name that matters to a lane is the one it can act on: an all-ARM APK is
  # the failure mode with a proven unblock, anything else is reported plainly.
  # shellcheck disable=SC2086 # intentional word split of the ABI list
  for abi in $abis; do
    case "$abi" in
      arm*) ;;
      *) arms_only=0 ;;
    esac
  done
  [ "$arms_only" -eq 1 ] && reason='arm_only_apk'
  printf 'PREFLIGHT fail reason=%s_on_%s_image\n' "$reason" "$image_abi"
  printf 'BLOCKER The APK ships %s; the %s image can only load %s.\n' \
    "$abis" "$avd" "$(printf '%s' "$supported" | tr '\n' ' ')"
  print_recipe
  if [ -n "$recipe_out" ]; then
    mkdir -p "$(dirname "$recipe_out")"
    recipe_gradle_body >"$recipe_out"
    printf 'RECIPE wrote=%s\n' "$recipe_out"
  fi
  return 2
}

# --- instrumentation ---------------------------------------------------------

# instrument_failure_kind <output> <requested-runner-simple-name>: prints `stale`
# when the emulator could not launch what it was asked for and named some other
# registration instead, `ok` on a completed run, and `failed` for a real failure
# that does name the requested runner.
instrument_failure_kind() {
  local out=$1 requested=$2
  case $out in
    *INSTRUMENTATION_FAILED* | *INSTRUMENTATION_ERROR*)
      case $out in
        *"$requested"*) printf 'failed\n' ;;
        *) printf 'stale\n' ;;
      esac
      ;;
    *'OK ('*) printf 'ok\n' ;;
    *) printf 'failed\n' ;;
  esac
}

# failure_component <output>: the component the emulator says it tried.
failure_component() {
  local out=$1
  printf '%s\n' "$out" |
    sed -n 's/.*INSTRUMENTATION_[A-Z]*:[[:space:]]*\([^[:space:]]*\).*/\1/p' |
    head -1
}

cmd_instrument() {
  local serial=${1:-} test_apk=${2:-} app_apk=${3:-} runner=${4:-}
  local adb_bin='' aapt_bin='' app_pkg='' test_pkg='' evidence_file=''
  [ -n "$serial" ] && [ -n "$test_apk" ] && [ -n "$app_apk" ] && [ -n "$runner" ] || {
    usage >&2
    exit 1
  }
  shift 4
  while [ $# -gt 0 ]; do
    case "$1" in
      --adb) [ $# -ge 2 ] || die '--adb needs a path'; adb_bin=$2; shift 2 ;;
      --aapt) [ $# -ge 2 ] || die '--aapt needs a path'; aapt_bin=$2; shift 2 ;;
      --app-package) [ $# -ge 2 ] || die '--app-package needs an id'; app_pkg=$2; shift 2 ;;
      --test-package) [ $# -ge 2 ] || die '--test-package needs an id'; test_pkg=$2; shift 2 ;;
      --evidence-file) [ $# -ge 2 ] || die '--evidence-file needs a path'; evidence_file=$2; shift 2 ;;
      *) die "instrument: unknown argument: $1" ;;
    esac
  done
  [ -f "$test_apk" ] || die "no test APK at $test_apk"
  [ -f "$app_apk" ] || die "no app APK at $app_apk"

  if [ -z "$adb_bin" ]; then
    adb_bin=$(command -v adb || true)
    [ -n "$adb_bin" ] ||
      die 'no adb on PATH; pass --adb (on zeppola the SDK lives in the droid container)'
  fi
  [ -x "$adb_bin" ] || die "adb is not executable: $adb_bin"

  if [ -z "$aapt_bin" ]; then
    aapt_bin=$(command -v aapt2 || command -v aapt || true)
  fi
  if { [ -z "$app_pkg" ] || [ -z "$test_pkg" ]; } && [ -z "$aapt_bin" ]; then
    die 'cannot read package names without aapt; pass --app-package and --test-package'
  fi
  if [ -z "$app_pkg" ]; then
    app_pkg=$("$aapt_bin" dump badging "$app_apk" 2>/dev/null |
      sed -n "s/^package: name='\\([^']*\\)'.*/\\1/p" | head -1 || true)
    [ -n "$app_pkg" ] || die "aapt found no package in $app_apk; pass --app-package"
  fi
  if [ -z "$test_pkg" ]; then
    test_pkg=$("$aapt_bin" dump badging "$test_apk" 2>/dev/null |
      sed -n "s/^package: name='\\([^']*\\)'.*/\\1/p" | head -1 || true)
    [ -n "$test_pkg" ] || die "aapt found no package in $test_apk; pass --test-package"
  fi

  # The component is always explicit: registered-runner discovery is what picks up
  # the previous width's instrumentation in the first place.
  local component requested_simple
  case "$runner" in
    */*) component=$runner ;;
    *) component="$test_pkg/$runner" ;;
  esac
  requested_simple=${runner##*/}
  requested_simple=${requested_simple##*.}

  record() {
    printf '%s\n' "$1"
    if [ -n "$evidence_file" ]; then
      mkdir -p "$(dirname "$evidence_file")"
      printf '%s\n' "$1" >>"$evidence_file"
    fi
  }

  local attempt=1 out kind component_seen
  while [ "$attempt" -le 2 ]; do
    # A clean slate for BOTH packages. A test package left over from the previous
    # width keeps its own runner registration, and an instrumentation run then
    # launches that instead of this build's runner.
    "$adb_bin" -s "$serial" uninstall "$app_pkg" >/dev/null 2>&1 || true
    "$adb_bin" -s "$serial" uninstall "$test_pkg" >/dev/null 2>&1 || true
    "$adb_bin" -s "$serial" install -r -t "$app_apk" >/dev/null ||
      die "could not install $app_apk on $serial"
    "$adb_bin" -s "$serial" install -r -t "$test_apk" >/dev/null ||
      die "could not install $test_apk on $serial"

    out=$("$adb_bin" -s "$serial" shell am instrument -w "$component" 2>&1 || true)
    kind=$(instrument_failure_kind "$out" "$requested_simple")
    case "$kind" in
      ok)
        record "INSTRUMENTATION ok serial=$serial component=$component attempt=$attempt"
        printf '%s\n' "$out" | tail -5
        return 0
        ;;
      stale)
        component_seen=$(failure_component "$out")
        record "INSTRUMENTATION_STALE_RUNNER serial=$serial requested=$component seen=${component_seen:-unknown} attempt=$attempt"
        ;;
      *)
        printf '%s\n' "$out" | tail -20
        die "instrumentation failed for $component on $serial; a clean reinstall does not fix a failure that names the requested runner"
        ;;
    esac
    attempt=$((attempt + 1))
  done

  record "INSTRUMENTATION_STALE_RUNNER serial=$serial requested=$component seen=${component_seen:-unknown} hits=2 action=skip_this_width"
  return 2
}

# --- evidence path -----------------------------------------------------------

cmd_evidence_dir() {
  local task_id=${1:-} root=${FM_EMULATOR_QA_WORKTREE:-$PWD} flat=0
  [ -n "$task_id" ] || { usage >&2; exit 1; }
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --worktree) [ $# -ge 2 ] || die '--worktree needs a path'; root=$2; shift 2 ;;
      --flat) flat=1; shift ;;
      *) die "evidence-dir: unknown argument: $1" ;;
    esac
  done
  [ -d "$root" ] || die "no such worktree: $root"
  local dir="$root/build/evidence"
  [ "$flat" -eq 1 ] || dir="$dir/$task_id"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

main() {
  case "${1:-}" in
    preflight) shift; cmd_preflight "$@" ;;
    instrument) shift; cmd_instrument "$@" ;;
    evidence-dir) shift; cmd_evidence_dir "$@" ;;
    -h | --help | help) usage ;;
    *) usage >&2; exit 1 ;;
  esac
}

main "$@"
