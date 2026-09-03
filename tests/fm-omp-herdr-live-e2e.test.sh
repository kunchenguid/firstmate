#!/usr/bin/env bash
# Opt-in, supervised live candidate for the provisional OMP-on-Herdr adapter.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${FM_OMP_HERDR_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OMP_HERDR_LIVE_E2E=1 for the supervised OMP/Herdr candidate"
  exit 0
fi

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

for tool in herdr jq git treehouse /bin/zsh; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
done
/bin/zsh -lic 'whence -w omp; whence -w ompp' \
  || fail "Mist's omp and ompp zsh wrappers must be installed before this trial"

printf 'herdr_version='; herdr --version
printf 'personal_wrapper='; /bin/zsh -lic 'whence -v omp'
printf 'personal_omp_version='; /bin/zsh -lic 'omp --version'
printf 'sf_wrapper='; /bin/zsh -lic 'whence -v ompp'
printf 'sf_omp_version='; /bin/zsh -lic 'ompp --version'

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-omp-profile-$$"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-omp-herdr-live.XXXXXX") \
  || fail "could not allocate the disposable fixture root"
MARKER="$SCRATCH/.fm-omp-herdr-live-fixture"
: > "$MARKER"
HOME_DIR="$SCRATCH/home"
PROJECT="$SCRATCH/project"
ACTIVE_IDS=()

cleanup() {
  local id resolved base
  for id in "${ACTIVE_IDS[@]:-}"; do
    FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" "$ROOT/bin/fm-teardown.sh" "$id" --force \
      >/dev/null 2>&1 || true
  done
  herdr_safe_stop_and_delete "$SESSION"
  if [ -f "$MARKER" ] && [ ! -L "$SCRATCH" ]; then
    resolved=$(CDPATH='' cd -P -- "$SCRATCH" 2>/dev/null && pwd -P) || resolved=
    base=$(CDPATH='' cd -P -- "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P) || base=
    case "$resolved" in
      "$base"/fm-omp-herdr-live.*) chmod -R u+w -- "$resolved" 2>/dev/null || true; rm -rf -- "$resolved" ;;
    esac
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects" "$PROJECT"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
git -C "$PROJECT" init -q
printf '# OMP live candidate\n' > "$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
  commit -qm initial
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare the isolated Herdr lab"

wait_for_file() { # <path> <seconds>
  local path=$1 remaining=$2
  while [ "$remaining" -gt 0 ]; do
    [ -f "$path" ] && return 0
    sleep 1
    remaining=$((remaining - 1))
  done
  return 1
}

meta_value() { # <meta> <key>
  sed -n "s/^$2=//p" "$1" | tail -1
}

run_profile() { # <personal|sf>
  local profile=$1 id="omp-live-$1-$$" meta worktree sentinel before after out
  ACTIVE_IDS+=("$id")
  mkdir -p "$HOME_DIR/data/$id"
  cat > "$HOME_DIR/data/$id/brief.md" <<EOF
This is a bounded Firstmate adapter verification.
Write exactly the word ready followed by a newline to .fm-omp-live-$profile-ready in this worktree, then stop and wait for the operator.
Do not inspect credentials, authentication stores, sessions, providers, environment variables, or unrelated files.
EOF
  out=$(FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_OMP_HERDR_EXPERIMENTAL=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJECT" --scout --harness omp \
      --profile "$profile" --backend herdr 2>&1) \
    || fail "$profile launch failed: $out"
  case "$out" in *"spawned $id harness=omp profile=$profile"*) ;; *) fail "$profile launch did not report its selected profile" ;; esac
  meta="$HOME_DIR/state/$id.meta"
  [ "$(meta_value "$meta" profile)" = "$profile" ] || fail "$profile launch metadata changed profile"
  worktree=$(meta_value "$meta" worktree)
  before=$(meta_value "$meta" window)
  sentinel="$worktree/.fm-omp-live-$profile-ready"
  wait_for_file "$sentinel" 90 || fail "$profile worker did not produce bounded processing evidence"
  [ "$(cat "$sentinel")" = ready ] || fail "$profile worker produced incorrect processing evidence"

  out=$(FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" "$ROOT/bin/fm-control.sh" "$id" interrupt 2>&1) \
    || fail "$profile interrupt delivery failed: $out"
  case "$out" in *'verified=agent-alive cancel=unconfirmed'*) ;; *) fail "$profile interrupt overstated cancellation evidence: $out" ;; esac

  out=$(FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" "$ROOT/bin/fm-control.sh" "$id" exit 2>&1) \
    || fail "$profile structured exit failed: $out"
  case "$out" in "stopped $id harness=omp backend=herdr"*) ;; *) fail "$profile exit returned an unexpected result: $out" ;; esac

  rm -f -- "$sentinel"
  out=$(FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_OMP_HERDR_EXPERIMENTAL=1 \
    "$ROOT/bin/fm-control.sh" "$id" relaunch --profile "$profile" 2>&1) \
    || fail "$profile relaunch failed: $out"
  after=$(meta_value "$meta" window)
  [ "$after" = "$before" ] || fail "$profile relaunch moved from $before to $after"
  case "$out" in *"relaunched $id harness=omp profile=$profile"*"backend=herdr endpoint=$before"*) ;; *) fail "$profile relaunch result lost its profile or endpoint: $out" ;; esac
  wait_for_file "$sentinel" 90 || fail "$profile relaunched worker did not process in the same pane"
  pass "live OMP candidate: $profile processed, reported unconfirmed cancellation, exited structurally, and relaunched in one pane"

  FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" "$ROOT/bin/fm-control.sh" "$id" exit \
    >/dev/null 2>&1 || fail "$profile final exit failed"
  # The fixture worktree intentionally contains its processing sentinel.  This
  # supervised, disposable trial therefore uses teardown's explicit discard
  # path instead of pretending the scout/report/captain contract was met.
  FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" "$ROOT/bin/fm-teardown.sh" "$id" --force \
    >/dev/null 2>&1 || fail "$profile teardown failed"
  ACTIVE_IDS=()
}

run_profile personal
run_profile sf
pass "live OMP/Herdr candidate completed both Mist profiles"
