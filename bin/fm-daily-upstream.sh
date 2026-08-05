#!/usr/bin/env bash
# Guarded daily upstream assessment, pinned safe-update, public-channel metadata,
# deterministic morning-report, and per-user LaunchAgent deployment owner.
#
# The scheduled 04:00 collection phase assesses exact upstream candidates,
# applies only the official Firstmate and explicitly opted-in registered-project
# fast-forwards authorized by their existing owners, records report-only supply
# chain opportunities, and publishes a private typed receipt.
# The scheduled 08:00 report phase renders that receipt, posts a best-effort local
# notification, and registers one authenticated custom check so an existing live
# Firstmate session can synthesize it.
# No command here launches a Firstmate session, updates packages or services,
# downloads video media, merges, deploys, restarts, stashes, resets, or forces.
#
# Private schema owner:
#   data/daily-upstream/receipts/*.receipt  FIRSTMATE_DAILY_UPSTREAM_RECEIPT_V1
#   data/daily-upstream/reports/*.md        deterministic rendered reports
#   data/daily-upstream/channel-last-seen  validated public YouTube video id
#   data/daily-upstream/retention.index     epoch<TAB>owned-relative-path
#   state/daily-upstream/report-offers.index id<TAB>owned-report-relative-path
#   state/daily-upstream/report-offer.notified epoch<TAB>last-offered-report-id
# Exact mechanics and flags are documented by --help below.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA_ROOT="$FM_HOME/data/daily-upstream"
STATE_ROOT="$FM_HOME/state/daily-upstream"
RECEIPTS="$DATA_ROOT/receipts"
REPORTS="$DATA_ROOT/reports"
RETENTION_INDEX="$DATA_ROOT/retention.index"
CHANNEL_SEEN="$DATA_ROOT/channel-last-seen"
OFFERS="$STATE_ROOT/report-offers.index"
OFFER_STAMP="$STATE_ROOT/report-offer.notified"
CHECK_FILE="$FM_HOME/state/daily-upstream-report.check.sh"
CHECK_TRUST="$FM_HOME/state/daily-upstream-report.check-trust"
RUN_LOCK="$STATE_ROOT/run.lock"
RUN_TMP=
LOCK_OWNED=0
MAX_COMMITS=${FM_DAILY_MAX_COMMITS:-50}
MAX_PROJECTS=${FM_DAILY_MAX_PROJECTS:-100}
NETWORK_TIMEOUT=${FM_DAILY_NETWORK_TIMEOUT_SECS:-30}

umask 077

usage() {
  cat <<'EOF'
Usage:
  fm-daily-upstream.sh detect
  fm-daily-upstream.sh assess
  fm-daily-upstream.sh collect
  fm-daily-upstream.sh report
  fm-daily-upstream.sh show-report <report-id>
  fm-daily-upstream.sh acknowledge <report-id>
  fm-daily-upstream.sh install
  fm-daily-upstream.sh verify-install
  fm-daily-upstream.sh uninstall
  fm-daily-upstream.sh cleanup --keep-days <days>
  fm-daily-upstream.sh recover-lock --older-than-seconds <seconds>
  fm-daily-upstream.sh --help

Commands:
  detect          Read local prerequisites and deployment state without network
                  access, repository writes, or private-state writes.
  assess          Collect and publish the same bounded evidence as the 04:00 job
                  without applying any repository fast-forward.
  collect         Run the 04:00 collection and mechanically authorized pinned
                  fast-forwards, then publish a typed private receipt.
  report          Run the 08:00 deterministic morning report, best-effort local
                  notification, and authenticated Firstmate check registration.
                  A scheduled report extends its lock wait only while a live
                  collection owns the lock, and otherwise records an explicit
                  deferral instead of failing without an explanation.
                  A pending report is re-offered to the watcher on a bounded
                  cadence rather than on every sweep.
  show-report ID  Print one exact pending private report for synthesis.
  acknowledge ID  Retire one exact report offer after successful synthesis.
  install         Idempotently write, but never load, two per-user LaunchAgent
                  definitions for 04:00 and 08:00 local calendar time.
  verify-install  Require byte-exact safe definitions, ownership, mode, calendar
                  triggers, and valid plist syntax without invoking launchctl.
  uninstall       Remove both definitions only when both still match exactly.
                  It never unloads a live job or changes unrelated launchd state.
  cleanup         Explicitly remove only indexed, validated receipt/report files
                  older than DAYS and never remove a pending report.
  recover-lock    Preserve and move aside one exact dead run lock only after its
                  age exceeds SECONDS, which must be at least 3600.

Safety:
  The Mac local timezone and install target must be America/Sao_Paulo.
  Collection uses one exact candidate SHA per repository and refuses origin
  movement between assessment and application.
  Firstmate updates accept only the official kunchenguid/firstmate origin.
  Project updates require a registered +daily-sync posture and are blocked by
  local-only, +production, unknown posture, dirty, off-default, diverged,
  missing/red checks, or ambiguous provenance.
  The channel monitor reads only public @kunchenguid metadata over HTTPS and
  never uses a browser profile, cookie, login, or media download.
  LaunchAgent installation, verification, and removal never call launchctl.
EOF
}

safe_number() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
}

sha_valid() {
  case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#1}" -eq 40 ]
}

name_valid() {
  case "$1" in ''|.|..|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 128 ]
}

report_id_valid() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 96 ]
}

path_nlink() {
  if [ "$(uname 2>/dev/null || echo unknown)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

path_uid() {
  if [ "$(uname 2>/dev/null || echo unknown)" = Darwin ]; then
    stat -f %u "$1" 2>/dev/null
  else
    stat -c %u "$1" 2>/dev/null
  fi
}

path_mode() {
  if [ "$(uname 2>/dev/null || echo unknown)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

path_mtime() {
  if [ "$(uname 2>/dev/null || echo unknown)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

private_file_valid() {
  local path=$1 mode=${2:-600} links owner actual_mode
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  links=$(path_nlink "$path") || return 1
  [ "$links" = 1 ] || return 1
  owner=$(path_uid "$path") || return 1
  [ "$owner" = "$(id -u)" ] || return 1
  actual_mode=$(path_mode "$path") || return 1
  [ "$actual_mode" = "$mode" ]
}

receipt_valid() {
  local path=$1 size date_line
  private_file_valid "$path" 600 || return 1
  size=$(wc -c < "$path" 2>/dev/null | tr -d ' ') || return 1
  safe_number "$size" && [ "$size" -le 1048576 ] || return 1
  [ "$(sed -n '1p' "$path")" = FIRSTMATE_DAILY_UPSTREAM_RECEIPT_V1 ] || return 1
  date_line=$(sed -n '2p' "$path")
  case "$date_line" in local-date=????-??-??) ;;
    *) return 1 ;;
  esac
}

safe_existing_destination() {
  local path=$1 mode=${2:-600}
  [ ! -e "$path" ] && [ ! -L "$path" ] && return 0
  private_file_valid "$path" "$mode"
}

ensure_dir() {
  local path=$1 resolved parent
  [ ! -L "$path" ] || return 1
  if [ ! -e "$path" ]; then
    parent=$(dirname "$path")
    [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
    mkdir "$path" || return 1
  fi
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  chmod 700 "$path" || return 1
  resolved=$(cd "$path" && pwd -P) || return 1
  case "$resolved" in
    "$(cd "$FM_HOME" && pwd -P)"/*) ;;
    *) return 1 ;;
  esac
}

validate_home_roots() {
  local home_real root
  [ -d "$FM_HOME" ] && [ ! -L "$FM_HOME" ] || return 1
  home_real=$(cd "$FM_HOME" && pwd -P) || return 1
  [ "$home_real" != / ] || return 1
  for root in "$FM_HOME/data" "$FM_HOME/state"; do
    [ ! -L "$root" ] || return 1
    if [ -e "$root" ]; then
      [ -d "$root" ] || return 1
    fi
  done
}

init_private() {
  validate_home_roots || {
    echo "refused: private home layout is unsafe" >&2
    return 1
  }
  [ -d "$FM_HOME/data" ] || mkdir "$FM_HOME/data"
  [ -d "$FM_HOME/state" ] || mkdir "$FM_HOME/state"
  if ! ensure_dir "$DATA_ROOT" || ! ensure_dir "$STATE_ROOT" || ! ensure_dir "$RECEIPTS" || ! ensure_dir "$REPORTS"; then
    echo "refused: private daily-upstream layout is unsafe" >&2
    return 1
  fi
}

atomic_publish() {
  local source=$1 dest=$2 mode=${3:-600} dir tmp
  dir=$(dirname "$dest")
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  safe_existing_destination "$dest" "$mode" || return 1
  tmp=$(mktemp "$dir/.daily-upstream.publish.XXXXXX") || return 1
  if ! cat "$source" > "$tmp" || ! chmod "$mode" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  safe_existing_destination "$dest" "$mode" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$dest"
}

atomic_text() {
  local dest=$1 mode=$2 text=$3 source
  source=$(mktemp "$STATE_ROOT/.daily-upstream.text.XXXXXX") || return 1
  printf '%s' "$text" > "$source" || { rm -f -- "$source"; return 1; }
  chmod "$mode" "$source" || { rm -f -- "$source"; return 1; }
  atomic_publish "$source" "$dest" "$mode"
  rm -f -- "$source"
}

cleanup_runtime() {
  local owner
  if [ "$LOCK_OWNED" -eq 1 ]; then
    owner=$(cat "$RUN_LOCK/pid" 2>/dev/null || true)
    if [ "$owner" = "${BASHPID:-$$}" ] && [ -d "$RUN_LOCK" ] && [ ! -L "$RUN_LOCK" ]; then
      rm -f -- "$RUN_LOCK/pid" "$RUN_LOCK/action" 2>/dev/null || true
      rmdir "$RUN_LOCK" 2>/dev/null || true
    fi
    LOCK_OWNED=0
  fi
  if [ -n "$RUN_TMP" ] && [ -d "$RUN_TMP" ] && [ ! -L "$RUN_TMP" ]; then
    case "$RUN_TMP" in "$STATE_ROOT"/.run.*) rm -rf -- "$RUN_TMP" ;; esac
  fi
  RUN_TMP=
}

trap cleanup_runtime EXIT HUP INT TERM

acquire_lock() {
  local action=$1 wait=${2:-0} elapsed=0
  safe_number "$wait" || wait=0
  while ! mkdir "$RUN_LOCK" 2>/dev/null; do
    [ -d "$RUN_LOCK" ] && [ ! -L "$RUN_LOCK" ] || {
      echo "refused: run lock path is unsafe" >&2
      return 1
    }
    if [ "$elapsed" -ge "$wait" ]; then
      echo "busy: another daily-upstream run owns this home"
      return 75
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  chmod 700 "$RUN_LOCK" || return 1
  printf '%s\n' "${BASHPID:-$$}" > "$RUN_LOCK/pid"
  printf '%s\n' "$action" > "$RUN_LOCK/action"
  chmod 600 "$RUN_LOCK/pid" "$RUN_LOCK/action"
  LOCK_OWNED=1
  RUN_TMP=$(mktemp -d "$STATE_ROOT/.run.XXXXXX") || return 1
  chmod 700 "$RUN_TMP"
}

collection_lock_live() {
  local action pid
  [ -d "$RUN_LOCK" ] && [ ! -L "$RUN_LOCK" ] || return 1
  private_file_valid "$RUN_LOCK/action" 600 || return 1
  private_file_valid "$RUN_LOCK/pid" 600 || return 1
  action=$(sed -n '1p' "$RUN_LOCK/action")
  [ "$action" = collect ] || return 1
  pid=$(sed -n '1p' "$RUN_LOCK/pid")
  safe_number "$pid" || return 1
  kill -0 "$pid" 2>/dev/null
}

bounded_capture() {
  local output=$1 seconds=$2
  shift 2
  : > "$output"
  chmod 600 "$output"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@" > "$output" 2>/dev/null
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; waitpid $pid, 0; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$seconds" "$@" > "$output" 2>/dev/null
  else
    return 125
  fi
}

gh_capture() {
  local output=$1
  shift
  command -v gh-axi >/dev/null 2>&1 || return 127
  bounded_capture "$output" "$NETWORK_TIMEOUT" env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh-axi "$@"
}

local_date() {
  if [ "${FM_DAILY_TEST_MODE:-0}" = 1 ] && [ -n "${FM_DAILY_TEST_DATE:-}" ]; then
    printf '%s\n' "$FM_DAILY_TEST_DATE"
  else
    date +%F
  fi
}

local_epoch() {
  if [ "${FM_DAILY_TEST_MODE:-0}" = 1 ] && safe_number "${FM_DAILY_TEST_EPOCH:-}"; then
    printf '%s\n' "$FM_DAILY_TEST_EPOCH"
  else
    date +%s
  fi
}

local_timezone() {
  local link
  if [ "${FM_DAILY_TEST_MODE:-0}" = 1 ] && [ -n "${FM_DAILY_TEST_TIMEZONE:-}" ]; then
    printf '%s\n' "$FM_DAILY_TEST_TIMEZONE"
    return
  fi
  link=$(readlink /etc/localtime 2>/dev/null || true)
  case "$link" in
    */zoneinfo/*) printf '%s\n' "${link##*/zoneinfo/}" ;;
    *) printf '%s\n' unknown ;;
  esac
}

require_timezone() {
  [ "$(local_timezone)" = America/Sao_Paulo ] || {
    echo "refused: local timezone is not America/Sao_Paulo" >&2
    return 1
  }
}

origin_literal_parse() {
  local value=$1 rest
  GH_OWNER=
  GH_REPO=
  case "$value" in
    https://github.com/*/*)
      rest=${value#https://github.com/}
      ;;
    git@github.com:*/*)
      rest=${value#git@github.com:}
      ;;
    ssh://git@github.com/*/*)
      rest=${value#ssh://git@github.com/}
      ;;
    *) return 1 ;;
  esac
  rest=${rest%.git}
  GH_OWNER=${rest%%/*}
  GH_REPO=${rest#*/}
  [ "$GH_OWNER" != "$rest" ] || return 1
  case "$GH_OWNER$GH_REPO" in *[!A-Za-z0-9_.-]*|'') return 1 ;; esac
  case "$GH_REPO" in */*) return 1 ;; esac
}

github_origin_identity() {
  local dir=$1 configured resolved count
  configured=$(git -C "$dir" config --get-all remote.origin.url 2>/dev/null) || return 1
  count=$(printf '%s\n' "$configured" | awk 'NF { n++ } END { print n+0 }')
  [ "$count" -eq 1 ] || return 1
  origin_literal_parse "$configured" || return 1
  [ -z "$(git -C "$dir" config --get-all remote.origin.uploadpack 2>/dev/null || true)" ] || return 1
  resolved=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 1
  if [ "$resolved" != "$configured" ]; then
    [ "${FM_DAILY_TEST_MODE:-0}" = 1 ] && [ "${FM_DAILY_TEST_ALLOW_URL_REWRITE:-0}" = 1 ] || return 1
  fi
}

github_default_branch() {
  local owner=$1 repo=$2 output branch
  output="$RUN_TMP/repo-default.$owner.$repo"
  gh_capture "$output" api GET "/repos/$owner/$repo" --jq '.default_branch' || return 1
  branch=$(sed -n '1p' "$output")
  case "$branch" in ''|.*|*[!A-Za-z0-9._/-]*) return 1 ;; esac
  [ "${#branch}" -le 128 ] || return 1
  printf '%s\n' "$branch"
}

fetch_candidate() {
  local dir=$1 default=$2 output=$3
  bounded_capture "$output" "$NETWORK_TIMEOUT" git -C "$dir" fetch --no-tags origin "+refs/heads/$default:refs/remotes/origin/$default" || return 1
  git -C "$dir" rev-parse --verify "refs/remotes/origin/$default^{commit}" 2>/dev/null
}

RANGE_STATUS=unknown
RANGE_CHECKS=unknown
RANGE_RISK=high
RANGE_SURFACES=unknown
RANGE_COMMITS=0
RANGE_PRS=0
RANGE_PR_LIST=none

assess_range() {
  local dir=$1 owner=$2 repo=$3 base=$4 candidate=$5 default=$6
  local commits files commit_count file_count surfaces risk commit output lines line number merge_sha valid_count
  local prs checks_out status_out check_total check_bad status_total status_state bad=0 missing=0 pr_numbers=
  RANGE_STATUS=unknown
  RANGE_CHECKS=unknown
  RANGE_RISK=high
  RANGE_SURFACES=unknown
  RANGE_COMMITS=0
  RANGE_PRS=0
  RANGE_PR_LIST=none

  commits="$RUN_TMP/range-commits.$repo"
  files="$RUN_TMP/range-files.$repo"
  git -C "$dir" rev-list --reverse "$base..$candidate" > "$commits" 2>/dev/null || return 1
  commit_count=$(awk 'NF { n++ } END { print n+0 }' "$commits")
  RANGE_COMMITS=$commit_count
  [ "$commit_count" -le "$MAX_COMMITS" ] || { RANGE_STATUS=range-too-large; return 0; }
  if [ "$commit_count" -eq 0 ]; then
    RANGE_STATUS=current
    RANGE_CHECKS=not-needed
    RANGE_RISK=low
    RANGE_SURFACES=none
    return 0
  fi

  git -C "$dir" diff --name-only "$base" "$candidate" > "$files" 2>/dev/null || return 1
  file_count=$(awk 'NF { n++ } END { print n+0 }' "$files")
  [ "$file_count" -le 500 ] || { RANGE_STATUS=surface-too-large; return 0; }
  surfaces=
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      AGENTS.md|bin/*|.agents/skills/*|.claude/*|.codex/*|.grok/*|.opencode/*|.pi/*) surfaces="$surfaces runtime" ;;
      .github/workflows/*|*auth*|*credential*|*secret*|*security*|*permission*|*fm-pr-*|*fm-lock*) surfaces="$surfaces security" ;;
      *migrat*|*schema*) surfaces="$surfaces migration" ;;
      package.json|package-lock.json|pnpm-lock.yaml|yarn.lock|go.mod|go.sum|Cargo.toml|Cargo.lock|Gemfile|Gemfile.lock|requirements*.txt|pyproject.toml) surfaces="$surfaces dependencies" ;;
      *launch*|*deploy*|*service*|*install*|*restart*) surfaces="$surfaces deployment" ;;
      docs/*|README.md|CONTRIBUTING.md|tests/*) surfaces="$surfaces docs-tests" ;;
      *) surfaces="$surfaces code" ;;
    esac
  done < "$files"
  surfaces=$(printf '%s\n' "$surfaces" | tr ' ' '\n' | awk 'NF && !seen[$0]++ { out=out (out?",":"") $0 } END { print out?out:"none" }')
  risk=low
  case ",$surfaces," in *,security,*|*,migration,*|*,dependencies,*|*,deployment,*) risk=high ;; *,runtime,*|*,code,*) risk=medium ;; esac
  RANGE_RISK=$risk
  RANGE_SURFACES=$surfaces

  prs="$RUN_TMP/range-prs.$repo"
  : > "$prs"
  while IFS= read -r commit; do
    sha_valid "$commit" || { RANGE_STATUS=provenance-unknown; return 0; }
    output="$RUN_TMP/commit-pr.$commit"
    if ! gh_capture "$output" api GET "/repos/$owner/$repo/commits/$commit/pulls" --jq ".[] | select(.merged_at != null and .base.ref == \"$default\") | [.number,.merge_commit_sha] | @tsv"; then
      RANGE_STATUS=provenance-unknown
      return 0
    fi
    lines=$(awk 'NF { n++ } END { print n+0 }' "$output")
    [ "$lines" -eq 1 ] || { RANGE_STATUS=provenance-ambiguous; return 0; }
    line=$(sed -n '1p' "$output")
    number=${line%%	*}
    merge_sha=${line#*	}
    if ! safe_number "$number" || ! sha_valid "$merge_sha"; then
      RANGE_STATUS='provenance-unknown'
      return 0
    fi
    git -C "$dir" merge-base --is-ancestor "$base" "$merge_sha" 2>/dev/null || { RANGE_STATUS=provenance-contradictory; return 0; }
    git -C "$dir" merge-base --is-ancestor "$merge_sha" "$candidate" 2>/dev/null || { RANGE_STATUS=provenance-contradictory; return 0; }
    printf '%s\t%s\n' "$number" "$merge_sha" >> "$prs"
  done < "$commits"
  awk -F '\t' '!seen[$1]++' "$prs" > "$prs.unique"
  mv "$prs.unique" "$prs"
  valid_count=$(awk 'NF { n++ } END { print n+0 }' "$prs")
  RANGE_PRS=$valid_count

  while IFS=$(printf '\t') read -r number merge_sha; do
    [ -n "$number" ] || continue
    checks_out="$RUN_TMP/check-runs.$merge_sha"
    status_out="$RUN_TMP/status.$merge_sha"
    if ! gh_capture "$checks_out" api GET "/repos/$owner/$repo/commits/$merge_sha/check-runs" --jq '[.total_count, ([.check_runs[] | select(.status != "completed" or .conclusion != "success")] | length)] | @tsv'; then
      RANGE_STATUS='checks-unknown'
      return 0
    fi
    if ! gh_capture "$status_out" api GET "/repos/$owner/$repo/commits/$merge_sha/status" --jq '[.total_count,.state] | @tsv'; then
      RANGE_STATUS='checks-unknown'
      return 0
    fi
    line=$(sed -n '1p' "$checks_out")
    check_total=${line%%	*}
    check_bad=${line#*	}
    line=$(sed -n '1p' "$status_out")
    status_total=${line%%	*}
    status_state=${line#*	}
    if ! safe_number "$check_total" || ! safe_number "$check_bad" || ! safe_number "$status_total"; then
      RANGE_STATUS='checks-unknown'
      return 0
    fi
    if [ "$check_total" -eq 0 ] && [ "$status_total" -eq 0 ]; then
      missing=1
    fi
    [ "$check_bad" -eq 0 ] || bad=1
    if [ "$status_total" -gt 0 ] && [ "$status_state" != success ]; then
      bad=1
    fi
    pr_numbers="$pr_numbers${pr_numbers:+,}#$number"
  done < "$prs"
  RANGE_PR_LIST=${pr_numbers:-none}
  if [ "$bad" -eq 1 ]; then
    RANGE_STATUS='checks-red'
    RANGE_CHECKS=red
  elif [ "$missing" -eq 1 ]; then
    RANGE_STATUS='checks-missing'
    RANGE_CHECKS=missing
  else
    RANGE_STATUS=eligible
    RANGE_CHECKS=green
  fi
}

receipt_line() {
  local key=$1 value=$2
  value=$(printf '%s' "$value" | LC_ALL=C tr '\t\r\n' '   ' | cut -c1-1000)
  printf '%s=%s\n' "$key" "$value" >> "$WORK_RECEIPT"
}

receipt_section() {
  printf '[%s]\n' "$1" >> "$WORK_RECEIPT"
}

summarize_repo() {
  local label=$1 action=$2 candidate=$3 status=$4 risk=$5 surfaces=$6 checks=$7 prs=$8
  local short=none
  sha_valid "$candidate" && short=${candidate:0:12}
  receipt_line summary "$label: $action; candidate $short; assessment $status; checks $checks; risk $risk ($surfaces); PRs $prs."
}

collect_firstmate() {
  local apply=$1 owner repo default candidate base branch dirty relation action update_out update_rc=0 secondmate_skips=0
  receipt_section firstmate
  if [ ! -d "$FM_ROOT/.git" ] && ! git -C "$FM_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    receipt_line action report-only:not-a-repository
    receipt_line summary "Firstmate: report-only because its repository is unavailable."
    return
  fi
  if ! github_origin_identity "$FM_ROOT" || [ "$GH_OWNER" != kunchenguid ] || [ "$GH_REPO" != firstmate ]; then
    receipt_line action report-only:unofficial-origin
    receipt_line summary "Firstmate: report-only because exact official-origin identity was not proven."
    return
  fi
  owner=$GH_OWNER
  repo=$GH_REPO
  default=$(github_default_branch "$owner" "$repo" || true)
  if [ -z "$default" ]; then
    receipt_line action report-only:default-branch-unknown
    receipt_line summary "Firstmate: report-only because the official default branch was not proven."
    return
  fi
  candidate=$(fetch_candidate "$FM_ROOT" "$default" "$RUN_TMP/firstmate-fetch" || true)
  if ! sha_valid "$candidate"; then
    receipt_line action report-only:fetch-failed
    receipt_line summary "Firstmate: report-only because the exact candidate could not be fetched."
    return
  fi
  base=$(git -C "$FM_ROOT" rev-parse HEAD 2>/dev/null || true)
  branch=$(git -C "$FM_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  dirty=no
  [ -z "$(git -C "$FM_ROOT" status --porcelain 2>/dev/null | head -1)" ] || dirty=yes
  relation=safe
  if [ "$branch" != "$default" ]; then
    relation=off-default
  elif [ "$dirty" = yes ]; then
    relation=dirty
  elif ! git -C "$FM_ROOT" merge-base --is-ancestor "$base" "$candidate" 2>/dev/null; then
    relation=diverged
  fi
  if [ "$relation" = diverged ]; then
    RANGE_STATUS=local-divergence
    RANGE_CHECKS=unknown
    RANGE_RISK=high
    RANGE_SURFACES=unknown
    RANGE_COMMITS=0
    RANGE_PRS=0
    RANGE_PR_LIST=none
  else
    assess_range "$FM_ROOT" "$owner" "$repo" "$base" "$candidate" "$default" || RANGE_STATUS=assessment-failed
  fi
  action=report-only:$relation
  if [ "$RANGE_STATUS" = current ]; then
    action=current
  elif [ "$relation" = safe ] && [ "$RANGE_STATUS" = eligible ]; then
    if [ "$apply" = yes ]; then
      update_out="$RUN_TMP/firstmate-update.out"
      set +e
      bounded_capture "$update_out" 180 env FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_DAILY_TEST_MODE="${FM_DAILY_TEST_MODE:-0}" FM_DAILY_TEST_ALLOW_URL_REWRITE="${FM_DAILY_TEST_ALLOW_URL_REWRITE:-0}" "$SCRIPT_DIR/fm-update.sh" --expected-sha "$candidate"
      update_rc=$?
      set -e
      if grep -Eq '^firstmate: (updated|already current)' "$update_out" 2>/dev/null && [ "$update_rc" -eq 0 ]; then
        secondmate_skips=$(grep -Ec '^secondmate .*: skipped:' "$update_out" 2>/dev/null || true)
        if [ "$secondmate_skips" -gt 0 ]; then action=applied-with-secondmate-skips; else action=applied; fi
      else
        action=refused:pinned-update
      fi
    else
      action='report-only:eligible'
    fi
  else
    action=report-only:$relation-$RANGE_STATUS
  fi
  receipt_line base "$base"
  receipt_line candidate "$candidate"
  receipt_line local-state "$relation"
  receipt_line assessment "$RANGE_STATUS"
  receipt_line checks "$RANGE_CHECKS"
  receipt_line risk "$RANGE_RISK"
  receipt_line surfaces "$RANGE_SURFACES"
  receipt_line commits "$RANGE_COMMITS"
  receipt_line pr-count "$RANGE_PRS"
  receipt_line prs "$RANGE_PR_LIST"
  receipt_line rollback forward-fix-only
  receipt_line action "$action"
  summarize_repo Firstmate "$action" "$candidate" "$RANGE_STATUS" "$RANGE_RISK" "$RANGE_SURFACES" "$RANGE_CHECKS" "$RANGE_PR_LIST"
}

collect_one_project() {
  local name=$1 posture=$2 apply=$3 dir owner repo default candidate base branch dirty relation action sync_out sync_rc=0
  receipt_section project
  receipt_line name "$name"
  receipt_line posture "$posture"
  dir="$FM_HOME/projects/$name"
  if [ "$posture" != eligible ]; then
    receipt_line action "$posture"
    receipt_line summary "Project $name: $posture and untouched."
    return
  fi
  if [ ! -d "$dir" ] || [ -L "$dir" ]; then
    receipt_line action report-only:absent
    receipt_line summary "Project $name: report-only because its registered copy is absent."
    return
  fi
  if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    receipt_line action report-only:not-a-repository
    receipt_line summary "Project $name: report-only because its registered copy is not a repository."
    return
  fi
  if ! github_origin_identity "$dir"; then
    receipt_line action report-only:origin-ambiguous
    receipt_line summary "Project $name: report-only because its GitHub origin identity is ambiguous."
    return
  fi
  owner=$GH_OWNER
  repo=$GH_REPO
  default=$(github_default_branch "$owner" "$repo" || true)
  if [ -z "$default" ]; then
    receipt_line action report-only:default-branch-unknown
    receipt_line summary "Project $name: report-only because its default branch is unknown."
    return
  fi
  candidate=$(fetch_candidate "$dir" "$default" "$RUN_TMP/project-fetch.$name" || true)
  if ! sha_valid "$candidate"; then
    receipt_line action report-only:fetch-failed
    receipt_line summary "Project $name: report-only because its exact candidate could not be fetched."
    return
  fi
  base=$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)
  branch=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  dirty=no
  [ -z "$(git -C "$dir" status --porcelain 2>/dev/null | head -1)" ] || dirty=yes
  relation=safe
  if [ "$branch" != "$default" ]; then
    relation=off-default
  elif [ "$dirty" = yes ]; then
    relation=dirty
  elif ! git -C "$dir" merge-base --is-ancestor "$base" "$candidate" 2>/dev/null; then
    relation=diverged
  fi
  if [ "$relation" = diverged ]; then
    RANGE_STATUS=local-divergence
    RANGE_CHECKS=unknown
    RANGE_RISK=high
    RANGE_SURFACES=unknown
    RANGE_COMMITS=0
    RANGE_PRS=0
    RANGE_PR_LIST=none
  else
    assess_range "$dir" "$owner" "$repo" "$base" "$candidate" "$default" || RANGE_STATUS=assessment-failed
  fi
  action=report-only:$relation
  if [ "$RANGE_STATUS" = current ]; then
    action=current
  elif [ "$relation" = safe ] && [ "$RANGE_STATUS" = eligible ]; then
    if [ "$apply" = yes ]; then
      sync_out="$RUN_TMP/project-sync.$name"
      set +e
      bounded_capture "$sync_out" 180 env FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_PROJECTS_OVERRIDE="$FM_HOME/projects" FM_DATA_OVERRIDE="$FM_HOME/data" FM_FLEET_PRUNE=0 "$SCRIPT_DIR/fm-fleet-sync.sh" --expected-target "$candidate" "$name"
      sync_rc=$?
      set -e
      if [ "$sync_rc" -eq 0 ] && grep -Eq "^$name: (synced|already current)" "$sync_out" 2>/dev/null; then
        action=applied
      else
        action=refused:pinned-update
      fi
    else
      action='report-only:eligible'
    fi
  else
    action=report-only:$relation-$RANGE_STATUS
  fi
  receipt_line base "$base"
  receipt_line candidate "$candidate"
  receipt_line local-state "$relation"
  receipt_line assessment "$RANGE_STATUS"
  receipt_line checks "$RANGE_CHECKS"
  receipt_line risk "$RANGE_RISK"
  receipt_line surfaces "$RANGE_SURFACES"
  receipt_line commits "$RANGE_COMMITS"
  receipt_line pr-count "$RANGE_PRS"
  receipt_line prs "$RANGE_PR_LIST"
  receipt_line rollback forward-fix-only
  receipt_line action "$action"
  summarize_repo "Project $name" "$action" "$candidate" "$RANGE_STATUS" "$RANGE_RISK" "$RANGE_SURFACES" "$RANGE_CHECKS" "$RANGE_PR_LIST"
}

collect_projects() {
  local registry="$FM_HOME/data/projects.md" count=0 line name posture registered_names="$RUN_TMP/registered-projects" unregistered=0 dir base
  : > "$registered_names"
  if [ ! -f "$registry" ] || [ -L "$registry" ]; then
    receipt_section projects
    receipt_line action report-only:registry-absent-or-unsafe
    receipt_line summary "Projects: no safe registry was available, so no project copy was inspected or changed."
    return
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    name=$(printf '%s\n' "$line" | awk '{print $2}')
    name_valid "$name" || {
      receipt_section project
      receipt_line action report-only:invalid-registry-name
      receipt_line summary "Projects: one ambiguous registry entry was left untouched."
      continue
    }
    count=$((count + 1))
    if [ "$count" -gt "$MAX_PROJECTS" ]; then
      receipt_section projects
      receipt_line action report-only:registry-limit
      receipt_line summary "Projects: registry limit reached, and remaining entries were left untouched."
      break
    fi
    printf '%s\n' "$name" >> "$registered_names"
    posture=$(env FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_DATA_OVERRIDE="$FM_HOME/data" "$SCRIPT_DIR/fm-project-mode.sh" --upstream-posture "$name" 2>/dev/null || echo report-only:ambiguous-posture)
    collect_one_project "$name" "$posture" "$APPLY_UPDATES"
  done < "$registry"

  if [ -d "$FM_HOME/projects" ] && [ ! -L "$FM_HOME/projects" ]; then
    while IFS= read -r dir; do
      base=$(basename "$dir")
      grep -Fxq -- "$base" "$registered_names" 2>/dev/null || unregistered=$((unregistered + 1))
      [ "$unregistered" -le 200 ] || break
    done < <(find "$FM_HOME/projects" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -201)
  fi
  receipt_section projects
  receipt_line registered-count "$count"
  receipt_line unregistered-copy-count "$unregistered"
  if [ "$unregistered" -gt 0 ]; then
    receipt_line summary "Projects: $unregistered unregistered immediate project copies were counted only and left untouched."
  fi
}

collect_supply_chain() {
  local output count rc
  receipt_section supply-chain
  output="$RUN_TMP/softwareupdate"
  if [ "${FM_DAILY_TEST_MODE:-0}" != 1 ] && [ -x /usr/sbin/softwareupdate ]; then
    if bounded_capture "$output" "$NETWORK_TIMEOUT" /usr/sbin/softwareupdate --list; then
      count=$(grep -Ec '^[[:space:]]*\* Label:' "$output" 2>/dev/null || true)
      receipt_line macos "report-only:opportunities-$count"
      receipt_line summary "macOS: $count update opportunities reported; none installed and restart implications remain operator-owned."
    else
      receipt_line macos report-only:unknown
      receipt_line summary "macOS: update availability could not be determined; nothing was changed."
    fi
  else
    receipt_line macos report-only:unavailable
  fi

  output="$RUN_TMP/brew-outdated"
  if command -v brew >/dev/null 2>&1; then
    if bounded_capture "$output" "$NETWORK_TIMEOUT" env HOMEBREW_NO_AUTO_UPDATE=1 brew outdated --json=v2; then
      count=$(perl -0777 -ne '$n=()=/"name"\s*:/g; print $n' "$output" 2>/dev/null || echo unknown)
      receipt_line homebrew "report-only:opportunities-$count"
      receipt_line summary "Homebrew: $count outdated entries reported; none installed or upgraded."
    else
      receipt_line homebrew report-only:unknown
    fi
  else
    receipt_line homebrew report-only:unavailable
  fi

  output="$RUN_TMP/npm-outdated"
  if command -v npm >/dev/null 2>&1; then
    set +e
    bounded_capture "$output" "$NETWORK_TIMEOUT" npm outdated --global --json
    rc=$?
    set -e
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
      count=$(perl -MJSON::PP -0777 -ne 'eval { $o=decode_json($_); print scalar(keys %$o) }; exit 1 if $@' "$output" 2>/dev/null || echo unknown)
      receipt_line global-packages "report-only:opportunities-$count"
      receipt_line summary "Global packages: $count update opportunities reported; none installed or upgraded."
    else
      receipt_line global-packages report-only:unknown
    fi
  else
    receipt_line global-packages report-only:unavailable
  fi
  receipt_line applications report-only:not-assessed
  receipt_line browser-extensions report-only:not-assessed
  receipt_line project-dependencies report-only:not-assessed
  receipt_line production-services report-only:not-assessed
  receipt_line summary "Applications, browser extensions, project dependencies, credentials, backups, and production services remained report-only and untouched."
}

xml_unescape_titles() {
  perl -CS -pe 's/&amp;/&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&#39;/'"'"'/g'
}

channel_feed_fetch() {
  local page="$RUN_TMP/channel-page" feed="$RUN_TMP/channel-feed" channel_id curl_bin
  if [ "${FM_DAILY_TEST_MODE:-0}" = 1 ] && [ -n "${FM_DAILY_TEST_CHANNEL_FEED:-}" ]; then
    [ -f "$FM_DAILY_TEST_CHANNEL_FEED" ] && [ ! -L "$FM_DAILY_TEST_CHANNEL_FEED" ] || return 1
    cp "$FM_DAILY_TEST_CHANNEL_FEED" "$feed"
    printf '%s\n' "$feed"
    return 0
  fi
  curl_bin=$(command -v curl 2>/dev/null || true)
  [ -n "$curl_bin" ] || return 1
  bounded_capture "$page" "$NETWORK_TIMEOUT" "$curl_bin" --fail --silent --location --connect-timeout 5 --max-time 20 --max-filesize 2097152 --proto '=https' --proto-redir '=https' --user-agent 'FirstmateDailyUpstream/1.0' 'https://www.youtube.com/@kunchenguid/videos' || return 1
  channel_id=$(grep -Eo '"(channelId|externalId)":"UC[A-Za-z0-9_-]{20,30}"' "$page" | head -1 | sed 's/.*:"//;s/"$//' || true)
  case "$channel_id" in UC[A-Za-z0-9_-]*) ;; *) return 1 ;; esac
  [ "${#channel_id}" -le 32 ] || return 1
  bounded_capture "$feed" "$NETWORK_TIMEOUT" "$curl_bin" --fail --silent --location --connect-timeout 5 --max-time 20 --max-filesize 1048576 --proto '=https' --proto-redir '=https' --user-agent 'FirstmateDailyUpstream/1.0' "https://www.youtube.com/feeds/videos.xml?channel_id=$channel_id" || return 1
  printf '%s\n' "$feed"
}

collect_channel() {
  local feed entries pending entry last_seen='' newest='' status=unknown found=0 count=0 id published title safe_title next_seen=''
  receipt_section channel
  feed=$(channel_feed_fetch || true)
  if [ -z "$feed" ]; then
    receipt_line status unavailable
    receipt_line summary "Kun Chen channel: public upload metadata was unavailable; no browser, login, cookie, or media download was used."
    return
  fi
  entries="$RUN_TMP/channel-entries"
  perl -0777 -ne '
    my $n=0;
    while (/<entry>(.*?)<\/entry>/sg && $n < 15) {
      my $e=$1;
      my ($id)=$e=~m{<yt:videoId>([A-Za-z0-9_-]{6,32})</yt:videoId>};
      my ($published)=$e=~m{<published>([^<]{1,64})</published>};
      my ($title)=$e=~m{<title>(.*?)</title>}s;
      next unless defined $id && defined $published && defined $title;
      $title =~ s/[\t\r\n]+/ /g;
      $title =~ s/\s+/ /g;
      $title=substr($title,0,200);
      print "$id\t$published\t$title\n";
      $n++;
    }
  ' "$feed" > "$entries" 2>/dev/null || true
  newest=$(awk -F '\t' 'NR==1 {print $1}' "$entries")
  case "$newest" in ''|*[!A-Za-z0-9_-]*)
    receipt_line status malformed
    receipt_line summary "Kun Chen channel: public metadata was malformed and no last-seen state changed."
    return
    ;;
  esac
  if [ -e "$CHANNEL_SEEN" ] || [ -L "$CHANNEL_SEEN" ]; then
    if ! private_file_valid "$CHANNEL_SEEN" 600; then
      receipt_line status state-unsafe
      receipt_line summary "Kun Chen channel: last-seen state was unsafe, so it was preserved and no upload was marked seen."
      return
    fi
    last_seen=$(sed -n '1p' "$CHANNEL_SEEN")
    case "$last_seen" in ''|*[!A-Za-z0-9_-]*)
      receipt_line status state-invalid
      receipt_line summary "Kun Chen channel: last-seen identity was invalid, so it was preserved."
      return
      ;;
    esac
  fi
  if [ -z "$last_seen" ]; then
    status=initialized
    next_seen=$newest
  elif [ "$last_seen" = "$newest" ]; then
    status=current
  else
    pending="$RUN_TMP/channel-pending"
    : > "$pending"
    chmod 600 "$pending"
    while IFS=$(printf '\t') read -r id published title; do
      [ -n "$id" ] || continue
      if [ "$id" = "$last_seen" ]; then found=1; break; fi
      count=$((count + 1))
      safe_title=$(printf '%s' "$title" | xml_unescape_titles | LC_ALL=C tr '\t\r\n' '   ' | cut -c1-200)
      printf '%s\n' "$id|$published|$safe_title|https://www.youtube.com/watch?v=$id" >> "$pending"
    done < "$entries"
    if [ "$found" -eq 1 ]; then
      status=new
      next_seen=$newest
      while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        receipt_line channel-entry "$entry"
      done < "$pending"
    else
      status=history-gap
      count=0
    fi
  fi
  receipt_line status "$status"
  receipt_line new-upload-count "$count"
  case "$status" in
    initialized) receipt_line summary "Kun Chen channel: initialized at the newest public upload without replaying history." ;;
    current) receipt_line summary "Kun Chen channel: no new public upload metadata." ;;
    new) receipt_line summary "Kun Chen channel: $count new public uploads are ready for Firstmate relevance decisions; no media was downloaded." ;;
    history-gap) receipt_line summary "Kun Chen channel: the prior identity fell outside the bounded feed, so state was preserved, no upload was falsely deduplicated, and no metadata was surfaced; monitoring stays gapped until the captain resolves the last-seen identity." ;;
  esac
  CHANNEL_NEXT_SEEN=$next_seen
}

retention_add() {
  local relative=$1 epoch old="$RUN_TMP/retention-old" new="$RUN_TMP/retention-new"
  case "$relative" in receipts/*.receipt|reports/*.md) ;; *) return 1 ;; esac
  epoch=$(local_epoch)
  if [ -e "$RETENTION_INDEX" ] || [ -L "$RETENTION_INDEX" ]; then
    private_file_valid "$RETENTION_INDEX" 600 || return 1
    cp "$RETENTION_INDEX" "$old"
  else
    : > "$old"
  fi
  awk -F '\t' -v p="$relative" '$2 != p' "$old" > "$new"
  printf '%s\t%s\n' "$epoch" "$relative" >> "$new"
  atomic_publish "$new" "$RETENTION_INDEX" 600
}

run_collection() {
  local mode=$1 today epoch receipt_name receipt_dest latest channel_next=${CHANNEL_NEXT_SEEN:-}
  require_timezone
  init_private
  acquire_lock "$mode" 0
  today=$(local_date)
  epoch=$(local_epoch)
  if [ "$mode" = collect ]; then
    receipt_name="$today.receipt"
    APPLY_UPDATES=yes
    if [ -e "$RECEIPTS/$receipt_name" ] || [ -L "$RECEIPTS/$receipt_name" ]; then
      receipt_valid "$RECEIPTS/$receipt_name" || { echo "refused: today's receipt path is unsafe" >&2; return 1; }
      echo "collection=already-published"
      return 0
    fi
  else
    receipt_name="$today-assess-$epoch.receipt"
    APPLY_UPDATES=no
  fi
  WORK_RECEIPT="$RUN_TMP/$receipt_name"
  {
    printf 'FIRSTMATE_DAILY_UPSTREAM_RECEIPT_V1\n'
    printf 'local-date=%s\n' "$today"
    printf 'timezone=America/Sao_Paulo\n'
    printf 'mode=%s\n' "$mode"
    printf 'started-epoch=%s\n' "$epoch"
  } > "$WORK_RECEIPT"
  chmod 600 "$WORK_RECEIPT"
  CHANNEL_NEXT_SEEN=
  collect_firstmate "$APPLY_UPDATES"
  collect_projects
  collect_supply_chain
  collect_channel
  receipt_section completion
  receipt_line completed-epoch "$(local_epoch)"
  receipt_line safety "No package, application, dependency, credential, backup, extension, service, deployment, restart, or media update was performed."
  receipt_dest="$RECEIPTS/$receipt_name"
  atomic_publish "$WORK_RECEIPT" "$receipt_dest" 600 || { echo "refused: receipt publication failed safely" >&2; return 1; }
  latest="$DATA_ROOT/latest.receipt"
  atomic_publish "$WORK_RECEIPT" "$latest" 600 || { echo "refused: latest receipt publication failed safely" >&2; return 1; }
  retention_add "receipts/$receipt_name" || { echo "refused: retention index publication failed safely" >&2; return 1; }
  channel_next=$CHANNEL_NEXT_SEEN
  if [ -n "$channel_next" ]; then
    atomic_text "$CHANNEL_SEEN" 600 "$channel_next" || { echo "refused: channel state publication failed safely" >&2; return 1; }
  fi
  echo "collection=published"
}

receipt_field() {
  local receipt=$1 key=$2
  awk -v k="$key=" 'index($0,k)==1 { print substr($0,length(k)+1); exit }' "$receipt"
}

report_from_receipt() {
  local receipt=$1 output=$2 today=$3 receipt_date=${4:-} receipt_mode=${5:-}
  case "$receipt_date" in ????-??-??) ;; *) receipt_date=unknown ;; esac
  case "$receipt_mode" in collect|assess) ;; *) receipt_mode=unknown ;; esac
  {
    printf '# Firstmate morning upstream report\n\n'
    printf 'Report date: %s.\n' "$today"
    if [ -z "$receipt" ]; then
      printf 'Evidence source: none, because no safe collection receipt was available.\n\n'
    elif [ "$receipt_date" = "$today" ] && [ "$receipt_mode" = collect ]; then
      printf 'Evidence source: the %s collection receipt.\n\n' "$today"
    else
      printf 'Evidence source: an earlier %s receipt dated %s, so no collection is claimed for %s.\n\n' "$receipt_mode" "$receipt_date" "$today"
    fi
    printf '## Deterministic findings\n\n'
    if [ -n "$receipt" ]; then
      awk 'index($0,"summary=")==1 { print "- " substr($0,9) }' "$receipt"
    else
      printf '%s\n' '- No safe collection receipt was available, so no update conclusion is claimed.'
    fi
    if [ -n "$receipt" ]; then
      awk -F '=' '
        index($0,"channel-entry=")==1 {
          value=substr($0,index($0,"=")+1)
          split(value,a,"|")
          if (a[1] ~ /^[A-Za-z0-9_-]+$/ && a[2] !~ /[\t\r\n]/) {
            print "- New public upload metadata: video " a[1] ", published " a[2] ", https://www.youtube.com/watch?v=" a[1] "."
          }
        }
      ' "$receipt"
    fi
    printf '\n## Safety boundary\n\n'
    printf '%s\n' '- The scheduled owner did not install packages, update applications or dependencies, change credentials or backups, alter services, deploy, restart, merge, or download video media.'
    printf '%s\n' '- Every repository application was pinned to the exact assessed SHA and retained the authoritative fast-forward guards.'
    printf '%s\n' '- Rollback is forward-fix-only because this scheduler never resets or rewrites history, so risky changes require a reviewed corrective commit.'
    printf '%s\n' "- A channel upload is metadata for a later Firstmate relevance decision, and any later analysis remains owned by the accepted \`/watch\` capability."
  } > "$output"
  chmod 600 "$output"
}

queue_report_offer() {
  local id=$1 relative=$2 old="$RUN_TMP/offers-old" new="$RUN_TMP/offers-new"
  if [ -e "$OFFERS" ] || [ -L "$OFFERS" ]; then
    private_file_valid "$OFFERS" 600 || return 1
    cp "$OFFERS" "$old"
  else
    : > "$old"
  fi
  if awk -F '\t' -v id="$id" '$1==id { found=1 } END { exit !found }' "$old"; then
    return 0
  fi
  cp "$old" "$new"
  printf '%s\t%s\n' "$id" "$relative" >> "$new"
  atomic_publish "$new" "$OFFERS" 600
}

write_report_check() {
  local tmp="$RUN_TMP/report-check" home_abs
  home_abs=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || return 1
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '# Auto-generated by fm-daily-upstream.sh - pending morning-report offer.'
    printf '%s\n' '# The watcher runs this from a validated snapshot with no inherited environment,'
    printf '%s\n' '# so the exact owning home is bound here rather than assumed.'
    printf 'export FM_HOME=%q\n' "$home_abs"
    cat <<'SH'
set -eu
home=${FM_HOME:?}
dir="$home/state/daily-upstream"
offers="$dir/report-offers.index"
stamp="$dir/report-offer.notified"
[ -d "$dir" ] && [ ! -L "$dir" ] || exit 0

private_file() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  if [ "$(uname 2>/dev/null || echo unknown)" = Darwin ]; then
    links=$(stat -f %l "$1" 2>/dev/null || echo 0)
    mode=$(stat -f %Lp "$1" 2>/dev/null || echo 0)
    owner=$(stat -f %u "$1" 2>/dev/null || echo -1)
  else
    links=$(stat -c %h "$1" 2>/dev/null || echo 0)
    mode=$(stat -c %a "$1" 2>/dev/null || echo 0)
    owner=$(stat -c %u "$1" 2>/dev/null || echo -1)
  fi
  [ "$links" = 1 ] && [ "$mode" = 600 ] && [ "$owner" = "$(id -u)" ]
}

private_file "$offers" || exit 0
line=$(sed -n '1p' "$offers")
id=${line%%	*}
case "$id" in ''|*[!A-Za-z0-9._-]*) exit 0 ;; esac
[ "${#id}" -le 96 ] || exit 0

# A pending report is re-offered on a bounded cadence so an unacknowledged
# report cannot wake the primary on every watcher sweep.
interval=${FM_DAILY_REPORT_REOFFER_SECS:-1800}
case "$interval" in ''|*[!0-9]*) interval=1800 ;; esac
now=$(date +%s)
last_epoch=0
last_id=
if private_file "$stamp"; then
  line=$(sed -n '1p' "$stamp")
  last_epoch=${line%%	*}
  last_id=${line#*	}
  case "$last_epoch" in ''|*[!0-9]*) last_epoch=0; last_id= ;; esac
fi
if [ "$last_id" = "$id" ] && [ "$now" -ge "$last_epoch" ] && [ "$((now - last_epoch))" -lt "$interval" ]; then
  exit 0
fi
umask 077
if tmp=$(mktemp "$dir/.report-offer.notified.XXXXXX"); then
  if ! printf '%s\t%s\n' "$now" "$id" > "$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$stamp"; then
    rm -f -- "$tmp"
  fi
fi
printf 'daily-upstream-report %s\n' "$id"
SH
  } > "$tmp"
  chmod 700 "$tmp"
  atomic_publish "$tmp" "$CHECK_FILE" 700 || return 1
  env FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$FM_HOME/state" "$SCRIPT_DIR/fm-check-register.sh" daily-upstream-report >/dev/null 2>&1
}

notify_report() {
  local summary='Firstmate morning upstream report is ready.'
  if [ -n "${FM_DAILY_NOTIFICATION_EXEC:-}" ] && [ "${FM_DAILY_TEST_MODE:-0}" = 1 ]; then
    bounded_capture "$RUN_TMP/notification" 10 "$FM_DAILY_NOTIFICATION_EXEC" "$summary" || return 1
  elif command -v osascript >/dev/null 2>&1; then
    bounded_capture "$RUN_TMP/notification" 10 osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "Firstmate"' -e 'end run' "$summary" || return 1
  else
    return 1
  fi
}

run_report() {
  local today receipt='' report_tmp receipt_hash report_name report_dest report_hash report_id relative wait=0 collection_wait=0 elapsed=0
  local grace max_wait lock_rc=0 receipt_date='' receipt_mode=''
  require_timezone
  init_private
  today=$(local_date)
  if [ "${FM_DAILY_SCHEDULED:-0}" = 1 ]; then
    grace=${FM_DAILY_REPORT_GRACE_SECS:-5}
    safe_number "$grace" || grace=5
    sleep "$grace"
    wait=${FM_DAILY_LOCK_WAIT_SECS:-900}
    safe_number "$wait" || wait=900
    max_wait=${FM_DAILY_REPORT_MAX_LOCK_WAIT_SECS:-3600}
    safe_number "$max_wait" || max_wait=3600
    collection_wait=${FM_DAILY_REPORT_COLLECTION_WAIT_SECS:-120}
    safe_number "$collection_wait" || collection_wait=120
    while [ "$elapsed" -lt "$collection_wait" ] && [ ! -e "$RECEIPTS/$today.receipt" ] && [ ! -L "$RECEIPTS/$today.receipt" ]; do
      sleep 1
      elapsed=$((elapsed + 1))
    done
    if collection_lock_live && [ "$max_wait" -gt "$wait" ]; then
      wait=$max_wait
    fi
  fi
  set +e
  acquire_lock report "$wait"
  lock_rc=$?
  set -e
  if [ "$lock_rc" -eq 75 ]; then
    echo "report=deferred; reason=run-lock-busy; retry=next-scheduled-report"
    return 75
  fi
  [ "$lock_rc" -eq 0 ] || return "$lock_rc"
  if [ -e "$RECEIPTS/$today.receipt" ] || [ -L "$RECEIPTS/$today.receipt" ]; then
    receipt_valid "$RECEIPTS/$today.receipt" || { echo "refused: receipt path is unsafe" >&2; return 1; }
    receipt="$RECEIPTS/$today.receipt"
  elif [ -e "$DATA_ROOT/latest.receipt" ] || [ -L "$DATA_ROOT/latest.receipt" ]; then
    receipt_valid "$DATA_ROOT/latest.receipt" || { echo "refused: latest receipt path is unsafe" >&2; return 1; }
    receipt="$DATA_ROOT/latest.receipt"
  fi
  if [ -n "$receipt" ]; then
    receipt_hash=$(shasum -a 256 "$receipt" | awk '{print substr($1,1,12)}')
    receipt_date=$(receipt_field "$receipt" local-date)
    receipt_mode=$(receipt_field "$receipt" mode)
  else
    receipt_hash=none
  fi
  report_name="$today-$receipt_hash.md"
  report_tmp="$RUN_TMP/$report_name"
  report_from_receipt "$receipt" "$report_tmp" "$today" "$receipt_date" "$receipt_mode"
  report_hash=$(shasum -a 256 "$report_tmp" | awk '{print substr($1,1,16)}')
  report_id="${today//-/}-$report_hash"
  relative="reports/$report_name"
  report_dest="$REPORTS/$report_name"
  atomic_publish "$report_tmp" "$report_dest" 600 || { echo "refused: report publication failed safely" >&2; return 1; }
  atomic_publish "$report_tmp" "$DATA_ROOT/latest-report.md" 600 || { echo "refused: latest report publication failed safely" >&2; return 1; }
  retention_add "$relative" || { echo "refused: retention index publication failed safely" >&2; return 1; }
  queue_report_offer "$report_id" "$relative" || { echo "refused: report offer publication failed safely" >&2; return 1; }
  if ! write_report_check; then
    echo "report=preserved; firstmate-check=unavailable"
  else
    echo "report=preserved; firstmate-check=armed"
  fi
  if notify_report; then
    echo "local-notification=posted"
  else
    echo "local-notification=unavailable; report-preserved=yes"
  fi
}

show_report() {
  local id=$1 line relative path expected_hash actual_hash
  report_id_valid "$id" || { echo "refused: invalid report id" >&2; return 2; }
  validate_home_roots || return 1
  private_file_valid "$OFFERS" 600 || { echo "refused: report offer is unavailable" >&2; return 1; }
  line=$(awk -F '\t' -v id="$id" '$1==id { print; exit }' "$OFFERS")
  [ -n "$line" ] || { echo "refused: report id is not pending" >&2; return 1; }
  relative=${line#*	}
  case "$relative" in reports/*.md) ;; *) echo "refused: report reference is unsafe" >&2; return 1 ;; esac
  path="$DATA_ROOT/$relative"
  private_file_valid "$path" 600 || { echo "refused: report file is unsafe" >&2; return 1; }
  expected_hash=${id#*-}
  actual_hash=$(shasum -a 256 "$path" | awk '{print substr($1,1,16)}')
  [ "$actual_hash" = "$expected_hash" ] || { echo "refused: report bytes no longer match the offered id" >&2; return 1; }
  cat "$path"
}

acknowledge_report() {
  local id=$1 old new remaining
  report_id_valid "$id" || { echo "refused: invalid report id" >&2; return 2; }
  init_private
  acquire_lock acknowledge 0
  private_file_valid "$OFFERS" 600 || { echo "refused: report offer is unavailable" >&2; return 1; }
  old="$RUN_TMP/offers-old"
  new="$RUN_TMP/offers-new"
  cp "$OFFERS" "$old"
  awk -F '\t' -v id="$id" '$1 != id' "$old" > "$new"
  remaining=$(awk 'NF { n++ } END { print n+0 }' "$new")
  [ "$remaining" -lt "$(awk 'NF { n++ } END { print n+0 }' "$old")" ] || { echo "refused: report id is not pending" >&2; return 1; }
  if [ "$remaining" -eq 0 ]; then
    rm -f -- "$OFFERS"
    if safe_existing_destination "$OFFER_STAMP" 600; then
      rm -f -- "$OFFER_STAMP"
    fi
    if safe_existing_destination "$CHECK_FILE" 700 && safe_existing_destination "$CHECK_TRUST" 600; then
      rm -f -- "$CHECK_FILE" "$CHECK_TRUST"
    fi
  else
    atomic_publish "$new" "$OFFERS" 600 || return 1
  fi
  echo "acknowledged=$id"
}

xml_escape() {
  printf '%s' "$1" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g;s/"/\&quot;/g;s/'"'"'/\&apos;/g'
}

launchagents_dir() {
  if [ "${FM_DAILY_TEST_MODE:-0}" = 1 ] && [ -n "${FM_DAILY_LAUNCHAGENTS_OVERRIDE:-}" ]; then
    printf '%s\n' "$FM_DAILY_LAUNCHAGENTS_OVERRIDE"
  else
    printf '%s\n' "$HOME/Library/LaunchAgents"
  fi
}

render_plist() {
  local phase=$1 hour=$2 output=$3 label command home script stdout stderr
  label="com.kunchenguid.firstmate.daily-upstream.$phase"
  command=$phase
  [ "$phase" != collection ] || command=collect
  home=$(xml_escape "$FM_HOME")
  script=$(xml_escape "$FM_ROOT/bin/fm-daily-upstream.sh")
  stdout=$(xml_escape "$STATE_ROOT/$phase.launchd.log")
  stderr=$(xml_escape "$STATE_ROOT/$phase.launchd.err.log")
  cat > "$output" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$script</string>
    <string>$command</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>FM_HOME</key>
    <string>$home</string>
    <key>FM_DAILY_SCHEDULED</key>
    <string>1</string>
    <key>FM_DAILY_SCHEDULED_PHASE</key>
    <string>$phase</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>$hour</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>ProcessType</key>
  <string>Background</string>
  <key>LowPriorityIO</key>
  <true/>
  <key>Nice</key>
  <integer>10</integer>
  <key>Umask</key>
  <integer>63</integer>
  <key>StandardOutPath</key>
  <string>$stdout</string>
  <key>StandardErrorPath</key>
  <string>$stderr</string>
</dict>
</plist>
EOF
  chmod 600 "$output"
}

plist_lint() {
  local file=$1
  if [ -x /usr/bin/plutil ]; then
    /usr/bin/plutil -lint "$file" >/dev/null 2>&1
  elif [ "${FM_DAILY_TEST_MODE:-0}" = 1 ] && command -v plutil >/dev/null 2>&1; then
    plutil -lint "$file" >/dev/null 2>&1
  else
    return 1
  fi
}

prepare_plists() {
  PLIST_COLLECTION="$RUN_TMP/collection.plist"
  PLIST_REPORT="$RUN_TMP/report.plist"
  render_plist collection 4 "$PLIST_COLLECTION"
  render_plist report 8 "$PLIST_REPORT"
  plist_lint "$PLIST_COLLECTION" && plist_lint "$PLIST_REPORT"
}

plist_paths() {
  local dir
  dir=$(launchagents_dir)
  LAUNCH_DIR=$dir
  COLLECTION_PLIST="$dir/com.kunchenguid.firstmate.daily-upstream.collection.plist"
  REPORT_PLIST="$dir/com.kunchenguid.firstmate.daily-upstream.report.plist"
}

install_preflight_file() {
  local expected=$1 target=$2
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then return 0; fi
  private_file_valid "$target" 600 && cmp -s "$expected" "$target"
}

install_one() {
  local expected=$1 target=$2
  if [ -e "$target" ] || [ -L "$target" ]; then
    private_file_valid "$target" 600 && cmp -s "$expected" "$target"
    return
  fi
  ln "$expected" "$target" || return 1
  rm -f -- "$expected"
  private_file_valid "$target" 600
}

install_launchagents() {
  local created_collection=0
  require_timezone
  init_private
  acquire_lock install 0
  plist_paths
  [ ! -L "$LAUNCH_DIR" ] || { echo "refused: LaunchAgents directory is unsafe" >&2; return 1; }
  if [ ! -e "$LAUNCH_DIR" ]; then
    mkdir -p "$LAUNCH_DIR" || return 1
  fi
  [ -d "$LAUNCH_DIR" ] && [ ! -L "$LAUNCH_DIR" ] || { echo "refused: LaunchAgents directory is unsafe" >&2; return 1; }
  prepare_plists || { echo "refused: generated LaunchAgent definitions are invalid" >&2; return 1; }
  if ! install_preflight_file "$PLIST_COLLECTION" "$COLLECTION_PLIST" || ! install_preflight_file "$PLIST_REPORT" "$REPORT_PLIST"; then
    echo "refused: an existing LaunchAgent definition is not byte-exact and safe" >&2
    return 1
  fi
  [ -e "$COLLECTION_PLIST" ] || created_collection=1
  if ! install_one "$PLIST_COLLECTION" "$COLLECTION_PLIST"; then
    echo "refused: collection LaunchAgent definition was not installed safely" >&2
    return 1
  fi
  if ! install_one "$PLIST_REPORT" "$REPORT_PLIST"; then
    if [ "$created_collection" -eq 1 ] && private_file_valid "$COLLECTION_PLIST" 600; then rm -f -- "$COLLECTION_PLIST"; fi
    echo "refused: report LaunchAgent definition was not installed safely" >&2
    return 1
  fi
  echo "install=definitions-ready; launchctl=not-invoked"
}

verify_launchagents() {
  init_private
  acquire_lock verify-install 0
  plist_paths
  prepare_plists || { echo "verification=failed: generated definitions invalid"; return 1; }
  if ! private_file_valid "$COLLECTION_PLIST" 600 || ! cmp -s "$PLIST_COLLECTION" "$COLLECTION_PLIST" || ! plist_lint "$COLLECTION_PLIST"; then
    echo "verification=failed: collection definition mismatch"
    return 1
  fi
  if ! private_file_valid "$REPORT_PLIST" 600 || ! cmp -s "$PLIST_REPORT" "$REPORT_PLIST" || ! plist_lint "$REPORT_PLIST"; then
    echo "verification=failed: report definition mismatch"
    return 1
  fi
  echo "verification=exact; launchctl=not-invoked"
}

uninstall_launchagents() {
  init_private
  acquire_lock uninstall 0
  plist_paths
  prepare_plists || { echo "refused: expected definitions could not be rendered" >&2; return 1; }
  for pair in "$PLIST_COLLECTION|$COLLECTION_PLIST" "$PLIST_REPORT|$REPORT_PLIST"; do
    expected=${pair%%|*}
    target=${pair#*|}
    if [ -e "$target" ] || [ -L "$target" ]; then
      if ! private_file_valid "$target" 600 || ! cmp -s "$expected" "$target"; then
        echo "refused: installed definitions are not both byte-exact; nothing removed" >&2
        return 1
      fi
    fi
  done
  rm -f -- "$COLLECTION_PLIST" "$REPORT_PLIST"
  echo "uninstall=definitions-removed; launchctl=not-invoked"
}

recover_run_lock() {
  local seconds=$1 pid mtime age preserved entries
  safe_number "$seconds" && [ "$seconds" -ge 3600 ] || { echo "refused: stale-lock threshold must be at least 3600 seconds" >&2; return 2; }
  init_private
  [ -d "$RUN_LOCK" ] && [ ! -L "$RUN_LOCK" ] || { echo "recover-lock=none"; return 0; }
  if ! private_file_valid "$RUN_LOCK/pid" 600 || ! private_file_valid "$RUN_LOCK/action" 600; then
    echo "refused: run lock evidence is unsafe and was preserved" >&2
    return 1
  fi
  entries=$(find "$RUN_LOCK" -mindepth 1 -maxdepth 1 -print 2>/dev/null | wc -l | tr -d ' ')
  [ "$entries" -eq 2 ] || { echo "refused: run lock has uncertain evidence and was preserved" >&2; return 1; }
  pid=$(sed -n '1p' "$RUN_LOCK/pid")
  case "$pid" in ''|*[!0-9]*) echo "refused: run lock owner is ambiguous and was preserved" >&2; return 1 ;; esac
  if kill -0 "$pid" 2>/dev/null; then
    echo "refused: run lock owner is still alive" >&2
    return 1
  fi
  mtime=$(path_mtime "$RUN_LOCK") || return 1
  age=$(( $(local_epoch) - mtime ))
  [ "$age" -ge "$seconds" ] || { echo "refused: run lock is not old enough" >&2; return 1; }
  preserved="$STATE_ROOT/preserved-run-lock-$mtime"
  [ ! -e "$preserved" ] && [ ! -L "$preserved" ] || { echo "refused: preserved lock destination exists" >&2; return 1; }
  mv -- "$RUN_LOCK" "$preserved"
  echo "recover-lock=preserved-and-cleared"
}

cleanup_retention() {
  local days=$1 now threshold old new epoch relative path pending removed=0 retained=0
  safe_number "$days" || { echo "refused: keep-days must be a non-negative integer" >&2; return 2; }
  init_private
  acquire_lock cleanup 0
  [ -e "$RETENTION_INDEX" ] || { echo "cleanup=none"; return 0; }
  private_file_valid "$RETENTION_INDEX" 600 || { echo "refused: retention index is unsafe" >&2; return 1; }
  now=$(local_epoch)
  threshold=$((now - days * 86400))
  old="$RUN_TMP/retention-old"
  new="$RUN_TMP/retention-new"
  cp "$RETENTION_INDEX" "$old"
  : > "$new"
  while IFS=$(printf '\t') read -r epoch relative; do
    safe_number "$epoch" || { printf '%s\t%s\n' "$epoch" "$relative" >> "$new"; retained=$((retained + 1)); continue; }
    case "$relative" in receipts/*.receipt|reports/*.md) ;; *) printf '%s\t%s\n' "$epoch" "$relative" >> "$new"; retained=$((retained + 1)); continue ;; esac
    pending=0
    if [ -e "$OFFERS" ] && private_file_valid "$OFFERS" 600 && awk -F '\t' -v p="$relative" '$2==p { found=1 } END { exit !found }' "$OFFERS"; then pending=1; fi
    path="$DATA_ROOT/$relative"
    if [ "$epoch" -lt "$threshold" ] && [ "$pending" -eq 0 ] && private_file_valid "$path" 600; then
      rm -f -- "$path"
      removed=$((removed + 1))
    else
      printf '%s\t%s\n' "$epoch" "$relative" >> "$new"
      retained=$((retained + 1))
    fi
  done < "$old"
  atomic_publish "$new" "$RETENTION_INDEX" 600 || return 1
  echo "cleanup=complete; removed=$removed; retained=$retained"
}

detect() {
  local tz home=unsafe root=unavailable install=absent dir collection report
  tz=$(local_timezone)
  validate_home_roots && home=safe
  git -C "$FM_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 && root=repository
  plist_paths
  collection=$COLLECTION_PLIST
  report=$REPORT_PLIST
  if [ -e "$collection" ] || [ -e "$report" ] || [ -L "$collection" ] || [ -L "$report" ]; then
    install=present-or-unsafe
  fi
  printf '%s\n' 'FIRSTMATE_DAILY_UPSTREAM_DETECT_V1'
  printf 'timezone=%s\n' "$tz"
  printf 'private-home=%s\n' "$home"
  printf 'firstmate-root=%s\n' "$root"
  printf 'launchagent-definitions=%s\n' "$install"
  printf '%s\n' 'launchctl-invoked=no'
}

main() {
  local command=${1:-}
  case "$command" in
    -h|--help|help) usage ;;
    detect) [ $# -eq 1 ] || { usage >&2; return 2; }; detect ;;
    assess) [ $# -eq 1 ] || { usage >&2; return 2; }; run_collection assess ;;
    collect) [ $# -eq 1 ] || { usage >&2; return 2; }; run_collection collect ;;
    report) [ $# -eq 1 ] || { usage >&2; return 2; }; run_report ;;
    show-report) [ $# -eq 2 ] || { usage >&2; return 2; }; show_report "$2" ;;
    acknowledge) [ $# -eq 2 ] || { usage >&2; return 2; }; acknowledge_report "$2" ;;
    install) [ $# -eq 1 ] || { usage >&2; return 2; }; install_launchagents ;;
    verify-install) [ $# -eq 1 ] || { usage >&2; return 2; }; verify_launchagents ;;
    uninstall) [ $# -eq 1 ] || { usage >&2; return 2; }; uninstall_launchagents ;;
    cleanup)
      [ $# -eq 3 ] && [ "$2" = --keep-days ] || { usage >&2; return 2; }
      cleanup_retention "$3"
      ;;
    recover-lock)
      [ $# -eq 3 ] && [ "$2" = --older-than-seconds ] || { usage >&2; return 2; }
      recover_run_lock "$3"
      ;;
    *) usage >&2; return 2 ;;
  esac
}

main "$@"
