#!/usr/bin/env bash
# Record a PR/MR-ready task: appends pr=<url> and the provider's pr_head=<sha>
# to state/<id>.meta when available, then arms the watcher's poll by writing
# state/<id>.check.sh, which prints one line when firstmate must wake
# (the watcher's check contract: output = wake firstmate, silence = keep sleeping).
# The poll wakes on two signals:
#   - the PR/MR has merged  -> prints "merged"
#   - its CI aggregate is definitively red -> prints "ci-failed", so a red build
#     wakes firstmate even if every other watch has died. This is the last-resort
#     backstop, not a substitute for richer review watches.
# GitHub PRs use gh. Codebase MRs use bytedcli; direct invocations print the
# helper error if the initial head lookup fails.
# The CI-red wake is debounced to fire once per red episode: state/<id>.check.ci
# marks that firstmate was already woken for the current red, and the marker is
# cleared as soon as CI leaves the failing state, so a persistently red PR is not
# re-reported every poll and a later relapse wakes firstmate again.
# The poll never goes silently blind: an unloadable bin/fm-scm-lib.sh, or a
# provider status lookup that keeps failing (missing bytedcli, expired PAT,
# revoked gh auth), wakes firstmate once with a diagnostic and records
# state/<id>.check.error. A lookup must fail FM_CHECK_FAIL_WAKE_AFTER times in a
# row before it wakes, so a transient gh/bytedcli network error stays quiet, and
# any single success resets the count. A CI read that fails is a lookup failure,
# never a red result, so an unreadable status never masquerades as a red build.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
URL=$2
# shellcheck source=bin/fm-scm-lib.sh
. "$SCRIPT_DIR/fm-scm-lib.sh"

fm_scm_parse_pr_url "$URL" >/dev/null || exit 1

META="$STATE/$ID.meta"
if [ -f "$META" ]; then
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  PR_HEAD=
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    if REMOTE_HEAD=$(fm_scm_pr_head "$WT" "$URL"); then
      PR_HEAD=$REMOTE_HEAD
    fi
  fi
  if ! grep -qxF "pr=$URL" "$META"; then
    echo "pr=$URL" >> "$META"
  fi
  if [ -n "$PR_HEAD" ] && ! grep -qxF "pr_head=$PR_HEAD" "$META"; then
    echo "pr_head=$PR_HEAD" >> "$META"
  fi
fi

quoted_url=$(printf "%s\n" "$URL" | sed "s/'/'\\\\''/g")
quoted_lib=$(printf "%s\n" "$FM_ROOT/bin/fm-scm-lib.sh" | sed "s/'/'\\\\''/g")
quoted_marker=$(printf "%s\n" "$STATE/$ID.check.error" | sed "s/'/'\\\\''/g")
quoted_fails=$(printf "%s\n" "$STATE/$ID.check.fails" | sed "s/'/'\\\\''/g")
quoted_ci=$(printf "%s\n" "$STATE/$ID.check.ci" | sed "s/'/'\\\\''/g")
rm -f "$STATE/$ID.check.error" "$STATE/$ID.check.fails" "$STATE/$ID.check.ci"
cat > "$STATE/$ID.check.sh" <<EOF
# shellcheck shell=bash
fm_scm_lib='$quoted_lib'
fm_scm_marker='$quoted_marker'
fm_scm_fails='$quoted_fails'
fm_scm_ci_marker='$quoted_ci'
fm_scm_wake_after=\${FM_CHECK_FAIL_WAKE_AFTER:-3}
case "\$fm_scm_wake_after" in ''|0|*[!0-9]*) fm_scm_wake_after=3 ;; esac

fm_scm_report_broken() {
  [ -e "\$fm_scm_marker" ] && return 0
  : > "\$fm_scm_marker" 2>/dev/null || true
  echo "poll broken: \$1; merge polling for '$quoted_url' is not running"
}

# shellcheck source=bin/fm-scm-lib.sh
if [ ! -r "\$fm_scm_lib" ] || ! . "\$fm_scm_lib"; then
  fm_scm_report_broken "cannot load \$fm_scm_lib"
  exit 0
fi

fails=\$(cat "\$fm_scm_fails" 2>/dev/null || true)
case "\$fails" in ''|*[!0-9]*) fails=0 ;; esac
fails=\$((fails + 1))
printf '%s\n' "\$fails" > "\$fm_scm_fails" 2>/dev/null || true

if state=\$(fm_scm_pr_state "" '$quoted_url' 2>/dev/null); then
  case "\$state" in
    MERGED|merged)
      rm -f "\$fm_scm_fails" "\$fm_scm_ci_marker"
      echo "merged"
      exit 0
      ;;
  esac
  # Not merged: read the CI aggregate. A read failure here is a lookup failure
  # (fail closed), never a red result, so it must NOT reset the failure count -
  # only a read that actually returns a state does.
  if ci=\$(fm_scm_pr_ci_state "" '$quoted_url' 2>/dev/null); then
    rm -f "\$fm_scm_fails"
    case "\$ci" in
      FAILING)
        # Wake once per red episode: mark on the first FAILING read and stay
        # quiet until CI leaves the failing state, which clears the marker below.
        if [ ! -e "\$fm_scm_ci_marker" ]; then
          : > "\$fm_scm_ci_marker" 2>/dev/null || true
          echo "ci-failed"
        fi
        ;;
      *)
        rm -f "\$fm_scm_ci_marker"
        ;;
    esac
    exit 0
  fi
fi

if [ "\$fails" -ge "\$fm_scm_wake_after" ]; then
  fm_scm_report_broken "cannot read PR/MR status after \$fails consecutive lookup failures (check gh/bytedcli auth)"
fi
EOF
echo "armed: state/$ID.check.sh polls $URL"
