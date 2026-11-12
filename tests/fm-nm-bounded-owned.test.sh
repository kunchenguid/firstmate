#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-bounded-owned)

test_owned_queries_remain_cancellable() {
  local mechanism operation dir owner i child pgid mismatch status
  for mechanism in default perl; do
    for operation in status resolver; do
      dir="$TMP_ROOT/$mechanism-$operation"
      mkdir -p "$dir/config" "$dir/fakebin"
      cat > "$dir/fakebin/no-mistakes" <<'SCRIPT'
#!/usr/bin/env bash
sleep 30 &
printf '%s\n' "$$" "$!" > "$FM_HOME/query-pids"
wait
SCRIPT
      chmod +x "$dir/fakebin/no-mistakes"
      if [ "$operation" = resolver ]; then
        printf '%s\n' "$dir/fakebin/no-mistakes" > "$dir/config/nm-home-resolver"
      fi
      set -m
      FM_HOME="$dir" PATH="$dir/fakebin:$PATH" bash -c '
        if [ "$2" = perl ]; then
          command() {
            case "$*" in
              "-v timeout"|"-v gtimeout") return 1 ;;
              *) builtin command "$@" ;;
            esac
          }
        fi
        . "$1/bin/fm-nm-run-lib.sh"
        FM_CHECK_OWNED_GROUP=1
        unset NM_HOME
        fm_nm_run_bounded "$FM_HOME" 30 axi status
      ' _ "$ROOT" "$mechanism" > "$dir/out" 2>&1 &
      owner=$!
      set +m
      i=0
      while [ ! -s "$dir/query-pids" ] && [ "$i" -lt 100 ]; do
        sleep 0.05
        i=$((i + 1))
      done
      mismatch=
      if [ -s "$dir/query-pids" ]; then
        while read -r child; do
          pgid=$(ps -o pgid= -p "$child" | tr -d '[:space:]')
          [ "$pgid" = "$owner" ] || mismatch="$mechanism $operation escaped ownership: $child group $pgid, owner $owner"
        done < "$dir/query-pids"
      else
        mismatch="$mechanism $operation never started: $(cat "$dir/out")"
      fi
      kill -TERM -- "-$owner" 2>/dev/null || true
      wait "$owner" 2>/dev/null || true
      i=0
      while kill -0 -- "-$owner" 2>/dev/null && [ "$i" -lt 20 ]; do
        sleep 0.01
        i=$((i + 1))
      done
      kill -KILL -- "-$owner" 2>/dev/null || true
      if [ -s "$dir/query-pids" ]; then
        while read -r child; do
          status=$(ps -o stat= -p "$child" 2>/dev/null || true)
          case "$status" in
            ''|*Z*) ;;
            *) mismatch="$mechanism $operation descendant $child survived cancellation" ;;
          esac
          kill -KILL "$child" 2>/dev/null || true
        done < "$dir/query-pids"
      fi
      [ -z "$mismatch" ] || fail "$mismatch"
    done
  done
  pass "owned status and resolver queries stay in their cancellable display group"
}

test_bounded_queries_preserve_success() {
  local result
  . "$ROOT/bin/fm-nm-run-lib.sh"
  result=$(FM_CHECK_OWNED_GROUP=1 fm_nm_bounded "$TMP_ROOT" 2 bash -c 'printf result; exit 7')
  [ "$?" -eq 7 ] || fail "owned bounded query lost its exit status"
  [ "$result" = result ] || fail "owned bounded query lost stdout"
  result=$(fm_nm_bounded "$TMP_ROOT" 2 bash -c 'printf standalone; exit 9')
  [ "$?" -eq 9 ] || fail "standalone bounded query lost its exit status"
  [ "$result" = standalone ] || fail "standalone bounded query lost stdout"
  pass "owned and standalone bounded queries preserve stdout and status"
}

fm_test_run test_owned_queries_remain_cancellable test_bounded_queries_preserve_success
