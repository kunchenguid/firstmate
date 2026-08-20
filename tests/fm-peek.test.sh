#!/usr/bin/env bash
# Characterization tests for fm-peek.sh's bounded explicit-target capture.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-peek.sh"
TMP_ROOT=$(fm_test_tmproot fm-peek)

make_fakebin() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  capture-pane)
    lines=40
    while [ "$#" -gt 0 ]; do
      if [ "${1:-}" = "-S" ]; then
        lines=${2#-}
        shift 2
      else
        shift
      fi
    done
    tail -n "$lines" "$FM_FAKE_CAPTURE"
    ;;
  *)
    exit 1
    ;;
  esac
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_explicit_target_capture_is_bounded() {
  local dir fakebin capture output rc=0
  dir="$TMP_ROOT/bounded"
  mkdir -p "$dir/state"
  fakebin=$(make_fakebin "$dir/fake")
  capture="$dir/capture"
  printf 'one\ntwo\nthree\n' > "$capture"

  output=$(
    FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" FM_FAKE_CAPTURE="$capture" \
      PATH="$fakebin:$PATH" "$SCRIPT" 'firstmate:fm-example' 2
  ) || rc=$?
  expect_code 0 "$rc" "an explicit target capture must succeed"
  [ "$output" = $'two\nthree' ] || fail "peek should return the requested tail, got: $output"
  pass "fm-peek.sh: explicit targets return exactly the requested capture tail"
}

test_explicit_target_capture_is_bounded
