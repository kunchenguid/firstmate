#!/usr/bin/env bash
# Put a merged commit live on the machine that serves one project, or put the
# previous one back.
#
# Usage:
#   fm-deploy.sh <project> <sha> [--with-captain-permission "<the captain's words>"]
#   fm-deploy.sh <project> --rollback
#   fm-deploy.sh <project> <sha> --record-live --with-captain-permission "<his words>"
#
# The procedure is the one deploy/PROVISIONING.md and the recorded cutover
# already establish: fetch the new version, prove the start-time requirements it
# makes of the machine, set the current version aside, stop the app, check out
# the exact commit, put the sealed front-end bundle in place, reinstall that one
# unit, verify the bundle, prove the user the app runs as can read it, restart,
# and prove it answers. It never touches the sign-in or TLS units, never reads
# or writes a secrets file, and never forces, stashes, or discards anything.
#
# It refuses, rather than proceeds, when:
#   - the range from what is live to <sha> touches a path the project's deploy
#     policy reserves for the captain, and --with-captain-permission is absent;
#   - --with-captain-permission is given without the captain's own words;
#   - the app is in the middle of a run (its own store lock is held);
#   - the live commit is not an ancestor of <sha>;
#   - the sealed bundle for <sha> cannot be obtained. There is no fallback to a
#     bundle built for some other commit, and the refusal says which of the four
#     reasons it is: no build has appeared for that commit yet, the build is
#     still running, the build finished without succeeding, or the artifact has
#     expired past its retention. The first two are races - a deploy attempted
#     before the commit's own build finished - and say so rather than reporting
#     the bundle as gone;
#   - a start-time requirement <sha>'s own units make of a host-owned file does
#     not hold yet. Those validators run read-only, from <sha>'s own copy, as
#     the user the unit runs as, BEFORE anything is stopped, and the refusal
#     names the validator and the unit that would have refused to start.
#
# The fetch happens before the stop for the same reason: a version the machine
# cannot even obtain must not be discovered after the app is already down.
#
# --rollback needs no captain permission: it restores a version the captain
# already had. Its target is the version the last attempt that REACHED the
# machine came from - a failed deploy included, which is when a rollback is
# actually wanted - and only one whose front end is still set aside under
# rollback_root, so a rollback still works long after the build that produced
# it stopped being downloadable.
#
# --record-live records that <sha> is already live because it was put there by
# hand. It changes nothing on the machine: it refuses unless the machine really
# reports <sha>, and it needs the captain's own words, because it asserts an
# authority this home did not exercise. Its only effect is that the durable
# record stops disagreeing with the machine, so a later rollback aims at the
# version this one actually replaced.
#
# Every attempt, refusal included, is appended to
# state/deploy-ledger/<project>.jsonl.
#
# config/deploy-policy/<project> and config/deploy-target/<project> are both
# required and both LOCAL; docs/configuration.md owns their formats.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-deploy-lib.sh
. "$SCRIPT_DIR/fm-deploy-lib.sh"
# shellcheck source=bin/fm-deploy-target-lib.sh
. "$SCRIPT_DIR/fm-deploy-target-lib.sh"

PROJECT=''
TARGET_SHA=''
PERMISSION=''
ROLLBACK=0
RECORD_LIVE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --with-captain-permission)
      shift
      PERMISSION="${1:-}"
      ;;
    --rollback) ROLLBACK=1 ;;
    --record-live) RECORD_LIVE=1 ;;
    -h | --help)
      sed -n '2,${/^#/!q; s/^# \{0,1\}//; p;}' "$0"
      exit 0
      ;;
    -*)
      printf 'error: unknown option %s\n' "$1" >&2
      exit 2
      ;;
    *)
      if [ -z "$PROJECT" ]; then
        PROJECT=$1
      elif [ -z "$TARGET_SHA" ]; then
        TARGET_SHA=$1
      else
        printf 'error: too many arguments\n' >&2
        exit 2
      fi
      ;;
  esac
  shift
done

[ -n "$PROJECT" ] || { printf 'error: usage: fm-deploy.sh <project> <sha> [--with-captain-permission "<reason>"]\n' >&2; exit 2; }
if [ "$ROLLBACK" -eq 1 ] && [ "$RECORD_LIVE" -eq 1 ]; then
  printf 'error: --rollback puts a version back; --record-live only records one that is already there\n' >&2
  exit 2
fi
if [ "$ROLLBACK" -eq 1 ]; then
  [ -z "$TARGET_SHA" ] || { printf 'error: --rollback takes no sha; it restores the version the last attempt came from\n' >&2; exit 2; }
  [ -z "$PERMISSION" ] || { printf 'error: --rollback needs no captain permission\n' >&2; exit 2; }
elif [ "$RECORD_LIVE" -eq 1 ]; then
  [ -n "$TARGET_SHA" ] || { printf 'error: --record-live needs the commit that is already live\n' >&2; exit 2; }
  [ -n "$PERMISSION" ] || { printf 'error: --record-live records an authority this home did not exercise, so it needs the captain\x27s own words in --with-captain-permission\n' >&2; exit 2; }
else
  [ -n "$TARGET_SHA" ] || { printf 'error: a commit to deploy is required\n' >&2; exit 2; }
fi

LEDGER_DIR="$STATE/deploy-ledger"
LEDGER="$LEDGER_DIR/$PROJECT.jsonl"

# ledger_append <result> <from> <to> <authority> <detail>
# Durable and append-only: a refusal is as much a record as a deploy, so a later
# question about what happened has one place to look.
ledger_append() {
  local result=$1 from=$2 to=$3 authority=$4 detail=$5 line
  mkdir -p "$LEDGER_DIR" 2>/dev/null || return 0
  line=$(printf '{"at":"%s","project":"%s","result":"%s","from":"%s","to":"%s","authority":"%s","detail":"%s"}' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(fm_deploy_json_escape "$PROJECT")" \
    "$(fm_deploy_json_escape "$result")" \
    "$(fm_deploy_json_escape "$from")" \
    "$(fm_deploy_json_escape "$to")" \
    "$(fm_deploy_json_escape "$authority")" \
    "$(fm_deploy_json_escape "$detail")")
  printf '%s\n' "$line" >>"$LEDGER" 2>/dev/null || true
}

refuse() {
  printf 'refused: %s\n' "$1" >&2
  ledger_append refused "${DEPLOYED_SHA:-unknown}" "${TARGET_SHA:-unknown}" "${AUTHORITY:-none}" "$1"
  exit 1
}

# The flag alone is not permission; it must carry what the captain actually
# said, so the ledger records a decision rather than a checkbox.
require_captains_words() {
  case "$PERMISSION" in
    -* | '') refuse "--with-captain-permission needs the captain's own words as its reason" ;;
  esac
  [ "${#PERMISSION}" -ge 8 ] || refuse "--with-captain-permission needs the captain's own words as its reason"
}

POLICY=$(fm_deploy_policy_file "$FM_HOME" "$PROJECT")
fm_deploy_policy_readable "$POLICY" || {
  printf 'error: %s has no deploy policy at %s, so it is not deployable from here\n' "$PROJECT" "$POLICY" >&2
  exit 2
}
fm_deploy_target_load "$FM_HOME" "$PROJECT" || exit 2

REPO="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}/$PROJECT"
[ -d "$REPO/.git" ] || { printf 'error: no local copy of %s at %s\n' "$PROJECT" "$REPO" >&2; exit 2; }

DEPLOYED_SHA=$(fm_deploy_host_sha) || { printf 'error: could not read the live version from the machine serving %s\n' "$PROJECT" >&2; exit 3; }
fm_deploy_sha_valid "$DEPLOYED_SHA" || {
  printf 'error: the machine serving %s is not pinned to a specific commit (it reports %s)\n' "$PROJECT" "$DEPLOYED_SHA" >&2
  exit 3
}

AUTHORITY=auto
if [ "$ROLLBACK" -eq 1 ]; then
  [ -f "$LEDGER" ] || { printf 'error: no deploy has been recorded for %s, so there is nothing to roll back to\n' "$PROJECT" >&2; exit 2; }
  # A rollback is wanted most after a deploy that FAILED, and that attempt set
  # the outgoing version aside before it stopped anything just as a completed
  # one does. Take the newest attempt that reached the machine and whose copy is
  # still there, rather than only a completed deploy: requiring a completed one
  # made the tool useless in exactly the case it exists for.
  probed=''
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    probed="$probed $candidate"
    fm_deploy_ssh "sudo test -d '$FM_DEPLOY_TGT_rollback_root/$candidate'" </dev/null 2>/dev/null \
      || continue
    if [ -n "$FM_DEPLOY_TGT_bundle_path" ]; then
      fm_deploy_ssh "sudo test -d '$FM_DEPLOY_TGT_rollback_root/$candidate/bundle'" </dev/null 2>/dev/null \
        || continue
    fi
    TARGET_SHA=$candidate
    break
  done < <(fm_deploy_ledger_rollback_candidates "$LEDGER")
  if [ -z "$TARGET_SHA" ]; then
    if [ -n "$probed" ]; then
      printf 'error: %s has recorded attempts, but the machine no longer holds a set-aside copy of any version they came from (%s), so there is nothing to roll back to\n' \
        "$PROJECT" "${probed# }" >&2
    else
      printf 'error: no attempt that reached the machine is recorded for %s, so there is nothing to roll back to\n' "$PROJECT" >&2
    fi
    exit 2
  fi
  AUTHORITY=rollback
  printf 'Rolling %s back to %s, the version the last attempt that reached the machine came from.\n' "$PROJECT" "$TARGET_SHA"
else
  TARGET_SHA=$(git -C "$REPO" rev-parse --verify --quiet "$TARGET_SHA^{commit}" 2>/dev/null) \
    || { printf 'error: %s is not a commit in the local copy of %s\n' "$TARGET_SHA" "$PROJECT" >&2; exit 2; }
fi

# Catching up the record on a version restored by hand. This is settled before
# the already-live comparison below, because being already live is the whole
# precondition it asserts, not a reason to do nothing.
if [ "$RECORD_LIVE" -eq 1 ]; then
  AUTHORITY=captain
  require_captains_words
  [ "$DEPLOYED_SHA" = "$TARGET_SHA" ] \
    || refuse "the machine serving $PROJECT reports $DEPLOYED_SHA, not $TARGET_SHA, so that version is not what is live"
  ledger_append recorded-live '' "$TARGET_SHA" captain "$PERMISSION"
  printf '%s is recorded as live at %s. Nothing on the machine was changed.\n' "$PROJECT" "$TARGET_SHA"
  exit 0
fi

if [ "$DEPLOYED_SHA" = "$TARGET_SHA" ]; then
  printf '%s is already live at %s; nothing to do.\n' "$PROJECT" "$TARGET_SHA"
  exit 0
fi

# --- the captain's gate -------------------------------------------------------
# Rollback restores a version the captain already had live, so it is not a new
# shipment and does not consult the policy.
if [ "$ROLLBACK" -eq 0 ]; then
  classify_rc=0
  fm_deploy_classify "$REPO" "$DEPLOYED_SHA" "$TARGET_SHA" "$POLICY" || classify_rc=$?
  [ "$classify_rc" -ne 2 ] || refuse "what is live for $PROJECT is not on the main line of work, so this cannot be a straight update"
  [ "$classify_rc" -eq 0 ] || refuse "could not work out what would change for $PROJECT"

  if [ "$FM_DEPLOY_CAPTAIN_COUNT" -gt 0 ]; then
    if [ -z "$PERMISSION" ]; then
      printf 'These changes need your permission before they go live:\n' >&2
      printf '%s' "$FM_DEPLOY_CAPTAIN" | sort -u -t'	' -k2 | while IFS='	' read -r pattern path; do
        [ -n "$path" ] || continue
        printf '  - %s (a design surface you asked to approve: %s)\n' "$path" "$pattern" >&2
      done
      refuse "$FM_DEPLOY_CAPTAIN_COUNT change(s) in this update touch design surfaces the captain reserved"
    fi
    AUTHORITY=captain
  fi
fi
if [ -n "$PERMISSION" ]; then
  require_captains_words
  AUTHORITY=captain
fi

# --- refuse mid-run -----------------------------------------------------------
# The app's own store lock is the authority on "a run is happening". This reads
# /proc/locks and takes no lock of its own, so asking the question can never be
# what makes a starting run fail.
if [ -n "$FM_DEPLOY_TGT_run_lock" ]; then
  busy=$(fm_deploy_ssh "sudo sh -c 'L='\''$FM_DEPLOY_TGT_run_lock'\''; if [ ! -e \"\$L\" ]; then echo idle; exit 0; fi; s=\$(stat -c \"%Hd %Ld %i\" \"\$L\") || exit 1; set -- \$s; t=\$(printf \"%02x:%02x:%d\" \"\$1\" \"\$2\" \"\$3\"); if grep -qE \"[[:space:]]\$t[[:space:]]\" /proc/locks; then echo busy; else echo idle; fi'") \
    || refuse "could not tell whether $PROJECT is in the middle of a run, so nothing was changed"
  case "$busy" in
    idle) ;;
    busy) refuse "$PROJECT is in the middle of a run; deploying now would interrupt it" ;;
    *) refuse "could not tell whether $PROJECT is in the middle of a run, so nothing was changed" ;;
  esac
fi

# --- obtain the sealed bundle for this exact commit ---------------------------
CO="$FM_DEPLOY_TGT_checkout"
UNIT="$FM_DEPLOY_TGT_unit"
PRECHECK_DIR="$FM_DEPLOY_TGT_rollback_root/.precheck-$TARGET_SHA"
PRECHECK_MADE=0
BUNDLE_DIR=''
BUNDLE_NEEDED=0
SAVED_BUNDLE=0

# Both scratch copies go away on every exit, refusals included, so a refused
# deploy leaves nothing of its own behind on either side.
cleanup() {
  [ -z "$BUNDLE_DIR" ] || rm -rf "$BUNDLE_DIR"
  [ "$PRECHECK_MADE" -eq 0 ] || fm_deploy_ssh "sudo rm -rf '$PRECHECK_DIR'" </dev/null >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [ -n "$FM_DEPLOY_TGT_bundle_path" ]; then
  # A rollback returns to a version this machine already ran, and the front end
  # it ran with was copied aside at that time. Prefer that copy: builds stay
  # downloadable only briefly, so by the time a rollback is wanted the build for
  # that commit is usually gone, and keeping the copy is the whole reason a
  # rollback is one command rather than a rebuild.
  if [ "$ROLLBACK" -eq 1 ] \
    && fm_deploy_ssh "sudo test -d '$FM_DEPLOY_TGT_rollback_root/$TARGET_SHA/bundle'" 2>/dev/null; then
    SAVED_BUNDLE=1
    printf 'The front-end %s ran with is still set aside on the machine; using it.\n' "$TARGET_SHA"
  elif git -C "$REPO" cat-file -e "$TARGET_SHA:$FM_DEPLOY_TGT_bundle_path" 2>/dev/null; then
    printf 'The front-end bundle is part of %s itself; nothing to fetch.\n' "$TARGET_SHA"
  else
    BUNDLE_NEEDED=1
    GH_REPO=$(git -C "$REPO" remote get-url origin 2>/dev/null | sed -e 's#^git@[^:]*:##' -e 's#^https\{0,1\}://[^/]*/##' -e 's#\.git$##')
    [ -n "$GH_REPO" ] || refuse "cannot tell which GitHub repository $PROJECT publishes its build to"
    BUNDLE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-deploy-bundle.XXXXXX")
    run_id=$(gh run list --repo "$GH_REPO" --workflow "$FM_DEPLOY_TGT_bundle_workflow" \
      --json databaseId,headSha --limit 100 2>/dev/null \
      | sed -n 's/.*"databaseId":\([0-9]*\),"headSha":"'"$TARGET_SHA"'".*/\1/p' | head -1) || true
    if [ -z "$run_id" ]; then
      run_id=$(gh run list --repo "$GH_REPO" --workflow "$FM_DEPLOY_TGT_bundle_workflow" \
        --json databaseId,headSha --limit 100 -q \
        ".[] | select(.headSha==\"$TARGET_SHA\") | .databaseId" 2>/dev/null | head -1) || true
    fi
    # A deploy that follows a merge can arrive before that commit's own build
    # does. Asking the run for its state is what separates "not yet" from
    # "gone": both leave nothing to download, and only one of them is a
    # problem. Saying the wrong one sends the captain looking for a broken
    # build that is merely a few minutes behind.
    [ -n "$run_id" ] || refuse "no build has appeared yet for $TARGET_SHA, so its front-end bundle cannot be obtained; if the commit only just merged, its build has not started"
    run_state=$(gh run view "$run_id" --repo "$GH_REPO" --json status,conclusion \
      -q '"\(.status) \(.conclusion)"' 2>/dev/null) || run_state=''
    case "$run_state" in
      completed*) ;;
      '') ;; # the run's state could not be read; fall through to the download
      *) refuse "the build for $TARGET_SHA has not finished yet (it is ${run_state%% *}), so its front-end bundle does not exist to download; it can go live once that build finishes" ;;
    esac
    case "$run_state" in
      'completed success') ;;
      completed*) refuse "the build for $TARGET_SHA finished without succeeding (${run_state#* }), so it produced no front-end bundle to deploy" ;;
    esac
    gh run download "$run_id" --repo "$GH_REPO" -n "$FM_DEPLOY_TGT_bundle_artifact" -D "$BUNDLE_DIR" >/dev/null 2>&1 \
      || refuse "the front-end bundle built for $TARGET_SHA is no longer available for download (builds are kept only briefly), and this machine cannot build one"
    [ -n "$(ls -A "$BUNDLE_DIR" 2>/dev/null)" ] || refuse "the downloaded front-end bundle for $TARGET_SHA is empty"
  fi
fi

# --- prove what the new version requires of the machine ------------------------
# The units gate their own start on validators that read host-owned files: an
# operator allow-list, a pinned binary. Those files are not in the repository
# and do not arrive with the release, so a version that starts requiring one the
# machine does not have takes the stack down at start - after the app has
# already been stopped, which is exactly how a dashboard came back while the
# sign-in stack stayed down. Asking first costs a fetch and a read.
#
# The validators come from the TARGET commit, not the one the machine still has,
# extracted read-only beside the rollback copies. Each runs as the user its own
# unit runs as: the allow-list validator requires the file to be owned by the
# euid opening it, so a root-run check would answer a question nobody asked.
#
# The scratch path is named for the commit rather than drawn from mktemp, which
# is safe because the `rm -rf` below runs before the `install -d` and the
# extraction: a symlink planted at that name is removed rather than followed,
# so nothing is written through it. rollback_root itself is trusted exactly as
# far as the set-aside step already trusts it, and no further.
fm_deploy_ssh "sudo git -C '$CO' fetch origin" \
  || refuse "could not fetch $TARGET_SHA onto the machine, so nothing was changed"

PRECONDITIONS=$(fm_deploy_preconditions "$REPO" "$TARGET_SHA" "$CO" "$PRECHECK_DIR")
mapfile -t PRECHECKS < <(printf '%s\n' "$PRECONDITIONS" | grep "^check	" || true)
PRECHECK_SKIPPED=$(printf '%s\n' "$PRECONDITIONS" | grep -c "^skip	" || true)
if [ "${#PRECHECKS[@]}" -gt 0 ]; then
  archive_dirs=$(printf '%s\n' "${PRECHECKS[@]}" | tr '[:blank:]' '\n' \
    | sed -n "s#^$PRECHECK_DIR/\([^/]*\)/.*#\1#p" | sort -u | tr '\n' ' ')
  PRECHECK_MADE=1
  fm_deploy_ssh "sudo sh -c 'rm -rf \"$PRECHECK_DIR\" && install -d -o root -g root -m 0755 \"$FM_DEPLOY_TGT_rollback_root\" \"$PRECHECK_DIR\" && git -C \"$CO\" archive '$TARGET_SHA' $archive_dirs | tar -C \"$PRECHECK_DIR\" -x && chmod -R a+rX \"$PRECHECK_DIR\"'" </dev/null \
    || refuse "could not read what $TARGET_SHA requires of the machine, so nothing was changed"

  for precheck in "${PRECHECKS[@]}"; do
    pc_rest=${precheck#*	}
    pc_unit=${pc_rest%%	*}
    pc_rest=${pc_rest#*	}
    pc_user=${pc_rest%%	*}
    pc_cmd=${pc_rest#*	}
    pc_what=$(printf '%s\n' "$pc_cmd" | tr ' ' '\n' | sed -n "s#^$PRECHECK_DIR/##p" | head -1)
    [ -n "$pc_what" ] || pc_what=$pc_cmd
    # A user the machine does not have yet reads nothing like a validator that
    # ran and said no, so it must not be reported as one.
    fm_deploy_ssh "sudo id -u '$pc_user'" </dev/null >/dev/null 2>&1 \
      || refuse "$TARGET_SHA starts ${pc_unit##*/} as the user $pc_user, and the machine has no such user; nothing was changed"
    pc_err=$(fm_deploy_ssh "sudo -u '$pc_user' $pc_cmd" </dev/null 2>&1) \
      || refuse "${pc_unit##*/} will not start until $pc_what passes on this machine, and it does not yet: ${pc_err:-it gave no reason}. Nothing was changed"
  done
  printf 'Checked %d start-time requirement(s) of %s against files this machine owns; all hold.\n' \
    "${#PRECHECKS[@]}" "$TARGET_SHA"
fi
# What was NOT proved is said out loud: silence here would read as "all of it
# holds" when it means "the rest can only be answered once it is running".
[ "$PRECHECK_SKIPPED" -eq 0 ] || printf '%d further start-time requirement(s) of %s can only be answered once it is running, and were not checked first.\n' \
  "$PRECHECK_SKIPPED" "$TARGET_SHA"

# --- perform the update -------------------------------------------------------
ROLLBACK_DIR="$FM_DEPLOY_TGT_rollback_root/$DEPLOYED_SHA"

printf 'Taking %s from %s to %s.\n' "$PROJECT" "$DEPLOYED_SHA" "$TARGET_SHA"

# Keep the outgoing version recoverable before anything changes: its commit is
# already in the ledger, and its bundle is copied aside because a bundle built
# for it may be past its download retention by the time it is wanted back.
fm_deploy_ssh "sudo install -d -o root -g root -m 0755 '$FM_DEPLOY_TGT_rollback_root' '$ROLLBACK_DIR'" \
  || refuse "could not set aside the current version of $PROJECT for a rollback, so nothing was changed"
if [ -n "$FM_DEPLOY_TGT_bundle_path" ]; then
  fm_deploy_ssh "sudo sh -c 'if [ -d \"$CO/$FM_DEPLOY_TGT_bundle_path\" ] && [ ! -d \"$ROLLBACK_DIR/bundle\" ]; then cp -a \"$CO/$FM_DEPLOY_TGT_bundle_path\" \"$ROLLBACK_DIR/bundle\" && chmod -R a+rX \"$ROLLBACK_DIR/bundle\"; fi'" \
    || refuse "could not set aside the current front-end of $PROJECT for a rollback, so nothing was changed"
fi

fm_deploy_ssh "sudo systemctl stop '$UNIT'" || refuse "could not stop $PROJECT to update it"

step_failed() {
  printf 'The update failed part way through: %s\n' "$1" >&2
  printf 'To put the previous version back, run: bin/fm-deploy.sh %s --rollback\n' "$PROJECT" >&2
  ledger_append failed "$DEPLOYED_SHA" "$TARGET_SHA" "$AUTHORITY" "$1"
  exit 1
}

fm_deploy_ssh "sudo git -C '$CO' checkout --detach '$TARGET_SHA'" || step_failed "could not switch the machine to $TARGET_SHA"

if [ "$BUNDLE_NEEDED" -eq 1 ]; then
  tar -C "$BUNDLE_DIR" -czf - . \
    | fm_deploy_ssh "sudo sh -c 'rm -rf \"$CO/$FM_DEPLOY_TGT_bundle_path.incoming\" && install -d -o root -g root -m 0755 \"$CO/$FM_DEPLOY_TGT_bundle_path.incoming\" && tar -C \"$CO/$FM_DEPLOY_TGT_bundle_path.incoming\" -xzf - && chmod -R a+rX \"$CO/$FM_DEPLOY_TGT_bundle_path.incoming\" && rm -rf \"$CO/$FM_DEPLOY_TGT_bundle_path\" && mv \"$CO/$FM_DEPLOY_TGT_bundle_path.incoming\" \"$CO/$FM_DEPLOY_TGT_bundle_path\" && chown -R root:root \"$CO/$FM_DEPLOY_TGT_bundle_path\"'" \
    || step_failed "could not install the front-end bundle for $TARGET_SHA"
elif [ "$SAVED_BUNDLE" -eq 1 ]; then
  fm_deploy_ssh "sudo sh -c 'rm -rf \"$CO/$FM_DEPLOY_TGT_bundle_path\" && cp -a \"$FM_DEPLOY_TGT_rollback_root/$TARGET_SHA/bundle\" \"$CO/$FM_DEPLOY_TGT_bundle_path\" && chmod -R a+rX \"$CO/$FM_DEPLOY_TGT_bundle_path\"'" \
    || step_failed "could not put the previous front-end bundle back"
fi

# The bundle verifier below runs as root, and root reads a bundle no service
# user can. That gap is the whole of it: a 0700 bundle directory passed the
# root-run check and then the unit's own start-time verifier could not open the
# seal inside it. Ask the question from the only perspective that decides
# whether the app starts.
UNIT_USER=$(fm_deploy_unit_user "$REPO" "$TARGET_SHA" "$FM_DEPLOY_UNIT_DIR/$UNIT.service")
if [ -n "$FM_DEPLOY_TGT_bundle_path" ] && [ -n "$UNIT_USER" ]; then
  unreadable=$(fm_deploy_ssh "sudo -u '$UNIT_USER' find '$CO/$FM_DEPLOY_TGT_bundle_path' '!' -readable -print" </dev/null 2>&1) || unreadable=${unreadable:-the front end could not be listed at all}
  [ -z "$unreadable" ] \
    || step_failed "the front end for $TARGET_SHA is on the machine, but $UNIT_USER, the user $UNIT runs as, cannot read all of it: $(printf '%s' "$unreadable" | head -3 | tr '\n' ' ')"
fi

fm_deploy_ssh "sudo install -o root -g root -m 0644 '$CO/$FM_DEPLOY_UNIT_DIR/$UNIT.service' '/etc/systemd/system/$UNIT.service' && sudo systemctl daemon-reload" \
  || step_failed "could not reinstall how $PROJECT is started"

if [ -n "$FM_DEPLOY_TGT_bundle_verify" ]; then
  fm_deploy_ssh "sudo '$FM_DEPLOY_TGT_python' -B '$CO/$FM_DEPLOY_TGT_bundle_verify'" \
    || step_failed "the front-end bundle on the machine did not pass the project's own check"
fi

fm_deploy_ssh "sudo systemctl restart '$UNIT'" || step_failed "$PROJECT would not start on the new version"

# --- prove it answers ---------------------------------------------------------
health=$(fm_deploy_ssh "curl -s -o /dev/null -w '%{http_code}' --max-time 20 '$FM_DEPLOY_TGT_health_url'" 2>/dev/null || true)
[ "$health" = 200 ] || step_failed "$PROJECT restarted but did not report itself healthy (it answered $health)"

public=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 "$FM_DEPLOY_TGT_public_url" 2>/dev/null || true)
[ "$public" = "$FM_DEPLOY_TGT_public_expect" ] || step_failed "the sign-in protected address answered $public instead of $FM_DEPLOY_TGT_public_expect"

if [ "$ROLLBACK" -eq 1 ]; then
  ledger_append rolled-back "$DEPLOYED_SHA" "$TARGET_SHA" "$AUTHORITY" 'restored the version the last attempt came from'
else
  ledger_append deployed "$DEPLOYED_SHA" "$TARGET_SHA" "$AUTHORITY" "${PERMISSION:-}"
fi
printf '%s is live at %s. Health check and the sign-in protected address both answered as expected.\n' "$PROJECT" "$TARGET_SHA"
printf 'To put the previous version back: bin/fm-deploy.sh %s --rollback\n' "$PROJECT"
