#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-bounded-owned)
TIMEOUT_EXECUTABLE=$(type -P timeout || type -P gtimeout || true)
QUERY_MECHANISMS=(default perl)
if [ -n "$TIMEOUT_EXECUTABLE" ]; then
  QUERY_MECHANISMS=(default gtimeout perl)
else
  printf '# GNU timeout backend emulation skipped: timeout and gtimeout unavailable\n'
fi

test_owned_queries_remain_cancellable() {
  local mechanism operation dir owner i child mismatch status
  for mechanism in "${QUERY_MECHANISMS[@]}"; do
    for operation in status resolver; do
      dir="$TMP_ROOT/$mechanism-$operation"
      mkdir -p "$dir/config" "$dir/fakebin"
      if [ "$mechanism" = gtimeout ]; then
        printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$TIMEOUT_EXECUTABLE" > "$dir/fakebin/gtimeout"
        chmod +x "$dir/fakebin/gtimeout"
      fi
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
        if [ "$2" != default ]; then
          mechanism=$2
          command() {
            case "$*" in
              "-v timeout") return 1 ;;
              "-v gtimeout") [ "$mechanism" != perl ] && builtin command "$@" ;;
              *) builtin command "$@" ;;
            esac
          }
        fi
        . "$1/bin/fm-nm-run-lib.sh"
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
      if [ ! -s "$dir/query-pids" ]; then
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
  pass "status and resolver query descendants stop on display cancellation"
}

test_bounded_queries_preserve_success() {
  local result
  . "$ROOT/bin/fm-nm-run-lib.sh"
  result=$(fm_nm_bounded "$TMP_ROOT" 2 bash -c 'printf result; exit 7')
  [ "$?" -eq 7 ] || fail "owned bounded query lost its exit status"
  [ "$result" = result ] || fail "owned bounded query lost stdout"
  result=$(fm_nm_bounded "$TMP_ROOT" 2 bash -c 'printf standalone; exit 9')
  [ "$?" -eq 9 ] || fail "standalone bounded query lost its exit status"
  [ "$result" = standalone ] || fail "standalone bounded query lost stdout"
  pass "owned and standalone bounded queries preserve stdout and status"
}

test_query_timeouts_are_isolated() {
  local mechanism dir result rc started elapsed child status
  for mechanism in "${QUERY_MECHANISMS[@]}"; do
    dir="$TMP_ROOT/timeout-$mechanism"
    mkdir -p "$dir/fakebin"
    if [ "$mechanism" = gtimeout ]; then
      printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$TIMEOUT_EXECUTABLE" > "$dir/fakebin/gtimeout"
      chmod +x "$dir/fakebin/gtimeout"
    fi
    cat > "$dir/query" <<'SCRIPT'
#!/usr/bin/env bash
sleep 30 &
printf '%s\n' "$$" "$!" > "$FM_HOME/query-pids"
wait
SCRIPT
    chmod +x "$dir/query"
    started=$SECONDS
    result=$(FM_HOME="$dir" PATH="$dir/fakebin:$PATH" bash -c '
      if [ "$2" != default ]; then
        mechanism=$2
        command() {
          case "$*" in
            "-v timeout") return 1 ;;
            "-v gtimeout") [ "$mechanism" != perl ] && builtin command "$@" ;;
            *) builtin command "$@" ;;
          esac
        }
      fi
      . "$1/bin/fm-nm-run-lib.sh"
      fm_nm_bounded "$FM_HOME" 1 "$FM_HOME/query"
      rc=$?
      printf "timeout=%s\n" "$rc"
      fm_nm_bounded "$FM_HOME" 2 printf next-query
    ' _ "$ROOT" "$mechanism")
    rc=$?
    elapsed=$((SECONDS - started))
    [ "$rc" -eq 0 ] && [ "$result" = $'timeout=124\nnext-query' ] \
      || fail "$mechanism timeout aborted its caller or lost the failure: $result ($rc)"
    [ "$elapsed" -lt 5 ] || fail "$mechanism query retained stdout after its bound: ${elapsed}s"
    while read -r child; do
      status=$(ps -o stat= -p "$child" 2>/dev/null || true)
      case "$status" in
        ''|*Z*) ;;
        *) kill -KILL "$child" 2>/dev/null || true; fail "$mechanism timeout left descendant $child running" ;;
      esac
    done < "$dir/query-pids"
  done
  pass "expired queries close descendant output and allow the next query"
}

fm_test_run test_owned_queries_remain_cancellable test_bounded_queries_preserve_success test_query_timeouts_are_isolated
