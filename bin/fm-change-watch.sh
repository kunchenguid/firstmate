#!/usr/bin/env bash
# Post-merge change watch: watch a merged change BY EFFECT, not by content.
#
# A merge that touches a deployable service is normally verified at merge time
# by reading the new content on the live pods. That proves the change ARRIVED; it
# does not prove the service is healthy afterwards. This script registers one
# bounded watch per merged change, samples the affected Deployment's own signals
# against a pre-deploy baseline, and reports the FIRST regression as a wake and a
# steer so a bad change is caught minutes after the rollout, not hours later.
#
# Usage:
#   fm-change-watch.sh register <task-id> <pr-url>
#   fm-change-watch.sh due <watch-id>
#   fm-change-watch.sh drive <watch-id>
#   fm-change-watch.sh sample <watch-id> [<offset-seconds>]
#   fm-change-watch.sh verdict <watch-id>
#   fm-change-watch.sh status [<watch-id>]
#   fm-change-watch.sh doctor [<watch-id>]
#
# register  Derive the affected Kubernetes Deployment(s) from the merged PR,
#           record the pre-deploy baseline, and arm one bounded schedule of
#           samples. For an H-DevOps pull request the targets are the
#           Deployment documents that the PR's diff hunks land in, across the
#           changed manifests under k8s/prod/, read at the PR's head commit so
#           the diff's line numbers apply; a target's namespace is the
#           document's own metadata.namespace, and a Deployment that declares
#           none is skipped with a stated reason, never guessed. When a hunk
#           cannot be placed in its manifest (no diff, or content that does not
#           match it) every Deployment in that manifest is watched and the
#           registration line says so. For an application repository the
#           targets are the Deployments that RUN this repository's image in a
#           production namespace, found by matching a container image's
#           repository name against the repository's own name and the aliases
#           in config/change-watch-repos (local, gitignored); a repository
#           whose Deployment names differ from its image name is mapped there,
#           and one that deploys to a host rather than the cluster is watched
#           through its own deploy workflow instead. A large family is capped
#           at MAX_TARGETS busiest Deployments and the registration line states
#           the cap. A repository that also has a Sentry project, and any
#           workflow the map names, become additional targets of their own; a
#           Sentry project this home has no token for is not a target. A
#           PR that touches no deployable service registers nothing and says
#           so, as does one that only deletes a manifest, one whose only target
#           could not be read, one whose manifests could not be read, and one
#           whose cluster image inventory could not be read; each says which of
#           those it was.
#           Every Kubernetes target records a rollout FINGERPRINT at
#           registration - its pod images plus its pods' pod-template-hash
#           labels - and the watch refuses to score it until that fingerprint
#           CHANGES, so a sample taken before the rollout lands measures the
#           release rather than the code it replaced. The template hash is why a
#           manifest change that rolls pods without touching an image (an env
#           value, a routing table) still opens the gate, and why a mutable tag or
#           a digest-pinned image still proves its own rollout. A target whose
#           fingerprint has not changed is recorded as awaiting the deploy, never
#           as health. When the fingerprint cannot be read at registration the
#           target is still measured, and the clean completion, the completed-
#           unmeasured note, and the status line each say the rollout was never
#           proven for it.
#           Registering an existing watch whose drive stopped before the end of
#           its schedule re-arms the remaining samples; any other existing watch
#           is left alone. Registration is read-only against the cluster; it
#           writes only under this home's state/ directory. Its forge reads
#           share one budget (default 60s) and its baseline capture the sample
#           budget below, so a merge or watcher cycle is never stalled by it.
# due       Condition hook for the armed watch: exit 0 when a scheduled sample
#           is due now, exit 1 otherwise. Pure and cheap; never runs a sample.
# drive     Action hook for the armed watch: take every remaining scheduled
#           sample in order, stopping at the first regression. This is the one
#           long-running child; it is armed through bin/fm-procevent-when.sh and
#           is never run in a conversational turn. A drive stopped before the
#           end of its schedule records "interrupted at +Nm" and queues one
#           check wake; it never reads as clean.
# sample    Read every metric for every target, compare each to its baseline
#           with a stated bar, and append one sample record. Degrades to
#           "unmeasured" per metric rather than failing the whole watch.
# verdict   Print "change-watch clean", "change-watch completed unmeasured",
#           "change-watch interrupted at +Nm", or
#           "change-watch regressed at +Nm on <metric> (<value> vs baseline <value>)".
#           Clean means every target had at least one scored reading across the
#           schedule. Completed unmeasured means the schedule ended with some
#           target never read: a measurement gap, recorded as such, never as
#           health.
# status    Print one line per registered watch (all of them, or one).
# doctor    Live self-test of the read path. It prints the kubeconfig in use,
#           proves the cluster answers, and with a watch id reads every target
#           live: a Deployment target must return its pods and its pod images, a
#           pool-backed target its own resolved pool, a Sentry target its
#           project, and a workflow target its run list. It also replays the
#           reasons the last sample recorded for each unmeasured metric, so the
#           question "why was nothing measured" is answered with evidence
#           instead of silence. A read that fails, times out, or returns no data
#           is a stated "doctor: FAIL" line and a non-zero exit.
#
# Kubeconfig: the cluster is read with the first of FM_CW_KUBECONFIG, the path
# on the first non-comment line of config/change-watch-kubeconfig (local,
# gitignored), an operator's own KUBECONFIG, and ~/.kube/mcp-viewer.kubeconfig
# (the read-only production reader this home uses) that is set and readable.
# The ambient ~/.kube/config default is used only when none of those exist,
# because that default can point at a cluster this home cannot reach - which is
# exactly how every watch once completed unmeasured while looking healthy. A
# sample proves the cluster answers once before reading any metric and records
# the reason for every metric it could not read.
#
# Metrics, bars, and windows:
#   http_5xx_per_min     5xx responses per minute from the pods' own access
#                        logs. When the per-container line cap is hit the rate
#                        is taken over the span the read lines actually cover,
#                        so a busy service is never divided by a window it did
#                        not fill. Regressed when value > 3x baseline AND
#                        value > 1/min.
#   restarts             total container restartCount across the Deployment's
#                        pods; regressed when value > baseline + 1.
#   oomkilled            OOMKilled container terminations at or after the
#                        baseline epoch; regressed when value > 0.
#   p95_ms               request p95 latency where the service exposes it;
#                        regressed when value > 3x baseline AND > baseline+100ms.
#   pgbouncer_cl_waiting clients waiting on the Deployment's own pgbouncer pool:
#                        the pod spec's DB_HOST/DB_PORT/DB_NAME (secret refs
#                        resolved), the pooler endpoint behind that Service, then
#                        SHOW POOLS filtered to that database. The console is
#                        read on the pooler host as `ssh -n ubuntu@<host>`
#                        running `sudo -u postgres psql -h /var/run/postgresql
#                        -p <port> -U pgbouncer pgbouncer -Ac 'SHOW POOLS'`, the
#                        admin unix socket the house wiki records as the form
#                        that answers without a password; the read is bounded
#                        by the remaining sample budget. A pool that cannot be
#                        resolved at registration is unmeasured for the whole
#                        watch. Regressed when value > 0 on two consecutive
#                        samples.
#   rss_ratio            highest container working set as a fraction of its
#                        memory limit; regressed when value > 0.85.
#   sentry_new_issues    issues first seen at or after the baseline epoch at
#                        level error or fatal; regressed when value > baseline
#                        AND value >= 3. Its target is sentry/<project>. It is
#                        not read until the watch's own landing is proven: the
#                        watched Deployments' rollout when the watch has any,
#                        otherwise its deploy workflow's run for this merge.
#                        Without a Sentry token or a mapped project it is
#                        unmeasured for the whole watch, with the reason
#                        recorded.
#   deploy_run           the repository's own deploy workflow as 1 when a run
#                        created at or after the merge completed successfully
#                        and 0 when it failed, was cancelled, or timed out;
#                        regressed when value is 0, because a failed deploy is
#                        definite whether or not any run existed at registration
#                        (so its baseline reads "unmeasured"). Its target is
#                        run/<owner>/<repo>#<workflow-path>. No run yet, or one
#                        still in flight, is awaiting the deploy and unmeasured.
# The baseline window is the 60 minutes before the change's rollout start, read
# as a level for counters (restarts, oomkilled, rss_ratio) and as a rate for the
# others. An unmeasured metric is skipped, never scored as a pass, and a metric
# with a relative bar (http_5xx_per_min, restarts, p95_ms, sentry_new_issues)
# whose baseline could not be read is recorded but never scored. Every metric a
# sample could not read leaves its reason in the watch's read-failures record,
# and both status and doctor replay them.
#
# An absent metric is never implied to be healthy: a clean verdict counts only
# the metrics that were actually read, and the completion note and status line
# name every metric key no sample ever scored, target included, so a release
# watched only for restarts and memory says exactly that and a target whose own
# pool or pods were never read is named as the gap it is.
#
# Schedule: +5m, +15m, +30m, then hourly to +12h. Samples stop at the first
# regression. On a clean +12h the watch appends one note to the task's status
# log and, when that note has no gap to report, records one wiki observation; a
# clean ending that did leave a metric unmeasured or a rollout unproven says so
# in the note instead, and on a completed-unmeasured +12h it appends one note
# naming the targets it never read and records nothing else.
#
# Reporting: the first regression appends one
#   check: change-watch <task-id> <pr-url> <metric> regressed
# wake to the durable wake queue and steers the owning task through
# bin/fm-send.sh with the numbers; an interrupted drive appends one
#   check: change-watch <task-id> <pr-url> interrupted at +Nm
# wake. All are best-effort and never fail a merge.
#
# Read-only against the cluster. No model calls. No new fleet workers: the
# watcher's existing process-event runner drives the registered watch. One
# sample, and the baseline capture at registration, are each bounded by a hard
# budget (default 25s). That budget bounds the cluster reads only: every metric
# they cannot reach inside it is recorded unmeasured, while the Sentry and
# deploy-workflow reads go over the network under their own bounds and are never
# costed against a budget the pod reads spent.
#
# Test seams (all optional, all inert in production):
#   FM_CW_NOW              fixed current epoch (integer) instead of `date +%s`
#   FM_CW_FORGE_DIR        directory replacing every forge read (files.txt,
#                          merge-epoch, head-ref, diff.txt, content/<path>)
#   FM_CW_HDEVOPS_K8S_DIR  k8s/prod tree of an H-DevOps checkout, the last-resort
#                          way to resolve an application repository to a Deployment
#   FM_CW_KUBECONFIG       kubeconfig file used for every cluster read
#   FM_CW_CONFIG_DIR       directory replacing the home's config/ directory,
#                          where change-watch-kubeconfig and change-watch-repos live
#   FM_CW_MAX_TARGETS      cap on Deployments watched for one repository (default 8)
#   FM_CW_WORKLOADS_DIR    directory replacing the live image inventory: a file
#                          workloads holds "ns<TAB>name<TAB>replicas<TAB>images",
#                          images comma- or space-separated
#   FM_CW_SENTRY_VAULT     Sentry credential file (default ~/.config/muso/sentry-vault.json)
#   FM_CW_SENTRY_DIR       directory of stubbed Sentry responses: issues-<project>.json
#   FM_CW_GH               gh command used for the deploy-run target (default gh)
#   FM_CW_GH_DIR           directory of stubbed gh responses:
#                          runs-<owner>-<repo>-<workflow-path with / and space as _>.json
#   FM_CW_FORGE_TIMEOUT    per-call bound on a forge read (default 12s)
#   FM_CW_FORGE_BUDGET     total bound on forge reads in one register (default 60s)
#   FM_CW_SAMPLE_DEADLINE  hard budget for one sample or baseline capture (default 25)
#   FM_CW_CLUSTER_DIR      directory of metric series replacing cluster reads:
#                          <metric>.<target>.<window>, one value per line, empty
#                          line = unmeasured; the target is ns/deploy with "/"
#                          replaced by "_". pool.<target> holds one line
#                          "ip<TAB>port<TAB>database" replacing the pool
#                          resolution (absent = unresolvable).
#   FM_CW_ARM_CMD          command replacing bin/fm-procevent-when.sh for arming
#   FM_CW_SEND_CMD         command replacing bin/fm-send.sh for the lane steer
#   FM_CW_SLEEP_CMD        command replacing `sleep` for the drive loop
#   FM_CW_NO_WIKI          set to 1 to skip the wiki note with a printed notice
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

WATCH_ROOT="$STATE/change-watch"
SCHEDULE_OFFSETS="300 900 1800 3600 7200 10800 14400 18000 21600 25200 28800 32400 36000 39600 43200"
K8S_METRICS="restarts oomkilled rss_ratio http_5xx_per_min p95_ms pgbouncer_cl_waiting"
SENTRY_METRICS="sentry_new_issues"
RUN_METRICS="deploy_run"
BASELINE_WINDOW_SECONDS=3600
SAMPLE_WINDOW_SECONDS=300
LOG_TAIL_LINES=2000
KUBECTL_TIMEOUT=4s
FORGE_TIMEOUT=${FM_CW_FORGE_TIMEOUT:-12}
FORGE_BUDGET_SECONDS=${FM_CW_FORGE_BUDGET:-60}
# Hard budget for one sample or one baseline capture: once it elapses, every
# remaining metric is recorded unmeasured so a slow or unreachable read can
# never run a sample, a merge, or a watcher cycle past its bound.
SAMPLE_DEADLINE_SECONDS=${FM_CW_SAMPLE_DEADLINE:-25}
MAX_MANIFEST_READS=20
# Cap on Deployments watched for one repository: a large image family (the
# industry-data-processing family alone is 21 Deployments in production) cannot
# be sampled inside one sample budget, so the busiest MAX_TARGETS are watched and
# the registration line states the cap instead of silently dropping the rest.
MAX_TARGETS=${FM_CW_MAX_TARGETS:-8}
# A Deployment is a watch target only when it runs in a production namespace:
# a dev, test, drill, or staging copy is not the release.
PROD_NAMESPACE_EXCLUDE='-dev|-test|-tests|-staging|-stage|-drill|-pr-'
TARGET_NAME_EXCLUDE='-test$'
SENTRY_VAULT=${FM_CW_SENTRY_VAULT:-$HOME/.config/muso/sentry-vault.json}
SENTRY_MIN_NEW=3
SENTRY_HTTP_TIMEOUT=6
POOLER_SSH_USER=ubuntu
POOLER_SOCKET_DIR=/var/run/postgresql
POOLER_DEFAULT_HOST=10.0.0.17
POOLER_DEFAULT_PORT=6432

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
notice() { printf 'notice: %s\n' "$1" >&2; }
usage() {
  awk 'NR == 1 { next } /^set -u$/ { exit } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
  exit 2
}

cw_now() {
  if [ -n "${FM_CW_NOW:-}" ]; then
    printf '%s\n' "$FM_CW_NOW"
  else
    date +%s
  fi
}

CW_FORGE_START=$(cw_now)
CW_BUDGET_START=''
CW_CONFIG_DIR=${FM_CW_CONFIG_DIR:-$FM_HOME/config}
CW_KUBECONFIG=''
CW_KUBECONFIG_SOURCE=''

cw_kubectl() { kubectl --request-timeout="$KUBECTL_TIMEOUT" "$@"; }

# Resolve the kubeconfig every cluster read uses, and export it once so a
# subshell, a background reader, and a by-hand reproduction all see the same
# file. Precedence: an explicit FM_CW_KUBECONFIG, the home's own
# config/change-watch-kubeconfig, an operator's KUBECONFIG, then the read-only
# production reader this house ships. The ambient default is last on purpose:
# when it points at a cluster this home cannot reach, every watch completed
# unmeasured while its record still read as a normal watch.
cw_kubeconfig_init() {
  local source configured candidate
  configured=''
  if [ -f "$CW_CONFIG_DIR/change-watch-kubeconfig" ]; then
    configured=$(sed -n 's/^[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d; p; q' \
      "$CW_CONFIG_DIR/change-watch-kubeconfig" 2>/dev/null || true)
  fi
  # Candidates are walked in precedence order and each one is tested for
  # readability as it is offered: an unreadable file is stated and skipped so the
  # next candidate still gets its turn. Ending the walk at the first unreadable
  # file is what silently moved reads onto the ambient default.
  for source in FM_CW_KUBECONFIG config/change-watch-kubeconfig KUBECONFIG mcp-viewer; do
    case "$source" in
      FM_CW_KUBECONFIG) candidate=${FM_CW_KUBECONFIG:-} ;;
      config/change-watch-kubeconfig) candidate=$configured ;;
      KUBECONFIG) candidate=${KUBECONFIG:-}; candidate=${candidate%%:*} ;;
      mcp-viewer) candidate=$HOME/.kube/mcp-viewer.kubeconfig ;;
    esac
    [ -n "$candidate" ] || continue
    if [ ! -r "$candidate" ]; then
      printf 'notice: change-watch: kubeconfig %s (%s) is unreadable; trying the next one\n' \
        "$candidate" "$source" >&2
      continue
    fi
    CW_KUBECONFIG=$candidate
    CW_KUBECONFIG_SOURCE=$source
    export KUBECONFIG="$candidate"
    return 0
  done
  CW_KUBECONFIG=''
  CW_KUBECONFIG_SOURCE='ambient default'
  return 0
}

# One cheap proof that the cluster answers, run before a sample spends its
# budget on metric reads that would each fail the same way.
cw_cluster_probe() {
  local out
  # A stubbed series directory stands in for every cluster read, so the probe
  # has nothing to prove.
  [ -z "${FM_CW_CLUSTER_DIR:-}" ] || return 0
  command -v kubectl >/dev/null 2>&1 || { printf 'kubectl not installed\n'; return 1; }
  if out=$(cw_kubectl get --raw=/version 2>&1 >/dev/null); then
    return 0
  fi
  printf '%s\n' "${out:-unreadable}" | grep -v '^$' | tail -1 | cut -c1-200
  return 1
}

# Bound one forge read per call and all forge reads of this process together, so
# a hung CLI or a wide PR can never stall the merge or watcher path.
cw_forge_run() {
  local left
  left=$(( FORGE_BUDGET_SECONDS - ($(cw_now) - CW_FORGE_START) ))
  [ "$left" -gt 0 ] || return 124
  [ "$left" -lt "$FORGE_TIMEOUT" ] || left=$FORGE_TIMEOUT
  fm_run_timed "$left" "$@" 2>/dev/null
}

# Every read-scoped cache and budget starts with the sample, because the armed
# drive is one long-lived process that takes every sample in-process: a budget
# or a memo spent at +5m must not decide the read at +6h.
cw_budget_start() {
  CW_BUDGET_START=$(cw_now)
  CW_FORGE_START=$(cw_now)
  CW_POD_FACTS_CACHE=''
  CW_WORKLOADS_CACHE=''
  [ -z "$CW_POOL_BAD_HOSTS_FILE" ] || : > "$CW_POOL_BAD_HOSTS_FILE" 2>/dev/null || true
}
cw_within_budget() { [ $(( $(cw_now) - CW_BUDGET_START )) -lt "$SAMPLE_DEADLINE_SECONDS" ]; }
cw_budget_left() {
  local used=0 left
  [ -z "$CW_BUDGET_START" ] || used=$(( $(cw_now) - CW_BUDGET_START ))
  left=$(( SAMPLE_DEADLINE_SECONDS - used ))
  [ "$left" -gt 0 ] || return 1
  printf '%s\n' "$left"
}

# Stable content hash of a string (shasum or sha256sum; empty when neither is
# available, in which case the watch name falls back to a path-safe prefix).
cw_hash() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum 2>/dev/null | awk '{print $1}'
  else
    printf '%s' "$1" | tr -c 'A-Za-z0-9-' '-'
  fi
}

# --- watch records ------------------------------------------------------------

cw_watch_id() { printf '%s-%s\n' "$1" "$2"; }
cw_watch_dir() { printf '%s/%s\n' "$WATCH_ROOT" "$1"; }
cw_meta_path() { printf '%s/watch.meta\n' "$(cw_watch_dir "$1")"; }
cw_targets_path() { printf '%s/targets\n' "$(cw_watch_dir "$1")"; }
cw_pools_path() { printf '%s/pools\n' "$(cw_watch_dir "$1")"; }
# Extra target kinds: a Sentry project and a deploy workflow are watched
# alongside the Deployments, and each is its own line in its own record so a
# watch with no cluster targets still has targets.
cw_sentry_path() { printf '%s/sentry\n' "$(cw_watch_dir "$1")"; }
cw_runs_path() { printf '%s/runs\n' "$(cw_watch_dir "$1")"; }
# The pod images and rollout fingerprint a Kubernetes target had at registration,
# the evidence the
# rollout must replace before the target is scored.
cw_landed_path() { printf '%s/images-at-register\n' "$(cw_watch_dir "$1")"; }
cw_landed_at_path() { printf '%s/landed-at\n' "$(cw_watch_dir "$1")"; }
# Why each metric of the last sample could not be read.
cw_reasons_path() { printf '%s/read-failures\n' "$(cw_watch_dir "$1")"; }
cw_reasons_begin() {
  : > "$(cw_reasons_path "$1")" 2>/dev/null || true
}
cw_record_reason() {  # <watch-id> <key> <reason>
  local id=$1 key=$2 reason=$3
  [ -n "$key" ] || return 0
  { printf '%s\t%s\n' "$key" "$(printf '%s' "${reason:-unmeasured}" | tr '\t\n' '  ' | cut -c1-200)"; } \
    >> "$(cw_reasons_path "$id")" 2>/dev/null || true
}
cw_baseline_path() { printf '%s/baseline\n' "$(cw_watch_dir "$1")"; }
cw_schedule_path() { printf '%s/schedule\n' "$(cw_watch_dir "$1")"; }
cw_samples_path() { printf '%s/samples.log\n' "$(cw_watch_dir "$1")"; }
cw_verdict_path() { printf '%s/verdict\n' "$(cw_watch_dir "$1")"; }
cw_sampled_path() { printf '%s/sampled\n' "$(cw_watch_dir "$1")"; }
cw_drive_pid_path() { printf '%s/drive.pid\n' "$(cw_watch_dir "$1")"; }
cw_drive_alive_path() { printf '%s/drive.alive\n' "$(cw_watch_dir "$1")"; }
cw_drive_identity_path() { printf '%s/drive.identity\n' "$(cw_watch_dir "$1")"; }
cw_last_path() { printf '%s/last.%s\n' "$(cw_watch_dir "$1")" "$2"; }

cw_meta_get() {  # <watch-id> <key>
  local file
  file=$(cw_meta_path "$1")
  [ -f "$file" ] || return 1
  grep "^$2=" "$file" | tail -1 | cut -d= -f2- || true
}

cw_watch_exists() {
  local dir
  dir=$(cw_watch_dir "$1")
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -f "$dir/watch.meta" ]
}

# atomic private write from stdin
cw_write() {  # <path>
  local path=$1 tmp
  tmp=$(umask 077; mktemp "$(dirname "$path")/.cw.XXXXXX") || return 1
  cat > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path"
}

# --- forge seam ---------------------------------------------------------------

# LIVE QUERY (forge) - changed paths of the merged PR, one per line. GitHub is
# read through gh; anything else degrades to no file list, so register reports
# that it cannot derive a target rather than guessing one.
cw_forge_files() {  # <url> <provider> <owner> <repo> <number>
  if [ -n "${FM_CW_FORGE_DIR:-}" ]; then
    [ -f "$FM_CW_FORGE_DIR/files.txt" ] || return 1
    cat "$FM_CW_FORGE_DIR/files.txt"
    return 0
  fi
  case "$2" in
    github)
      command -v gh >/dev/null 2>&1 || return 1
      cw_forge_run gh pr view "$1" --json files -q '.files[].path' || return 1
      ;;
    *) return 1 ;;
  esac
}

# LIVE QUERY (forge) - the merged PR's unified diff.
cw_forge_diff() {  # <url> <provider>
  if [ -n "${FM_CW_FORGE_DIR:-}" ]; then
    [ -f "$FM_CW_FORGE_DIR/diff.txt" ] || return 1
    cat "$FM_CW_FORGE_DIR/diff.txt"
    return 0
  fi
  case "$2" in
    github)
      command -v gh >/dev/null 2>&1 || return 1
      cw_forge_run gh pr diff "$1" || return 1
      ;;
    *) return 1 ;;
  esac
}

# LIVE QUERY (forge) - merge/rollout epoch of the merged change.
cw_forge_merge_epoch() {  # <url> <provider>
  if [ -n "${FM_CW_FORGE_DIR:-}" ]; then
    [ -f "$FM_CW_FORGE_DIR/merge-epoch" ] || return 1
    cat "$FM_CW_FORGE_DIR/merge-epoch"
    return 0
  fi
  local iso
  case "$2" in
    github)
      command -v gh >/dev/null 2>&1 || return 1
      iso=$(cw_forge_run gh pr view "$1" --json mergedAt -q .mergedAt) || return 1
      ;;
    *) return 1 ;;
  esac
  cw_iso_to_epoch "$iso"
}

cw_iso_to_epoch() {  # <iso8601>
  local iso=$1 out
  [ -n "$iso" ] || return 1
  if out=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null); then
    printf '%s\n' "$out"; return 0
  fi
  if out=$(date -u -d "$iso" +%s 2>/dev/null); then
    printf '%s\n' "$out"; return 0
  fi
  return 1
}

# LIVE QUERY (forge) - one file's content at the merged commit.
cw_forge_content() {  # <owner> <repo> <path> <ref>
  if [ -n "${FM_CW_FORGE_DIR:-}" ]; then
    [ -f "$FM_CW_FORGE_DIR/content/$3" ] || return 1
    cat "$FM_CW_FORGE_DIR/content/$3"
    return 0
  fi
  command -v gh >/dev/null 2>&1 || return 1
  cw_forge_run gh api "repos/$1/$2/contents/$3?ref=$4" --jq .content \
    | base64 -d 2>/dev/null || return 1
}

# LIVE QUERY (forge) - head commit sha of the merged pull request, the commit
# the PR diff's new-file line numbers refer to.
cw_forge_head_ref() {  # <url>
  if [ -n "${FM_CW_FORGE_DIR:-}" ]; then
    [ -f "$FM_CW_FORGE_DIR/head-ref" ] || return 1
    cat "$FM_CW_FORGE_DIR/head-ref"
    return 0
  fi
  command -v gh >/dev/null 2>&1 || return 1
  cw_forge_run gh pr view "$1" --json headRefOid -q .headRefOid || return 1
}

# --- deployment derivation ----------------------------------------------------

# Documents of a Kubernetes manifest stream (stdin), one per line as
# "start<TAB>end<TAB>kind<TAB>namespace<TAB>name" with 1-based inclusive line
# ranges. The name and namespace are the top-level metadata's own keys.
cw_manifest_docs() {
  awk '
    function flush(end) {
      if (kind != "" && end >= start) printf "%d\t%d\t%s\t%s\t%s\n", start, end, kind, ns, name
      start = NR + 1; kind = ""; ns = ""; name = ""; meta = 0; cind = 0
    }
    BEGIN { start = 1 }
    /^---[[:space:]]*$/ { flush(NR - 1); next }
    /^kind:[[:space:]]*/ { kind = $2; gsub(/["\047]/, "", kind); next }
    /^[^[:space:]#]/ { meta = ($0 ~ /^metadata:/); cind = 0; next }
    meta && /^[[:space:]]+[^[:space:]]/ {
      match($0, /^[[:space:]]+/)
      if (cind == 0) cind = RLENGTH
      if (RLENGTH != cind) next
      if ($1 == "name:" && name == "") { name = $2; gsub(/["\047]/, "", name) }
      else if ($1 == "namespace:" && ns == "") { ns = $2; gsub(/["\047]/, "", ns) }
    }
    END { flush(NR) }
  '
}

# Deployments declared in a manifest stream (stdin): "namespace<TAB>name", with
# an empty namespace when the document declares none.
cw_manifest_deployments() {
  cw_manifest_docs | awk -F'\t' '$3 == "Deployment" && $5 != "" { print $4 "\t" $5 }'
}

# Changed lines of a unified diff (stdin) as "path<TAB>new-file-line", one per
# added line and one per removed line at the position it was removed from; a
# file the diff deletes is one "path<TAB>removed" line instead.
cw_diff_changed_lines() {
  awk '
    /^diff --git / { path = ""; old = ""; inhunk = 0; next }
    /^--- / && !inhunk { old = $2; sub(/^a\//, "", old); next }
    /^\+\+\+ / {
      path = $2; sub(/^b\//, "", path); inhunk = 0
      if (path == "/dev/null") { path = ""; if (old != "" && old != "/dev/null") print old "\tremoved" }
      next
    }
    /^@@ / {
      match($0, /\+[0-9]+/)
      cur = substr($0, RSTART + 1, RLENGTH - 1) + 0
      if (cur < 1) cur = 1
      inhunk = 1
      next
    }
    !inhunk || path == "" { next }
    /^\\/ { next }
    /^\+/ { print path "\t" cur; cur++; next }
    /^-/ { print path "\t" cur; next }
    { cur++ }
  ' | sort -u
}

# LIVE QUERY (cluster) - every Deployment's namespace, name, replicas, and
# container images, one "ns<TAB>name<TAB>replicas<TAB>images" line each. A
# Deployment with more than one container renders its images space-separated, so
# a reader splits the field on commas and whitespace alike. One call answers the
# whole inventory, which keeps registering an application release cheap enough
# to run inside a merge hook. An unreadable cluster prints nothing and its caller
# records the reason.
cw_live_workloads() {
  if [ -n "${CW_WORKLOADS_CACHE:-}" ]; then
    printf '%s' "$CW_WORKLOADS_CACHE"
    return 0
  fi
  local out
  if [ -n "${FM_CW_WORKLOADS_DIR:-}" ]; then
    [ -f "$FM_CW_WORKLOADS_DIR/workloads" ] || return 1
    out=$(cat "$FM_CW_WORKLOADS_DIR/workloads")
  else
    command -v kubectl >/dev/null 2>&1 || return 1
    out=$(cw_kubectl get deploy -A \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.replicas}{"\t"}{.spec.template.spec.containers[*].image}{"\n"}{end}' \
      2>/dev/null) || return 1
  fi
  [ -n "$out" ] || return 1
  CW_WORKLOADS_CACHE=$out
  printf '%s' "$out"
}

# The built-in repository map: the aliases an image name does not carry itself,
# the Sentry project a repository reports into, and the deploy workflow of a
# repository that reaches a host rather than the cluster. A home extends or
# overrides it in config/change-watch-repos (never sourced), whose lines are
# "<repo> <spec>..." with each spec one of
#   <namespace>/<deployment>   an explicit Deployment target
#   <deployment>               a Deployment in muso-prod
#   image:<name>               match Deployments running an image named <name>
#   sentry:<project-slug>      the repository's Sentry project
#   run:<owner>/<repo>#<workflow-path>   the repository's deploy workflow
#                                  (a path such as .github/workflows/deploy.yml,
#                                  so the spec stays one whitespace-free token)

# The home's repository map with comments removed. A `#` starts a comment only at
# the start of a line or after whitespace, because a `run:` spec carries one
# inside `<owner>/<repo>#<workflow-path>`.
cw_repo_map_clean() {
  sed -e 's/^#.*$//' -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    "$CW_CONFIG_DIR/change-watch-repos" 2>/dev/null | grep -v '^$' || true
}

cw_repo_map_lines() {
  cat <<'BUILTIN'
core-backend image:core-backend sentry:core-backend
industry-data-processing image:industry-data-processing
web-credits-next image:web-credits-next sentry:credits-web-next
muso-messaging messaging/notify-gateway messaging/send-gateway messaging/preferences
hydra run:Muso-AI/hydra#.github/workflows/deploy.yml
BUILTIN
  if [ -f "$CW_CONFIG_DIR/change-watch-repos" ]; then
    cw_repo_map_clean
  fi
}

# Specs mapped to one repository, in order: the home's own line when it names
# the repository (so a local map replaces the built-in one), else the built-in
# line.
cw_repo_specs() {  # <repo>
  local repo=$1 line specs=''
  if [ -f "$CW_CONFIG_DIR/change-watch-repos" ]; then
    specs=$(cw_repo_map_clean \
      | awk -v r="$repo" '$1 == r { $1 = ""; sub(/^ /, ""); print }' | paste -sd ' ' -)
  fi
  [ -z "$specs" ] || { printf '%s\n' "$specs"; return 0; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(printf '%s' "$line" | awk '{print $1}')" = "$repo" ] || continue
    specs="$specs $(printf '%s' "$line" | cut -d' ' -f2-)"
  done <<MAP
$(cw_repo_map_lines)
MAP
  printf '%s\n' "$(printf '%s' "$specs" | sed -e 's/^ *//' -e 's/ *$//')"
}

# Production-only filter for a Deployment: a dev, test, drill, or staging copy is
# not the release, and a test copy of a production Deployment is not a target.
cw_target_eligible() {  # <ns> <name>
  local ns=$1 name=$2
  case "$ns" in '') return 1 ;; esac
  if printf '%s' "$ns" | grep -Eq "($PROD_NAMESPACE_EXCLUDE)"; then return 1; fi
  if printf '%s' "$name" | grep -Eq "($TARGET_NAME_EXCLUDE)"; then return 1; fi
  return 0
}

# Resolve one spec to "target<TAB>ns<TAB>name" or "sentry<TAB>slug" or
# "run<TAB>owner/repo<TAB>workflow" lines, ranked by replica count and capped at
# MAX_TARGETS so a large image family is watched by its busiest members.
cw_spec_targets() {  # <spec>
  local spec=$1 arg='' ns name matched='' total inventory
  case "$spec" in
    sentry:*) printf 'sentry\t%s\n' "${spec#sentry:}"; return 0 ;;
    run:*)
      arg=${spec#run:}
      printf 'run\t%s\t%s\n' "${arg%%#*}" "${arg#*#}"
      return 0
      ;;
    image:*) arg=${spec#image:} ;;
    '') return 0 ;;
    */*) ns=${spec%%/*}; name=${spec#*/}
      cw_target_eligible "$ns" "$name" || return 0
      printf 'target\t%s\t%s\n' "$ns" "$name"
      return 0
      ;;
    *) ns=muso-prod; name=$spec
      cw_target_eligible "$ns" "$name" || return 0
      printf 'target\t%s\t%s\n' "$ns" "$name"
      return 0
      ;;
  esac
  [ -n "$arg" ] || return 0
  # Match every production Deployment running an image whose repository name is
  # <arg>, then keep the busiest MAX_TARGETS. An inventory that cannot be read is
  # stated, so it is distinguishable from a repository that deploys nothing.
  if ! inventory=$(cw_live_workloads 2>/dev/null); then
    printf 'note\timage inventory unread: no Deployment of image:%s could be resolved\t\n' "$arg"
    return 0
  fi
  matched=$(printf '%s\n' "$inventory" | awk -F'\t' -v want="$arg" '
    {
      ns = $1; name = $2; replicas = $3 + 0; images = $4
      n = split(images, list, /[,[:space:]]+/)
      for (i = 1; i <= n; i++) {
        repo = list[i]
        sub(/^.*\//, "", repo)
        sub(/@.*$/, "", repo)
        sub(/:.*$/, "", repo)
        if (repo == want) { printf "%s\t%s\t%d\n", ns, name, replicas; break }
      }
    }' | while IFS=$'\t' read -r ns name replicas; do
      cw_target_eligible "$ns" "$name" || continue
      printf '%s\t%s\t%s\n' "$replicas" "$ns" "$name"
    done | sort -t$'\t' -k1,1nr -k2,2 -k3,3)
  [ -n "$matched" ] || return 0
  total=$(printf '%s\n' "$matched" | grep -c '' || true)
  if [ "$total" -gt "$MAX_TARGETS" ]; then
    printf 'note\tcapped: watching the %s busiest of %s image:%s Deployments\t\n' \
      "$MAX_TARGETS" "$total" "$arg"
  fi
  printf '%s\n' "$matched" | head -n "$MAX_TARGETS" \
    | while IFS=$'\t' read -r replicas ns name; do
        [ -n "$ns" ] || continue
        printf 'target\t%s\t%s\n' "$ns" "$name"
      done
}

# Resolve an application repository to its whole target set from the map: the
# Deployments that run its image, its Sentry project, and its deploy workflow.
# Prints "target<TAB>ns<TAB>name", "sentry<TAB>slug", "run<TAB>repo<TAB>workflow",
# and "note<TAB>text" lines. LIVE QUERY (cluster inventory).
cw_repo_targets() {  # <repo>
  local repo=$1 specs spec
  specs=$(cw_repo_specs "$repo")
  [ -n "$specs" ] || return 1
  for spec in $specs; do
    cw_spec_targets "$spec"
  done
  return 0
}

# Resolve an application repository's name to "target<TAB>namespace<TAB>name"
# from a local H-DevOps checkout's k8s/prod tree. Read-only; prints nothing when
# unresolved or when the Deployment declares no namespace. Used only when the
# image inventory resolves nothing for the repository. LIVE QUERY (checkout).
cw_service_targets() {  # <service>
  local root=${FM_CW_HDEVOPS_K8S_DIR:-$FM_HOME/projects/H-DevOps/k8s/prod}
  local service=$1 dir manifest ns name
  [ -d "$root" ] || return 1
  for dir in "$root"/*; do
    [ -d "$dir" ] || continue
    for manifest in "$dir"/*.yaml "$dir"/*.yml; do
      [ -f "$manifest" ] || continue
      while IFS=$'\t' read -r ns name; do
        [ "$name" = "$service" ] && [ -n "$ns" ] || continue
        printf 'target\t%s\t%s\n' "$ns" "$name"
        return 0
      done < <(cw_manifest_deployments < "$manifest")
    done
  done
  return 1
}

# Map one manifest's changed lines onto its Deployment documents. Prints
# "target<TAB>namespace<TAB>name" per affected Deployment, one
# "note<TAB>whole manifest: <path>" when the lines could not be placed, in which
# case every Deployment of the manifest is a target, and one
# "note<TAB>no namespace: <name> in <path>" per affected Deployment that
# declares no metadata.namespace and is therefore skipped.
cw_place_changed_lines() {  # <path> <docs> <lines>
  CW_LINES="$3" awk -F'\t' -v path="$1" '
    BEGIN { lines = ENVIRON["CW_LINES"]; n = split(lines, l, "\n"); whole = (lines == "") }
    { start[NR] = $1; end[NR] = $2; kind[NR] = $3; ns[NR] = $4; name[NR] = $5 }
    END {
      if (!whole) {
        for (i = 1; i <= n; i++) {
          if (l[i] == "") continue
          hit = 0
          for (d = 1; d <= NR; d++) {
            if (l[i] + 0 >= start[d] && l[i] + 0 <= end[d]) {
              hit = 1
              if (kind[d] == "Deployment" && name[d] != "") pick[d] = 1
            }
          }
          if (!hit) whole = 1
        }
      }
      if (whole) for (d = 1; d <= NR; d++) if (kind[d] == "Deployment" && name[d] != "") pick[d] = 1
      for (d = 1; d <= NR; d++) {
        if (!pick[d]) continue
        if (ns[d] == "") printf "note\tno namespace: %s in %s\n", name[d], path
        else printf "target\t%s\t%s\n", ns[d], name[d]
      }
      if (whole) printf "note\twhole manifest: %s\n", path
    }
  ' <<DOCS
$2
DOCS
}

# Derive the affected Deployments from the merged PR. Prints
# "target<TAB>namespace<TAB>name" lines and "note<TAB>text" lines; prints no
# target when no deployable service is touched.
cw_derive_targets() {  # <url> <provider> <owner> <repo> <number> <repo-name>
  local url=$1 provider=$2 owner=$3 repo=$4 number=$5 repo_name=$6
  local files manifests ref changed path docs lines placed any=0 reads=0
  files=$(cw_forge_files "$url" "$provider" "$owner" "$repo" "$number") || return 1
  [ -n "$files" ] || return 1
  manifests=$(printf '%s\n' "$files" | grep -E '^k8s/prod/[^/]+/[^/]+\.ya?ml$' || true)
  if [ -z "$manifests" ]; then
    cw_app_targets "$repo_name"
    return
  fi
  ref=$(cw_forge_head_ref "$url" 2>/dev/null || true)
  changed=$(cw_forge_diff "$url" "$provider" 2>/dev/null | cw_diff_changed_lines || true)
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if printf '%s\n' "$changed" | grep -qxF "$path	removed"; then
      printf 'note\tmanifest removed: %s\n' "$path"
      continue
    fi
    if [ -z "$ref" ] || [ "$reads" -ge "$MAX_MANIFEST_READS" ]; then
      printf 'note\tmanifest unread: %s\n' "$path"
      continue
    fi
    reads=$((reads + 1))
    docs=$(cw_forge_content "$owner" "$repo" "$path" "$ref" 2>/dev/null | cw_manifest_docs) || docs=''
    if [ -z "$docs" ]; then
      printf 'note\tmanifest unread: %s\n' "$path"
      continue
    fi
    lines=$(printf '%s\n' "$changed" | awk -F'\t' -v p="$path" '$1 == p { print $2 }')
    placed=$(cw_place_changed_lines "$path" "$docs" "$lines")
    [ -n "$placed" ] || continue
    printf '%s\n' "$placed"
    case "$placed" in *target*) any=1 ;; esac
  done <<PATHS
$manifests
PATHS
  [ "$any" -eq 1 ] && return 0
  cw_app_targets "$repo_name"
}

# An application repository's targets: its image family from the live cluster,
# its mapped Sentry project, and its mapped deploy workflow. Falls back to the
# local H-DevOps checkout's Deployment names when the inventory resolves no
# Deployment for the repository, so a repository whose image name is unknown is
# still watched rather than silently unwatched.
cw_app_targets() {  # <repo>
  local repo=$1 out targets
  out=$(cw_repo_targets "$repo" 2>/dev/null || true)
  targets=$(printf '%s\n' "$out" | grep -c '^target	' || true)
  if [ "$targets" -eq 0 ] && ! printf '%s\n' "$out" | grep -q '^run	'; then
    # The image inventory resolved no Deployment. Fall back to the checkout's own
    # manifest, and keep every non-Deployment target the map already resolved
    # (its Sentry project, its deploy workflow): those reads never touch the
    # cluster, so a cluster that refused the inventory is no reason to lose them.
    if cw_service_targets "$repo"; then
      printf '%s\n' "$out" | grep -v '^target	' || true
    else
      printf '%s\n' "$out"
    fi
    return 0
  fi
  printf '%s\n' "$out"
}

# --- live metric reads --------------------------------------------------------
# Each live query below is self-contained and can be run by hand with the same
# arguments, so an operator can reproduce any sample outside this script.

# LIVE QUERY (cluster) - 5xx responses per minute for one Deployment's pods, from
# the app's own access log over the window, kept only when the HTTP/1.1 line
# count proves the probe executed. Each container's read is capped at
# LOG_TAIL_LINES lines; a container that hit the cap is rated over the span its
# lines cover, one that did not over the whole window.
cw_live_http_5xx_per_min() {  # <ns> <deploy> <window-seconds>
  local ns=$1 deploy=$2 secs=$3 out
  out=$(cw_kubectl -n "$ns" logs --tail="$LOG_TAIL_LINES" --since="${secs}s" --max-log-requests=10 \
    --prefix --timestamps -l "app=$deploy" 2>/dev/null | python3 -c '
import datetime, re, sys
window = float(sys.argv[1])
cap = int(sys.argv[2])
error_re = re.compile(r"500 Internal|\"\s5[0-9][0-9]\s")
pods = {}
for line in sys.stdin:
    line = line.rstrip("\n")
    pod = ""
    if line.startswith("["):
        end = line.find("] ")
        if end > 0:
            pod = line[1:end]
            line = line[end + 2:]
    ts, _, rest = line.partition(" ")
    try:
        t = datetime.datetime.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        continue
    epoch = t.replace(tzinfo=datetime.timezone.utc).timestamp()
    p = pods.setdefault(pod, {"first": epoch, "last": epoch, "lines": 0, "http": 0, "errors": 0})
    p["first"] = min(p["first"], epoch)
    p["last"] = max(p["last"], epoch)
    p["lines"] += 1
    if "HTTP/1.1" in rest:
        p["http"] += 1
    if error_re.search(rest):
        p["errors"] += 1
if sum(p["http"] for p in pods.values()) == 0:
    sys.exit(1)
rate = 0.0
for p in pods.values():
    span = window if p["lines"] < cap else max(p["last"] - p["first"], 1.0)
    rate += p["errors"] * 60.0 / span
print("%.4f" % rate)
' "$secs" "$LOG_TAIL_LINES" 2>/dev/null)
  [ -n "$out" ] || {
    printf 'no HTTP access-log status lines in this Deployment\047s pod logs over the window\n' >&2
    return 1
  }
  printf '%s\n' "$out"
}

# LIVE QUERY (cluster) - one Deployment's pod facts, read once and reused by
# every metric that needs them: restartCount total, the OOMKilled termination
# epochs, the pod images, and the per-container memory limits that the
# working-set ratio divides by, and the pods' pod-template-hash labels that the
# landing gate uses to prove a rollout. The row is epoch-free so one read answers
# the landing gate and every pod-backed metric of the sample; cw_prime_pod_facts
# takes that read in this process, because a memo written inside a per-metric
# command substitution dies with its subshell. Prints
# "restarts<TAB>oom-epochs<TAB>images<TAB>pairs<TAB>hashes" where oom-epochs is
# the termination epochs joined by "," (0 for a termination that carries no
# timestamp), pairs is "pod,container,limit-bytes" joined by ";", and hashes is
# the sorted distinct pod-template-hash values joined by ",".
CW_POD_FACTS_CACHE=''
CW_WORKLOADS_CACHE=''
# A read that failed is remembered for the sample as this sentinel, so a target
# whose pods cannot be read costs one attempt instead of one per metric.
CW_POD_FACTS_FAILED='!'
cw_pod_facts_failed() {  # <key>
  CW_POD_FACTS_CACHE="$CW_POD_FACTS_CACHE$1	$CW_POD_FACTS_FAILED
"
}
cw_pod_facts() {  # <ns> <deploy>
  local ns=$1 deploy=$2 key cached
  key="$ns/$deploy"
  while IFS=$'\t' read -r k v; do
    [ "$k" = "$key" ] || continue
    [ "$v" = "$CW_POD_FACTS_FAILED" ] && return 1
    printf '%s\n' "$v"
    return 0
  done <<CACHE
$CW_POD_FACTS_CACHE
CACHE
  command -v kubectl >/dev/null 2>&1 || { cw_pod_facts_failed "$key"; return 1; }
  cached=$(cw_kubectl -n "$ns" get pods -l "app=$deploy" -o json 2>/dev/null | python3 -c '
import datetime, json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
items = data.get("items", [])
if not items:
    sys.exit(1)
restarts = 0
ooms = []
images = []
hashes = []
pairs = []
for pod in items:
    pname = pod.get("metadata", {}).get("name", "")
    h = (pod.get("metadata", {}).get("labels", {}) or {}).get("pod-template-hash", "")
    if h and h not in hashes:
        hashes.append(h)
    for cs in pod.get("status", {}).get("containerStatuses", []) or []:
        restarts += int(cs.get("restartCount", 0) or 0)
        for state in (cs.get("lastState", {}) or {}).values():
            if not isinstance(state, dict) or state.get("reason") != "OOMKilled":
                continue
            ts = state.get("finishedAt") or ""
            try:
                t = datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
                ooms.append(int(t.replace(tzinfo=datetime.timezone.utc).timestamp()))
            except ValueError:
                ooms.append(0)
    for c in pod.get("spec", {}).get("containers", []) or []:
        img = c.get("image", "")
        if img and img not in images:
            images.append(img)
        raw = str((c.get("resources", {}).get("limits", {}) or {}).get("memory", "") or "")
        factor = 1
        for suffix, mult in (("Ki", 1024), ("Mi", 1024 ** 2), ("Gi", 1024 ** 3),
                             ("K", 1000), ("M", 1000 ** 2), ("G", 1000 ** 3)):
            if raw.endswith(suffix):
                factor = mult
                raw = raw[: -len(suffix)]
                break
        try:
            limit = float(raw) * factor
        except ValueError:
            limit = 0.0
        if limit > 0:
            pairs.append("%s,%s,%.0f" % (pname, c.get("name", ""), limit))
print("%d\t%s\t%s\t%s\t%s" % (restarts, ",".join(str(e) for e in ooms),
                              ",".join(images), ";".join(pairs), ",".join(hashes)))
') || { cw_pod_facts_failed "$key"; return 1; }
  [ -n "$cached" ] || { cw_pod_facts_failed "$key"; return 1; }
  CW_POD_FACTS_CACHE="$CW_POD_FACTS_CACHE$key	$cached
"
  printf '%s\n' "$cached"
}

# Read every target's pod facts once per sample so the landing gate and each
# pod-backed metric are served by that one read: a whole image family then costs
# one pod read per target instead of one per metric per target.
cw_prime_pod_facts() {  # <watch-id>
  local id=$1 ns deploy
  [ -f "$(cw_targets_path "$id")" ] || return 0
  while IFS=$'\t' read -r ns deploy; do
    [ -n "${ns:-}" ] || continue
    cw_within_budget || return 0
    cw_pod_facts "$ns" "$deploy" >/dev/null 2>&1 || true
  done < "$(cw_targets_path "$id")"
}

# One field of a target's pod facts, or nothing when the read failed.
cw_pod_fact() {  # <ns> <deploy> <field>
  local facts
  facts=$(cw_pod_facts "$1" "$2") || return 1
  printf '%s' "$facts" | cut -f"$3"
}

# LIVE QUERY (cluster) - total container restartCount across the Deployment.
cw_live_restarts() {  # <ns> <deploy>
  cw_pod_fact "$1" "$2" 1
}

# LIVE QUERY (cluster) - OOMKilled terminations at or after the baseline epoch.
# An OOMKilled pod that restarted successfully never shows in the pod's current
# STATUS, so lastState is the only honest signal. A termination that carries no
# timestamp cannot be proven to predate the baseline, so it counts.
cw_live_oomkilled() {  # <ns> <deploy> <baseline-epoch>
  local epochs
  epochs=$(cw_pod_fact "$1" "$2" 2) || return 1
  printf '%s' "$epochs" | awk -F, -v since="${3:-0}" '
    { for (i = 1; i <= NF; i++) if ($i != "" && ($i + 0 == 0 || $i + 0 >= since)) n++ }
    END { print n + 0 }
  '
}

# LIVE QUERY (cluster) - the pod images a target runs, comma-separated.
cw_live_images() {  # <ns> <deploy>
  cw_pod_fact "$1" "$2" 3
}

# LIVE QUERY (cluster) - the rollout fingerprint a target is judged by: its pod
# images plus its pods' pod-template-hash labels. A Deployment rollout always
# mints a new template hash, so an env or routing change that leaves every image
# byte-identical still changes the fingerprint, while a mutable tag or a
# digest-pinned reference still proves the rollout happened by its own hash.
cw_live_fingerprint() {  # <ns> <deploy>
  local facts images hashes
  facts=$(cw_pod_facts "$1" "$2") || return 1
  images=$(printf '%s' "$facts" | cut -f3)
  hashes=$(printf '%s' "$facts" | cut -f5)
  [ -n "$images$hashes" ] || return 1
  printf '%s|%s\n' "$images" "$hashes"
}

# LIVE QUERY (cluster) - request p95 latency where the service exposes it, from
# the conventional per-service Prometheus histogram. An absent series is
# unmeasured, not a pass. The read needs a port-forward into the monitoring
# namespace, which a read-only reader is usually not granted; that refusal is a
# measured gap with its reason recorded, never a silent zero.
cw_live_p95_ms() {  # <ns> <deploy> <window-seconds>
  local ns=$1 deploy=$2 secs=$3 value rc
  command -v kubectl >/dev/null 2>&1 || return 1
  command -v curl >/dev/null 2>&1 || return 1
  fm_run_timed "$(cw_budget_left || printf 5)" kubectl -n monitoring \
    auth can-i create pods/portforward >/dev/null 2>&1 || {
    printf 'port-forward into the monitoring namespace is not permitted for this reader, so the Prometheus p95 series cannot be read\n' >&2
    return 1
  }
  value=$(
    cw_kubectl -n monitoring port-forward svc/kube-prometheus-kube-prome-prometheus 19090:9090 >/dev/null 2>&1 &
    pf=$!
    sleep 1
    curl -fsS -G 'http://127.0.0.1:19090/api/v1/query' \
      --data-urlencode "query=histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{namespace=\"$ns\",app=\"$deploy\"}[${secs}s])) by (le))" \
      2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    print(float(data["data"]["result"][0]["value"][1]) * 1000)
except Exception:
    sys.exit(1)
' 2>/dev/null
    rc=$?
    kill "$pf" 2>/dev/null || true
    exit "$rc"
  )
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

# LIVE QUERY (cluster) - highest container working set as a fraction of its
# memory limit across the Deployment's pods. The limits come from the pod facts
# read the other pod metrics already share, and the working set from
# metrics-server (POD NAME CONTAINER CPU MEMORY); the worst ratio wins.
cw_live_rss_ratio() {  # <ns> <deploy> <window-seconds>
  local ns=$1 deploy=$2 limits usage
  limits=$(cw_pod_fact "$1" "$2" 4) || return 1
  [ -n "$limits" ] || return 1
  usage=$(cw_kubectl -n "$ns" top pods -l "app=$deploy" --containers --no-headers 2>/dev/null) || return 1
  [ -n "$usage" ] || return 1
  printf '%s\n' "$limits" | tr ';' '\n' | CW_USAGE="$usage" awk -F',' '
    function bytes(u,    two, one) {
      two = substr(u, length(u) - 1, 2)
      one = substr(u, length(u), 1)
      if (two == "Ki") return substr(u, 1, length(u) - 2) * 1024
      if (two == "Mi") return substr(u, 1, length(u) - 2) * 1048576
      if (two == "Gi") return substr(u, 1, length(u) - 2) * 1073741824
      if (one == "K") return substr(u, 1, length(u) - 1) * 1000
      if (one == "M") return substr(u, 1, length(u) - 1) * 1000000
      if (one == "G") return substr(u, 1, length(u) - 1) * 1000000000
      return u + 0
    }
    BEGIN {
      n = split(ENVIRON["CW_USAGE"], rows, "\n")
      for (i = 1; i <= n; i++) {
        m = split(rows[i], f, /[ \t]+/)
        if (m < 4) continue
        used[f[1] SUBSEP f[2]] = bytes(f[4])
      }
      worst = 0
    }
    {
      key = $1 SUBSEP $2
      if (key in used && $3 + 0 > 0) {
        r = used[key] / ($3 + 0)
        if (r > worst) worst = r
      }
    }
    END { if (worst > 0) printf "%.4f\n", worst }
  '
}

# LIVE QUERY (http) - the mapped Sentry project's new error and fatal issues:
# those first seen at or after <since-epoch>. A missing credential, an unmapped
# project, or a refused read is unmeasured with its reason, never a zero.

# True when the vault holds a token, without ever materialising the token itself.
cw_sentry_vault_ready() {
  local file=$SENTRY_VAULT
  [ -r "$file" ] || return 1
  python3 - "$file" <<'PY' 2>/dev/null || return 1
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
inner = data.get("data") if isinstance(data, dict) else None
if not isinstance(inner, dict) or not (inner.get("auth_token") or ""):
    sys.exit(1)
PY
}

# One page of the mapped project's issues first seen at or after <since>, as the
# JSON its caller counts. The filter is server-side so a busy project's newest
# issues are the page itself rather than whatever survived a most-recently-seen
# cut, and the token is read and used inside the interpreter only: unlike a curl
# header built from it, it never appears in any process's argv.
cw_sentry_issue_page() {  # <project> <since-epoch>
  local project=$1 since=$2 budget
  if [ -n "${FM_CW_SENTRY_DIR:-}" ]; then
    [ -f "$FM_CW_SENTRY_DIR/issues-$project.json" ] || return 1
    cat "$FM_CW_SENTRY_DIR/issues-$project.json"
    return 0
  fi
  command -v python3 >/dev/null 2>&1 || return 1
  budget=$(cw_budget_left || printf '%s' "$SENTRY_HTTP_TIMEOUT")
  fm_run_timed "$budget" python3 -c '
import datetime, json, sys, urllib.error, urllib.parse, urllib.request
vault, project, since, timeout = sys.argv[1], sys.argv[2], int(sys.argv[3]), float(sys.argv[4])
try:
    data = json.load(open(vault))
except Exception:
    sys.stderr.write("no readable Sentry vault at %s\n" % vault)
    sys.exit(1)
inner = data.get("data") if isinstance(data, dict) else None
if not isinstance(inner, dict):
    sys.stderr.write("Sentry vault %s has no data section\n" % vault)
    sys.exit(1)
token = inner.get("auth_token") or ""
if not token:
    sys.stderr.write("no Sentry token in %s\n" % vault)
    sys.exit(1)
host = inner.get("host") or "sentry.io"
org = inner.get("org") or "musoai"
first_seen = datetime.datetime.fromtimestamp(since, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
params = urllib.parse.urlencode({
    "query": "is:unresolved firstSeen:>=%s" % first_seen,
    "limit": "100",
    "sort": "new",
})
url = "https://%s/api/0/projects/%s/%s/issues/?%s" % (host, org, project, params)
request = urllib.request.Request(url, headers={"Authorization": "Bearer %s" % token})
try:
    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = response.read()
except urllib.error.HTTPError as exc:
    sys.stderr.write("Sentry read refused for %s: HTTP %s\n" % (project, exc.code))
    sys.exit(1)
except Exception as exc:
    sys.stderr.write("Sentry read refused for %s: %s\n" % (project, exc))
    sys.exit(1)
try:
    issues = json.loads(body)
except ValueError:
    issues = None
if not isinstance(issues, list):
    sys.stderr.write("Sentry returned an unreadable issue list for %s\n" % project)
    sys.exit(1)
json.dump(issues, sys.stdout)
' "$SENTRY_VAULT" "$project" "$since" "$SENTRY_HTTP_TIMEOUT"
}

cw_live_sentry_new_issues() {  # <project> <since-epoch>
  local project=$1 since=$2 page
  case "$project" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  page=$(cw_sentry_issue_page "$project" "$since") || return 1
  printf '%s' "$page" | python3 -c '
import datetime, json, sys
since = int(sys.argv[1] or 0)
try:
    issues = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(issues, list):
    sys.exit(1)
count = 0
for issue in issues:
    level = (issue.get("level") or "").lower()
    if level not in ("error", "fatal"):
        continue
    first = issue.get("firstSeen") or ""
    try:
        t = datetime.datetime.strptime(first.replace("Z", "")[:19], "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        continue
    if int(t.replace(tzinfo=datetime.timezone.utc).timestamp()) >= since:
        count += 1
print(count)
' "$since"
}

# LIVE QUERY (forge) - the mapped deploy workflow's run created at or after the
# merge: 1 when the earliest such run completed successfully, 0 when it failed,
# and nothing while no run exists or one is still in flight (both are awaiting
# the deploy, never health).
cw_live_deploy_run() {  # <owner/repo> <workflow> <since-epoch>
  local repo=$1 workflow=$2 since=$3 gh_cmd=${FM_CW_GH:-gh} out rc=0
  if [ -n "${FM_CW_GH_DIR:-}" ]; then
    local safe=${workflow//[\/ ]/_}
    [ -f "$FM_CW_GH_DIR/runs-$repo-$safe.json" ] || {
      printf 'no %s run since the merge\n' "$workflow"
      return 1
    }
    out=$(cat "$FM_CW_GH_DIR/runs-$repo-$safe.json")
  else
    command -v "$gh_cmd" >/dev/null 2>&1 || return 1
    out=$(cw_forge_run "$gh_cmd" run list -R "$repo" --workflow "$workflow" --limit 20 \
      --json conclusion,status,createdAt,databaseId,url) || rc=$?
    if [ "${rc:-0}" -ne 0 ]; then
      # A spent budget is stated as itself: "read exited 124 with no value" told
      # nobody why the deploy target stayed unmeasured.
      [ "${rc:-0}" -ne 124 ] || printf 'the forge read budget for this sample was already spent\n'
      return 1
    fi
  fi
  printf '%s' "$out" | python3 -c '
import datetime, json, sys
since = int(sys.argv[1] or 0)
try:
    runs = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(runs, list):
    sys.exit(1)
candidates = []
for run in runs:
    created = run.get("createdAt") or ""
    try:
        t = datetime.datetime.strptime(created.replace("Z", "")[:19], "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        continue
    if int(t.replace(tzinfo=datetime.timezone.utc).timestamp()) >= since:
        candidates.append(run)
if not candidates:
    print("no run created at or after the merge")
    sys.exit(1)
candidates.sort(key=lambda r: r.get("createdAt") or "")
run = candidates[0]
status = (run.get("status") or "")
conclusion = (run.get("conclusion") or "")
if status != "completed" or not conclusion:
    print("run in flight: status %s" % (status or "unknown"))
    sys.exit(1)
if conclusion == "success":
    print("1")
    sys.exit(0)
print("0")
' "$since"
}

# LIVE QUERY (cluster) - the Deployment's own pgbouncer pool as
# "ip<TAB>port<TAB>database": DB_HOST/DB_PORT/DB_NAME from the pod spec with
# secret refs resolved, and the pooler endpoint behind that Service from its
# EndpointSlice. Prints nothing when any step is unresolvable.
cw_live_pool_spec() {  # <ns> <deploy>
  local ns=$1 deploy=$2 env host port db svc rest sns endpoint
  env=$(cw_kubectl -n "$ns" set env "deployment/$deploy" --list --resolve 2>/dev/null) || return 1
  host=$(printf '%s\n' "$env" | awk -F= '$1 == "DB_HOST" { print $2; exit }')
  port=$(printf '%s\n' "$env" | awk -F= '$1 == "DB_PORT" { print $2; exit }')
  db=$(printf '%s\n' "$env" | awk -F= '$1 == "DB_NAME" { print $2; exit }')
  [ -n "$host" ] && [ -n "$db" ] || return 1
  case "$port" in ''|*[!0-9]*) port=5432 ;; esac
  case "$db" in *[!A-Za-z0-9_-]*) return 1 ;; esac
  case "$host" in
    *[!0-9.]*)
      svc=${host%%.*}
      rest=${host#*.}
      sns=${rest%%.*}
      [ -n "$svc" ] && [ -n "$sns" ] && [ "$rest" != "$host" ] || return 1
      endpoint=$(cw_kubectl -n "$sns" get endpointslices -l "kubernetes.io/service-name=$svc" -o json 2>/dev/null \
        | python3 -c '
import json, sys
want = int(sys.argv[1])
data = json.load(sys.stdin)
for item in data.get("items", []):
    ports = [int(p["port"]) for p in item.get("ports", []) or [] if p.get("port")]
    if not ports:
        continue
    port = want if want in ports else ports[0]
    for ep in item.get("endpoints", []) or []:
        for addr in ep.get("addresses", []) or []:
            print("%s\t%s" % (addr, port))
            sys.exit(0)
sys.exit(1)
' "$port" 2>/dev/null) || return 1
      ;;
    *) endpoint=$(printf '%s\t%s' "$host" "$port") ;;
  esac
  [ -n "$endpoint" ] || return 1
  printf '%s\t%s\n' "$endpoint" "$db"
}

# LIVE QUERY (pooler host) - the pgbouncer admin console's SHOW POOLS on the
# pooler at <host>, reached as ubuntu over ssh with stdin closed (so the read
# can never drain a caller's input stream), through the admin unix socket, and
# bounded by the remaining sample budget. Prints the console's unaligned rows;
# exit 124 when the bound was hit.
# A host whose console did not answer is remembered for this sample: a watch
# with several targets on one unreachable pooler must not spend the sample budget
# on the same connect timeout once per target. The record is a file because every
# pool read runs inside a command substitution, where a variable assignment dies
# with its subshell.
# The path is made once per process with mktemp so no other process can
# pre-place it, and it is unlinked when the process exits.
CW_POOL_BAD_HOSTS_FILE=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-cw-pool-unreachable.XXXXXX" 2>/dev/null) || CW_POOL_BAD_HOSTS_FILE=''
cw_pool_memo_clear() {
  [ -z "$CW_POOL_BAD_HOSTS_FILE" ] || rm -f -- "$CW_POOL_BAD_HOSTS_FILE" 2>/dev/null || true
}
cw_pool_console() {  # <host> <port>
  local host=$1 port=$2 left out rc
  command -v ssh >/dev/null 2>&1 || return 1
  case "$port" in ''|*[!0-9]*) return 1 ;; esac
  case "$host" in ''|*[!A-Za-z0-9.-]*) return 1 ;; esac
  if [ -n "$CW_POOL_BAD_HOSTS_FILE" ] && grep -qxF -- "$host" "$CW_POOL_BAD_HOSTS_FILE" 2>/dev/null; then
    printf '%s: console unreachable (recorded earlier in this read)\n' "$host" >&2
    return 1
  fi
  left=$(cw_budget_left) || return 124
  out=$(fm_run_timed "$left" ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
    "$POOLER_SSH_USER@$host" \
    "sudo -u postgres psql -h $POOLER_SOCKET_DIR -p $port -U pgbouncer pgbouncer -Ac 'SHOW POOLS'")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    [ -z "$CW_POOL_BAD_HOSTS_FILE" ] \
      || printf '%s\n' "$host" >> "$CW_POOL_BAD_HOSTS_FILE" 2>/dev/null || true
    return "$rc"
  fi
  printf '%s\n' "$out"
}

# Clients waiting on one database's pools (cl_waiting summed over that
# database's users). An unreachable console or an absent database is unmeasured.
cw_live_pgbouncer_cl_waiting() {  # <host> <port> <database>
  local host=$1 port=$2 db=$3 out err rc
  case "$db" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  err=$(mktemp "${TMPDIR:-/tmp}/fm-cw-pool.XXXXXX" 2>/dev/null) || err=/dev/null
  out=$(cw_pool_console "$host" "$port" 2>"$err")
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    printf 'pgbouncer console %s:%s unreachable: %s\n' "$host" "$port" \
      "$(tail -1 "$err" 2>/dev/null || printf 'exit %s with no rows' "$rc")" >&2
    [ "$err" = /dev/null ] || rm -f -- "$err"
    return 1
  fi
  [ "$err" = /dev/null ] || rm -f -- "$err"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | awk -F'|' -v db="$db" '
    NR == 1 {
      for (i = 1; i <= NF; i++) { if ($i == "database") d = i; if ($i == "cl_waiting") w = i }
      next
    }
    d && w && $d == db { sum += $w + 0; found = 1 }
    END { if (!found) exit 1; printf "%.0f\n", sum }
  '
}

# Resolve one target's pool through the test seam or the live query.
cw_resolve_pool_spec() {  # <ns> <deploy>
  local file
  if [ -n "${FM_CW_CLUSTER_DIR:-}" ]; then
    file="$FM_CW_CLUSTER_DIR/pool.$(printf '%s_%s' "$1" "$2")"
    [ -f "$file" ] || return 1
    head -1 "$file"
    return 0
  fi
  cw_live_pool_spec "$1" "$2"
}

cw_pool_spec() {  # <watch-id> <target>
  local file
  file=$(cw_pools_path "$1")
  [ -f "$file" ] || return 1
  awk -F'\t' -v t="$2" '$1 == t && $2 != "" { print $2 "\t" $3 "\t" $4; found = 1; exit } END { exit(found ? 0 : 1) }' "$file"
}

# Dispatch one metric read through the test seam or its live function.
cw_metric_read() {  # <watch-id> <metric> <target> <window> [<baseline-epoch>]
  local id=$1 metric=$2 target=$3 window=$4 since=${5:-0}
  local file value sanitized secs ns='' deploy='' spec=''
  if [ "$metric" = pgbouncer_cl_waiting ]; then
    if ! spec=$(cw_pool_spec "$id" "$target"); then
      printf 'no pgbouncer pool was resolved for this target, so its pool metric is unmeasured for the whole watch\n' >&2
      return 1
    fi
  fi
  if [ -n "${FM_CW_CLUSTER_DIR:-}" ]; then
    sanitized=$(printf '%s' "$target" | tr '/' '_')
    file="$FM_CW_CLUSTER_DIR/$metric.$sanitized.$window"
    [ -f "$file" ] || return 1
    value=$(cw_series_next "$file" "$metric.$sanitized.$window")
    case "$value" in
      '') return 1 ;;
      *) printf '%s\n' "$value"; return 0 ;;
    esac
  fi
  case "$metric" in
    sentry_new_issues)
      cw_live_sentry_new_issues "${target#sentry/}" "$since"
      return $?
      ;;
    deploy_run)
      local run_target=${target#run/}
      cw_live_deploy_run "${run_target%%#*}" "${run_target#*#}" "$since"
      return $?
      ;;
  esac
  case "$target" in
    */*) ns=${target%%/*}; deploy=${target#*/} ;;
    *) return 1 ;;
  esac
  if [ "$window" = baseline ]; then secs=$BASELINE_WINDOW_SECONDS; else secs=$SAMPLE_WINDOW_SECONDS; fi
  case "$metric" in
    http_5xx_per_min) cw_live_http_5xx_per_min "$ns" "$deploy" "$secs" ;;
    restarts) cw_live_restarts "$ns" "$deploy" ;;
    oomkilled) cw_live_oomkilled "$ns" "$deploy" "$since" ;;
    p95_ms) cw_live_p95_ms "$ns" "$deploy" "$secs" ;;
    rss_ratio) cw_live_rss_ratio "$ns" "$deploy" "$secs" ;;
    pgbouncer_cl_waiting)
      cw_live_pgbouncer_cl_waiting "$(printf '%s' "$spec" | cut -f1)" \
        "$(printf '%s' "$spec" | cut -f2)" "$(printf '%s' "$spec" | cut -f3)"
      ;;
    *) return 1 ;;
  esac
}

# Read the next value from a stub series, consuming it through a durable cursor.
cw_series_next() {  # <file> <cursor-id>
  local file=$1 id=$2 cursor_file total next
  mkdir -p "$WATCH_ROOT" 2>/dev/null || true
  cursor_file="$WATCH_ROOT/.series-cursor.$id"
  total=$(grep -c '' "$file" 2>/dev/null || echo 0)
  next=$(( $(cat "$cursor_file" 2>/dev/null || echo 0) + 1 ))
  printf '%s\n' "$next" > "$cursor_file" 2>/dev/null || true
  [ "$next" -le "$total" ] || return 1
  sed -n "${next}p" "$file"
}

# --- baseline and sample ------------------------------------------------------

cw_metric_keys() {  # <watch-id>
  local id=$1 target ns deploy metric project run_repo workflow
  if [ -f "$(cw_targets_path "$id")" ]; then
    while IFS=$'\t' read -r ns deploy; do
      [ -n "${ns:-}" ] || continue
      target="$ns/$deploy"
      for metric in $K8S_METRICS; do
        printf '%s@%s\n' "$metric" "$target"
      done
    done < "$(cw_targets_path "$id")"
  fi
  if [ -f "$(cw_sentry_path "$id")" ]; then
    while IFS= read -r project; do
      [ -n "$project" ] || continue
      for metric in $SENTRY_METRICS; do
        printf '%s@sentry/%s\n' "$metric" "$project"
      done
    done < "$(cw_sentry_path "$id")"
  fi
  if [ -f "$(cw_runs_path "$id")" ]; then
    while IFS=$'\t' read -r run_repo workflow; do
      [ -n "${run_repo:-}" ] || continue
      for metric in $RUN_METRICS; do
        printf '%s@run/%s#%s\n' "$metric" "$run_repo" "$workflow"
      done
    done < "$(cw_runs_path "$id")"
  fi
}

# Every target of every kind this watch was registered with, as the target
# strings the metric keys carry, so a completion can name what it never read.
cw_target_ids() {  # <watch-id>
  local id=$1 ns deploy project run_repo workflow
  if [ -f "$(cw_targets_path "$id")" ]; then
    while IFS=$'\t' read -r ns deploy; do
      [ -n "${ns:-}" ] || continue
      printf '%s/%s\n' "$ns" "$deploy"
    done < "$(cw_targets_path "$id")"
  fi
  if [ -f "$(cw_sentry_path "$id")" ]; then
    while IFS= read -r project; do
      [ -n "$project" ] || continue
      printf 'sentry/%s\n' "$project"
    done < "$(cw_sentry_path "$id")"
  fi
  if [ -f "$(cw_runs_path "$id")" ]; then
    while IFS=$'\t' read -r run_repo workflow; do
      [ -n "${run_repo:-}" ] || continue
      printf 'run/%s#%s\n' "$run_repo" "$workflow"
    done < "$(cw_runs_path "$id")"
  fi
}

# The landing gate: a Kubernetes target is scored only once the rollout it
# ran at registration have been replaced, so a sample can never report the code
# the release replaced as healthy. 0 = landed or nothing to compare, 2 = still
# awaiting the rollout, 3 = images unreadable.
cw_target_landed() {  # <watch-id> <ns> <deploy>
  local id=$1 ns=$2 deploy=$3 row recorded fingerprint current
  [ -f "$(cw_landed_path "$id")" ] || return 0
  row=$(awk -F'\t' -v t="$ns/$deploy" '$1 == t { print $2 "|" $3; found = 1 } END { exit(found ? 0 : 1) }' \
    "$(cw_landed_path "$id")" 2>/dev/null) || return 0
  recorded=${row%%|*}
  fingerprint=${row#*|}
  # No image was recorded for this target, so the rollout cannot be proven.
  # The watch still measures its metrics (a reader that works is worth more than
  # a silent 12h gap) but every verdict says the landing was never proven.
  [ -n "$recorded" ] || return 0
  if [ -n "$fingerprint" ]; then
    # A landing record from this release carries the fingerprint: the rollout is
    # proven by the template hash, so a change that leaves every image identical
    # (an env value, a routing table) still opens the gate.
    current=$(cw_live_fingerprint "$ns" "$deploy" 2>/dev/null) || return 3
    [ -n "$current" ] || return 3
    [ "$current" = "$fingerprint" ] || return 0
    return 2
  fi
  # A landed record written before the fingerprint existed compares the images,
  # which is all it recorded.
  current=$(cw_live_images "$ns" "$deploy" 2>/dev/null) || return 3
  [ -n "$current" ] || return 3
  [ "$current" = "$recorded" ] || return 0
  return 2
}

# Record the images and rollout fingerprint every Kubernetes target runs right
# now, the evidence the rollout must replace. Both come from one pod read, so a
# target can never be recorded with images but no fingerprint. A target whose
# pods cannot be read is recorded empty and its gate stays open (never scored).
cw_record_images() {  # <watch-id>
  local id=$1 ns deploy facts images hashes fingerprint out=''
  [ -z "${FM_CW_CLUSTER_DIR:-}" ] || return 0
  [ -f "$(cw_targets_path "$id")" ] || return 0
  while IFS=$'\t' read -r ns deploy; do
    [ -n "${ns:-}" ] || continue
    cw_within_budget || break
    facts=$(cw_pod_facts "$ns" "$deploy" 2>/dev/null || true)
    images=$(printf '%s' "$facts" | cut -f3)
    hashes=$(printf '%s' "$facts" | cut -f5)
    fingerprint=''
    [ -z "$images$hashes" ] || fingerprint="$images|$hashes"
    out="$out$ns/$deploy	$images	$fingerprint
"
  done < "$(cw_targets_path "$id")"
  printf '%s' "$out" | cw_write "$(cw_landed_path "$id")"
}

# cw_runs_awaiting_deploy <watch-id> <since-epoch> succeeds when a watch with no
# Deployment target has no completed deploy-workflow run for this release, and
# prints why. The Sentry gate uses it so a repository deployed by its own workflow
# (hydra) does not read its errors before that deploy has landed either.
cw_runs_awaiting_deploy() {  # <watch-id> <since-epoch>
  local id=$1 since=$2 run_repo workflow out rc seen=0 awaiting='' unreadable=''
  [ -f "$(cw_runs_path "$id")" ] || return 1
  while IFS=$'\t' read -r run_repo workflow; do
    [ -n "${run_repo:-}" ] || continue
    [ -n "${workflow:-}" ] || continue
    seen=1
    rc=0
    out=$(cw_live_deploy_run "$run_repo" "$workflow" "$since" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] && continue
    case "$out" in
      no\ *|'run in flight'*) awaiting=${out:-no run has been read} ;;
      '') awaiting='no run has been read' ;;
      *) unreadable=$out ;;
    esac
  done < "$(cw_runs_path "$id")"
  [ "$seen" -eq 1 ] || return 1
  # A read that failed for its own reason is unmeasured, never "awaiting".
  if [ -n "$unreadable" ]; then
    printf '%s\n' "$unreadable"
    return 0
  fi
  [ -n "$awaiting" ] || return 1
  printf 'awaiting the deploy: %s\n' "$awaiting"
  return 0
}

# cw_all_k8s_awaiting <watch-id> succeeds when every k8s target of the watch is
# still running the images it ran at registration, so no rollout has happened.
cw_all_k8s_awaiting() {  # <watch-id>
  local id=$1 ns deploy landed seen=0
  [ -f "$(cw_targets_path "$id")" ] || return 1
  while IFS=$'\t' read -r ns deploy; do
    [ -n "$ns" ] || continue
    seen=1
    landed=0
    cw_target_landed "$id" "$ns" "$deploy" || landed=$?
    [ "$landed" -eq 2 ] || return 1
  done < "$(cw_targets_path "$id")"
  [ "$seen" -eq 1 ]
}

# cw_unproven_landing <watch-id> prints the k8s targets whose pre-merge pod
# images were never readable, so no verdict can claim their rollout was seen.
cw_unproven_landing() {  # <watch-id>
  local id=$1 ns deploy recorded
  [ -f "$(cw_targets_path "$id")" ] || return 0
  while IFS=$'\t' read -r ns deploy; do
    recorded=$(awk -F'\t' -v t="$ns/$deploy" '$1 == t { print $2 }' "$(cw_landed_path "$id")" 2>/dev/null)
    [ -n "$recorded" ] || printf '%s/%s\n' "$ns" "$deploy"
  done < "$(cw_targets_path "$id")"
}

cw_mark_landed() {  # <watch-id> <ns> <deploy> <epoch>
  local id=$1 target="$2/$3"
  [ -f "$(cw_landed_at_path "$id")" ] || : > "$(cw_landed_at_path "$id")"
  grep -qF "$target" "$(cw_landed_at_path "$id")" 2>/dev/null && return 0
  printf '%s\t%s\n' "$target" "$4" >> "$(cw_landed_at_path "$id")" 2>/dev/null || true
}

cw_key_metric() { printf '%s\n' "${1%%@*}"; }
cw_key_target() { printf '%s\n' "${1#*@}"; }

cw_metric_relative() {
  case "$1" in http_5xx_per_min|restarts|p95_ms|sentry_new_issues) return 0 ;; *) return 1 ;; esac
}

# Resolve every target's pool inside the shared budget; an unresolved target has
# no pools line and its pool metric stays unmeasured.
cw_resolve_pools() {  # <watch-id>
  local id=$1 ns deploy spec out=''
  [ -f "$(cw_targets_path "$id")" ] || return 0
  while IFS=$'\t' read -r ns deploy; do
    [ -n "${ns:-}" ] || continue
    cw_within_budget || break
    spec=$(cw_resolve_pool_spec "$ns" "$deploy" 2>/dev/null) || continue
    [ -n "$spec" ] || continue
    out="$out$ns/$deploy	$spec
"
  done < "$(cw_targets_path "$id")"
  printf '%s' "$out" | cw_write "$(cw_pools_path "$id")"
}

# True when a metric's read needs the cluster, mirroring cw_sample_blocker: the
# Sentry and deploy-run reads go over the network, so neither is gated on the
# cluster probe.
cw_baseline_needs_cluster() {  # <metric>
  case "$1" in
    sentry_new_issues|deploy_run) return 1 ;;
  esac
  return 0
}

cw_capture_baseline() {  # <watch-id> <baseline-epoch>
  local id=$1 since=$2 key metric target value out cluster err rc
  out=''
  cw_budget_start
  cw_reasons_begin "$id"
  err=$(mktemp "${TMPDIR:-/tmp}/fm-cw-base.XXXXXX" 2>/dev/null) || err=/dev/null
  cluster=$(cw_cluster_probe || true)
  cw_resolve_pools "$id"
  [ -z "$cluster" ] || cw_record_reason "$id" "baseline" "cluster read failed: $cluster"
  [ -n "$cluster" ] || cw_prime_pod_facts "$id"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    metric=$(cw_key_metric "$key")
    target=$(cw_key_target "$key")
    value=''
    # Only a cluster-backed metric is gated on the probe. A Sentry or deploy-run
    # baseline is read over the network, so a cluster that is down at register
    # time must not cost the whole watch its relative bar.
    if [ -n "$cluster" ] && cw_baseline_needs_cluster "$metric"; then
      :
    elif cw_baseline_needs_cluster "$metric" || cw_within_budget; then
      rc=0
      value=$(cw_metric_read "$id" "$metric" "$target" baseline "$since" 2>"$err") || rc=$?
      if [ "$rc" -ne 0 ] || ! printf '%s' "$value" | grep -qE '^-?[0-9]+([.][0-9]+)?$'; then
        # A reader that explains itself on stdout ("no run since the merge")
        # supplies the reason; one that fails silently is reported by its stderr
        # or its exit status, so a baseline gap is always stated.
        if [ -n "$value" ] && ! printf '%s' "$value" | grep -qE '^[0-9]'; then
          cw_record_reason "$id" "$key" "$(printf '%s' "$value" | tail -1 | cut -c1-200)"
        else
          cw_record_reason "$id" "$key" "$(tail -1 "$err" 2>/dev/null | cut -c1-200)"
        fi
        value=''
      fi
    fi
    out="$out$key	$value
"
  done < <(cw_metric_keys "$id")
  [ "$err" = /dev/null ] || rm -f -- "$err" 2>/dev/null || true
  printf '%s' "$out" | cw_write "$(cw_baseline_path "$id")"
  cw_pool_memo_clear
}

cw_baseline_value() {  # <watch-id> <key>
  local file
  file=$(cw_baseline_path "$1")
  [ -f "$file" ] || return 1
  awk -F'\t' -v k="$2" '$1 == k { print $2; found=1 } END { exit(found ? 0 : 1) }' "$file"
}

# State the bar for one metric and report whether the value crosses it.
cw_metric_regressed() {  # <metric> <value> <baseline> <previous>
  local metric=$1 value=$2 baseline=$3 previous=$4
  [ -n "$value" ] || return 1
  case "$metric" in
    http_5xx_per_min) awk -v v="$value" -v b="$baseline" 'BEGIN { exit !((v+0) > 1 && (v+0) > 3*(b+0)) }' ;;
    restarts) awk -v v="$value" -v b="$baseline" 'BEGIN { exit !((v+0) > (b+0) + 1) }' ;;
    oomkilled) awk -v v="$value" 'BEGIN { exit !((v+0) > 0) }' ;;
    p95_ms) awk -v v="$value" -v b="$baseline" 'BEGIN { exit !((v+0) > (b+0) + 100 && (v+0) > 3*(b+0)) }' ;;
    pgbouncer_cl_waiting) awk -v v="$value" -v p="$previous" 'BEGIN { exit !((v+0) > 0 && (p+0) > 0) }' ;;
    rss_ratio) awk -v v="$value" 'BEGIN { exit !((v+0) > 0.85) }' ;;
    sentry_new_issues)
      awk -v v="$value" -v b="$baseline" -v min="$SENTRY_MIN_NEW" \
        'BEGIN { exit !((v+0) >= min && (v+0) > (b+0)) }' ;;
    deploy_run) awk -v v="$value" 'BEGIN { exit !((v+0) < 1) }' ;;
    *) return 1 ;;
  esac
}

cw_previous_id() { printf '%s' "$1" | tr '/@' '__'; }

cw_previous_value() {  # <watch-id> <key>
  local file
  file=$(cw_last_path "$1" "$(cw_previous_id "$2")")
  [ -f "$file" ] || return 1
  cat "$file"
}

cw_set_previous_value() {  # <watch-id> <key> <value>
  printf '%s\n' "$3" > "$(cw_last_path "$1" "$(cw_previous_id "$2")")" 2>/dev/null || true
}

# Take one sample. Prints "metric<TAB>target<TAB>value<TAB>baseline" for the
# first bar crossed, or nothing when every scored metric is inside its bar.
# Appends one record per metric to samples.log:
#   epoch<TAB>offset<TAB>key<TAB>value<TAB>baseline<TAB>regressed<TAB>scored
# where scored is 0 for an unmeasured value or a relative bar with no baseline.
cw_take_sample() {  # <watch-id> <offset-seconds> <sample-epoch> <baseline-epoch>
  local id=$1 offset=$2 epoch=$3 baseline_epoch=$4
  local key metric target value baseline previous regressed scored first reason cluster err rc
  first=''
  cw_budget_start
  cw_reasons_begin "$id"
  err=$(mktemp "${TMPDIR:-/tmp}/fm-cw-read.XXXXXX" 2>/dev/null) || err=/dev/null
  # Prove the cluster answers once. Without this an unreachable cluster spent the
  # whole budget on reads that each failed the same way, and every watch
  # completed unmeasured while its record still looked like a normal watch.
  cluster=$(cw_cluster_probe || true)
  [ -n "$cluster" ] || cw_prime_pod_facts "$id"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    metric=$(cw_key_metric "$key")
    target=$(cw_key_target "$key")
    value=''
    reason=''
    reason=$(cw_sample_blocker "$id" "$metric" "$target" "$cluster") || true
    baseline=$(cw_baseline_value "$id" "$key" 2>/dev/null || true)
    previous=$(cw_previous_value "$id" "$key" 2>/dev/null || true)
    scored=1
    if [ -z "$reason" ]; then
      rc=0
      value=$(cw_metric_read "$id" "$metric" "$target" sample "$baseline_epoch" 2>"$err") || rc=$?
      if [ "$rc" -ne 0 ] || [ -z "$value" ]; then
        # A reader that explains itself on stdout ("no run since the merge")
        # hands that sentence back as the reason; one that fails silently is
        # reported by its stderr or its exit status.
        if [ -n "$value" ] && ! printf '%s' "$value" | grep -qE '^-?[0-9]+([.][0-9]+)?$'; then
          reason=$value
        else
          reason=$(tail -1 "$err" 2>/dev/null | cut -c1-200)
          [ -n "$reason" ] || reason="read exited $rc with no value"
        fi
        value=''
      elif ! printf '%s' "$value" | grep -qE '^-?[0-9]+([.][0-9]+)?$'; then
        reason=$value
        value=''
      fi
    fi
    [ -n "$value" ] || cw_record_reason "$id" "$key" "${reason:-unmeasured}"
    [ -n "$value" ] || scored=0
    if [ "$scored" -eq 1 ] && cw_metric_relative "$metric" && [ -z "$baseline" ]; then
      scored=0
      cw_record_reason "$id" "$key" "baseline could not be read, so the relative bar was not scored"
    fi
    regressed=0
    if [ "$scored" -eq 1 ] && cw_metric_regressed "$metric" "$value" "$baseline" "$previous"; then
      regressed=1
      [ -n "$first" ] || first="$metric	$target	$value	$baseline"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$epoch" "$offset" "$key" "$value" "$baseline" "$regressed" "$scored" \
      >> "$(cw_samples_path "$id")"
    [ -z "$value" ] || cw_set_previous_value "$id" "$key" "$value"
  done < <(cw_metric_keys "$id")
  [ "$err" = /dev/null ] || rm -f -- "$err" 2>/dev/null || true
  cw_pool_memo_clear
  [ -n "$first" ] && printf '%s\n' "$first"
  return 0
}

# Why a metric cannot be read right now, as one stated reason, or nothing when
# the read may proceed. A Kubernetes target that has not seen its rollout is
# awaiting the deploy, and an unreachable cluster is named once instead of being
# retried per metric.
cw_sample_blocker() {  # <watch-id> <metric> <target> <cluster-probe-error>
  local id=$1 metric=$2 target=$3 cluster=$4 ns deploy landed since
  case "$metric" in
    sentry_new_issues)
      # Sentry errors are only the release's once its landing is proven: the
      # watched Deployments' rollout when the watch has any, otherwise its own
      # deploy workflow's run for this merge. A watch with neither has nothing
      # better to prove, so its Sentry read proceeds.
      #
      # Proving a rollout costs a pod read, and a spent sample budget buys none:
      # the pod-backed metrics state that budget themselves, and a landing the
      # sample could not read is unproven (as an unreadable fingerprint already
      # is), never a silent reason to skip a network read.
      if [ -s "$(cw_targets_path "$id")" ]; then
        if cw_within_budget && cw_all_k8s_awaiting "$id"; then
          printf 'awaiting the deploy: no watched Deployment has rolled out yet\n'
        fi
        return 0
      fi
      since=$(cw_meta_get "$id" t0 || true)
      cw_runs_awaiting_deploy "$id" "$since" || true
      return 0
      ;;
    deploy_run) return 0 ;;
  esac
  if [ -n "$cluster" ]; then
    printf 'cluster read failed: %s\n' "$cluster"
    return 0
  fi
  case "$target" in
    */*) ns=${target%%/*}; deploy=${target#*/} ;;
    *) return 0 ;;
  esac
  # A spent budget is stated as itself before the pod read this metric needs, and
  # stops that read only: the Sentry and deploy-workflow reads above go over the
  # network with their own bounds, so a budget cluster reads spent never costs
  # them the sample.
  cw_within_budget || { printf 'sample budget spent before this metric was read\n'; return 0; }
  landed=0
  cw_target_landed "$id" "$ns" "$deploy" || landed=$?
  case "$landed" in
    2) printf 'awaiting the deploy: the pods still run the image they ran at registration\n' ;;
    3) printf 'deploy landing unreadable: the target\047s pod fingerprint could not be read\n' ;;
  esac
  return 0
}

# --- verdict ------------------------------------------------------------------

cw_verdict_line() {  # <watch-id>
  local id=$1 file
  file=$(cw_verdict_path "$id")
  if [ -f "$file" ]; then
    cat "$file"
    return 0
  fi
  printf 'change-watch clean so far (%s)\n' "$(cw_progress_label "$id")"
}

cw_schedule_latest() {  # <watch-id>
  awk -F'\t' 'NR == 1 || $1 > max { max = $1 } END { if (max == "") max = 0; print max }' \
    "$(cw_schedule_path "$1")" 2>/dev/null || echo 0
}

cw_progress_label() {  # <watch-id>
  local id=$1 t0 now latest offset
  t0=$(cw_meta_get "$id" t0 || true)
  now=$(cw_now)
  latest=$(cw_schedule_latest "$id")
  [ -n "$t0" ] || { printf 'armed\n'; return 0; }
  offset=$(( now - t0 ))
  [ "$offset" -ge 0 ] || offset=0
  printf '+%dm of +%dm' "$((offset / 60))" "$((latest / 60))"
}

cw_record_regression() {  # <watch-id> <offset-seconds> <metric> <target> <value> <baseline>
  local id=$1 offset=$2 metric=$3 target=$4 value=$5 baseline=$6 tick line
  tick=$((offset / 60))
  line=$(printf 'regressed at +%dm on %s (%s vs baseline %s)' \
    "$tick" "$metric" "${value:-unmeasured}" "${baseline:-unmeasured}")
  printf '%s\n' "$line" | cw_write "$(cw_verdict_path "$id")"
  {
    printf 'metric=%s\n' "$metric"
    printf 'target=%s\n' "$target"
    printf 'value=%s\n' "$value"
    printf 'baseline=%s\n' "$baseline"
    printf 'offset=%s\n' "$offset"
    printf 'tick=%s\n' "$tick"
  } | cw_write "$(cw_watch_dir "$id")/regression"
  printf '%s\n' "$line"
}

# Create a marker exactly once; exit 0 only for the creating call.
cw_mark_once() {  # <path>
  local path=$1
  (umask 077; set -C; : > "$path") 2>/dev/null
}

cw_regression_field() {  # <watch-id> <key>
  grep "^$2=" "$(cw_watch_dir "$1")/regression" 2>/dev/null | cut -d= -f2- || true
}

cw_report_regression() {  # <watch-id>
  local id=$1 task url metric target value baseline tick line rc send_cmd
  cw_watch_exists "$id" || return 0
  [ -f "$(cw_watch_dir "$id")/regression" ] || return 0
  cw_mark_once "$(cw_watch_dir "$id")/reported" || return 0
  task=$(cw_meta_get "$id" task || true)
  url=$(cw_meta_get "$id" pr_url || true)
  metric=$(cw_regression_field "$id" metric)
  target=$(cw_regression_field "$id" target)
  value=$(cw_regression_field "$id" value)
  baseline=$(cw_regression_field "$id" baseline)
  tick=$(cw_regression_field "$id" tick)
  [ -n "$metric" ] || return 0

  line="check: change-watch $task $url $metric regressed"
  fm_wake_append check "change-watch-$id" "$line" 2>/dev/null \
    || notice "change-watch: could not queue the regression wake for $url"

  if [ -n "$task" ]; then
    send_cmd=${FM_CW_SEND_CMD:-$SCRIPT_DIR/fm-send.sh}
    if [ -x "$send_cmd" ] || command -v "$send_cmd" >/dev/null 2>&1; then
      rc=0
      FM_HOME="$FM_HOME" "$send_cmd" "$task" \
        "change-watch $url regressed at +${tick}m on $metric (target $target, measured ${value:-unmeasured}, baseline ${baseline:-unmeasured}); investigate before the next sample" \
        >/dev/null 2>&1 || rc=$?
      [ "$rc" -eq 0 ] || notice "change-watch: could not steer $task (rc=$rc); the wake carries the numbers"
    fi
  fi
}

cw_wiki_note() {  # <watch-id> <task> <url>
  local id=$1 task=$2 url=$3 cmd kinds targets body
  if [ "${FM_CW_NO_WIKI:-0}" = 1 ]; then
    notice "change-watch: wiki note skipped by FM_CW_NO_WIKI for $url"
    return 0
  fi
  cmd=wiki-retro
  if ! command -v "$cmd" >/dev/null 2>&1; then
    notice "change-watch: wiki note skipped (no $cmd on PATH) for $url"
    return 0
  fi
  # The body names the metric kinds and targets this watch actually measured: a
  # watch of a deploy workflow or a Sentry project alone must never claim a
  # Kubernetes metric it never read.
  kinds=$(cw_metric_keys "$id" | awk -F@ '{ print $1 }' | sort -u | paste -sd ',' - | sed 's/,/, /g')
  targets=$(cw_target_ids "$id" | sort -u | paste -sd ',' - | sed 's/,/, /g')
  body="Post-merge change watch for $url (task $task) completed clean at +12h: no regression on ${kinds:-any metric} against the pre-deploy baseline${targets:+ (watched: $targets)}."
  printf '%s\n' "$body" | "$cmd" "change-watch-clean-$id" "Post-merge change watch clean: $url" \
    >/dev/null 2>&1 || notice "change-watch: wiki note failed for $url"
}

cw_task_note() {  # <task> <url> <line>
  local task=$1 url=$2 line=$3
  if [ -n "$task" ] && [ -d "$STATE" ] \
    && { [ -f "$STATE/$task.meta" ] || [ -f "$STATE/$task.status" ]; }; then
    printf '%s\n' "$line" >> "$STATE/$task.status" 2>/dev/null \
      || notice "change-watch: could not append the completion note for $url"
  else
    notice "change-watch: completion note skipped for $url (task $task has no status record)"
  fi
}

cw_record_clean() {  # <watch-id>
  local id=$1 task url gaps unproven
  task=$(cw_meta_get "$id" task || true)
  url=$(cw_meta_get "$id" pr_url || true)
  printf 'clean\n' | cw_write "$(cw_verdict_path "$id")"
  cw_mark_once "$(cw_watch_dir "$id")/noted" || return 0
  gaps=$(cw_measured_gaps "$id")
  unproven=$(cw_unproven_landing "$id" | paste -sd ',' - | sed 's/,/, /g')
  if [ -n "$gaps" ] || [ -n "$unproven" ]; then
    cw_task_note "$task" "$url" \
      "note: change-watch clean for $url on every metric it could read${gaps:+; never measured: $gaps}${unproven:+; the rollout was never proven for: $unproven}"
    notice "change-watch: clean for $url on every metric it could read${gaps:+, but these metrics were never measured: $gaps}${unproven:+; the rollout could not be proven for: $unproven}"
    return 0
  fi
  cw_task_note "$task" "$url" "note: change-watch clean for $url"
  cw_wiki_note "$id" "$task" "$url"
}

cw_record_unmeasured() {  # <watch-id> <unread-targets>
  local id=$1 unread=$2 task url list unproven why
  task=$(cw_meta_get "$id" task || true)
  url=$(cw_meta_get "$id" pr_url || true)
  printf 'completed unmeasured\n' | cw_write "$(cw_verdict_path "$id")"
  cw_mark_once "$(cw_watch_dir "$id")/noted" || return 0
  list=$(printf '%s\n' "$unread" | paste -sd ',' - | sed 's/,/, /g')
  unproven=$(cw_unproven_landing "$id" | paste -sd ',' - | sed 's/,/, /g')
  # The reason the last sample recorded is what turns "unmeasured" into an
  # actionable gap instead of a mystery.
  why=$(awk -F'\t' '{ if ($2 != "") { print $2; exit } }' "$(cw_reasons_path "$id")" 2>/dev/null || true)
  cw_task_note "$task" "$url" \
    "note: change-watch completed unmeasured for $url (never measured: $list)${unproven:+; the rollout was never proven for: $unproven}${why:+; last reason: $why}"
  notice "change-watch: wiki note skipped for $url (completed unmeasured: $list)${unproven:+; the rollout could not be proven for: $unproven}${why:+; last reason: $why}"
}

# Targets that never had one scored reading across the whole schedule.
cw_unmeasured_targets() {  # <watch-id>
  local id=$1 samples want
  samples=$(cw_samples_path "$id")
  [ -f "$samples" ] || : > "$samples"
  want=$(mktemp "${TMPDIR:-/tmp}/fm-cw-want.XXXXXX" 2>/dev/null) || { printf 'no temp file\n'; return 0; }
  cw_target_ids "$id" | sort -u > "$want"
  awk -F'\t' '
    NR == FNR { want[$1] = 1; next }
    $7 == 1 { key = $3; sub(/^[^@]*@/, "", key); delete want[key] }
    END { for (t in want) print t }
  ' "$want" "$samples" | sort
  rm -f -- "$want" 2>/dev/null || true
}

# Every metric key no sample of this watch ever scored, across every target it
# was registered with: the honest statement of what a clean verdict did and did
# not cover, so a release watched only for restarts and memory says exactly that
# and a target whose own pool or pods were never read is named as the gap it is.
cw_measured_gaps() {  # <watch-id>
  local id=$1 samples keys
  samples=$(cw_samples_path "$id")
  keys=$(cw_metric_keys "$id" | sort -u)
  [ -n "$keys" ] || return 0
  [ -f "$samples" ] || samples=/dev/null
  printf '%s\n' "$keys" | awk -F'\t' -v samples="$samples" '
    BEGIN {
      while ((getline line < samples) > 0) {
        n = split(line, f, "\t")
        if (n >= 7 && f[7] == 1) measured[f[3]] = 1
      }
      close(samples)
    }
    !($1 in measured) { printf "%s%s", sep, $1; sep = ", " }
  '
}

# The schedule ended: clean only when every target was measured at least once.
cw_record_completion() {  # <watch-id>
  local id=$1 unread
  unread=$(cw_unmeasured_targets "$id")
  if [ -z "$unread" ] && [ -n "$(cw_metric_keys "$id")" ]; then
    cw_record_clean "$id"
  else
    [ -n "$unread" ] || unread='no target of this watch was ever registered'
    cw_record_unmeasured "$id" "$unread"
  fi
}

# A drive that stopped before the end of its schedule: the verdict names the
# point it reached, and one check wake carries it. Never clean.
cw_record_interrupted() {  # <watch-id> <epoch>
  local id=$1 at=$2 t0 latest offset tick task url line
  cw_watch_done "$id" && return 0
  t0=$(cw_meta_get "$id" t0 || true)
  latest=$(cw_schedule_latest "$id")
  offset=$(( at - ${t0:-$at} ))
  [ "$offset" -ge 0 ] || offset=0
  [ "$offset" -le "$latest" ] || offset=$latest
  tick=$((offset / 60))
  printf 'interrupted at +%dm\n' "$tick" | cw_write "$(cw_verdict_path "$id")"
  rm -f -- "$(cw_drive_pid_path "$id")" "$(cw_drive_identity_path "$id")" "$(cw_drive_alive_path "$id")"
  cw_mark_once "$(cw_watch_dir "$id")/interrupted-reported" || return 0
  task=$(cw_meta_get "$id" task || true)
  url=$(cw_meta_get "$id" pr_url || true)
  line="check: change-watch $task $url interrupted at +${tick}m"
  fm_wake_append check "change-watch-$id-interrupted" "$line" 2>/dev/null \
    || notice "change-watch: could not queue the interruption wake for $url"
}

# A drive whose process is gone without a verdict was killed outright; record
# the interruption at its last heartbeat. The pid counts as the drive only when
# the process behind it still carries the identity the drive recorded at start,
# so a pid reused after a reboot never reads as a live watch.
cw_reconcile_drive() {  # <watch-id>
  local id=$1 pidfile pid recorded at
  pidfile=$(cw_drive_pid_path "$id")
  [ -f "$pidfile" ] || return 0
  cw_watch_done "$id" && return 0
  pid=$(cat "$pidfile" 2>/dev/null || true)
  recorded=$(cat "$(cw_drive_identity_path "$id")" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) ;;
    *)
      if [ -n "$recorded" ] && kill -0 "$pid" 2>/dev/null \
        && [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "$recorded" ]; then
        return 0
      fi
      ;;
  esac
  at=$(cat "$(cw_drive_alive_path "$id")" 2>/dev/null || true)
  case "$at" in ''|*[!0-9]*) at=$(cw_now) ;; esac
  cw_record_interrupted "$id" "$at"
}

# --- schedule -----------------------------------------------------------------

cw_write_schedule() {  # <watch-id> <t0>
  local id=$1 t0=$2 out='' offset
  for offset in $SCHEDULE_OFFSETS; do
    out="$out$offset	$((t0 + offset))
"
  done
  printf '%s' "$out" | cw_write "$(cw_schedule_path "$id")"
}

cw_next_due_offset() {  # <watch-id> <now>
  local id=$1 now=$2 offset epoch
  while IFS=$'\t' read -r offset epoch; do
    [ -n "$offset" ] || continue
    grep -qx "$offset" "$(cw_sampled_path "$id")" 2>/dev/null && continue
    [ "$now" -ge "$epoch" ] || continue
    printf '%s\n' "$offset"
    return 0
  done < "$(cw_schedule_path "$id")"
  return 1
}

cw_remaining_count() {  # <watch-id>
  local id=$1 offset epoch n=0
  while IFS=$'\t' read -r offset epoch; do
    [ -n "$offset" ] || continue
    grep -qx "$offset" "$(cw_sampled_path "$id")" 2>/dev/null && continue
    n=$((n + 1))
  done < "$(cw_schedule_path "$id")"
  printf '%s\n' "$n"
}

cw_mark_sampled() {  # <watch-id> <offset>
  printf '%s\n' "$2" >> "$(cw_sampled_path "$1")" 2>/dev/null || true
}

cw_watch_done() { [ -f "$(cw_verdict_path "$1")" ]; }

cw_arm() {  # <watch-id> <when-name> <url>
  local id=$1 when_name=$2 url=$3 arm_cmd
  arm_cmd=${FM_CW_ARM_CMD:-$SCRIPT_DIR/fm-procevent-when.sh}
  if [ -x "$arm_cmd" ] || command -v "$arm_cmd" >/dev/null 2>&1; then
    "$arm_cmd" arm "$when_name" \
      --interval 60 --stable 1 --deadline 46800 \
      --condition-timeout 60 --action-timeout 46800 \
      --condition "$SCRIPT_DIR/fm-change-watch.sh" due "$id" \
      --action "$SCRIPT_DIR/fm-change-watch.sh" drive "$id" \
      >/dev/null 2>&1 \
      || notice "change-watch: could not arm the scheduled watch for $url (the watch record is retained)"
  else
    notice "change-watch: arming command unavailable; watch record retained for $url"
  fi
}

# Re-arm an interrupted watch for the samples it has not taken.
cw_rearm() {  # <watch-id> <url>
  local id=$1 url=$2 remaining old attempt when_name arm_cmd
  remaining=$(cw_remaining_count "$id")
  if [ "$remaining" -eq 0 ]; then
    rm -f -- "$(cw_verdict_path "$id")"
    cw_record_completion "$id"
    printf 'change-watch: %s had no samples left; completed as %s\n' "$id" "$(cw_verdict_line "$id")"
    return 0
  fi
  old=$(cw_meta_get "$id" when_name || true)
  attempt=$(cw_meta_get "$id" arm_attempt || true)
  case "$attempt" in ''|*[!0-9]*) attempt=1 ;; esac
  attempt=$((attempt + 1))
  rm -f -- "$(cw_verdict_path "$id")" "$(cw_watch_dir "$id")/interrupted-reported"
  arm_cmd=${FM_CW_ARM_CMD:-$SCRIPT_DIR/fm-procevent-when.sh}
  if [ -n "$old" ] && { [ -x "$arm_cmd" ] || command -v "$arm_cmd" >/dev/null 2>&1; }; then
    "$arm_cmd" retire "$old" >/dev/null 2>&1 || true
  fi
  when_name="cw-$(cw_hash "$id/$attempt" | cut -c1-40)"
  {
    printf 'when_name=%s\n' "$when_name"
    printf 'arm_attempt=%s\n' "$attempt"
  } >> "$(cw_meta_path "$id")"
  cw_arm "$id" "$when_name" "$url"
  printf 'change-watch: re-armed %s for %s (%s sample(s) remaining)\n' "$id" "$url" "$remaining"
}

# --- commands -----------------------------------------------------------------

cmd_register() {
  local task=$1 url=$2 provider owner repo number repo_name id derived targets sentries runs
  local notes unread inventory_unread now t0 landed_unread when_name sentry_unreadable
  fm_pr_task_id_valid "$task" || die "invalid task id: $task"
  fm_pr_url_parse "$url" || die "invalid pr url: $url"
  provider=$FM_PR_PROVIDER
  owner=${FM_PR_OWNER:-}
  repo=${FM_PR_REPO:-}
  number=$FM_PR_NUMBER
  repo_name=${repo:-}
  [ -n "$repo_name" ] || repo_name=$(basename "${FM_PR_PATH:-$url}")

  id=$(cw_watch_id "$task" "$number")
  if cw_watch_exists "$id"; then
    cw_reconcile_drive "$id"
    case "$(cat "$(cw_verdict_path "$id")" 2>/dev/null || true)" in
      interrupted*) cw_rearm "$id" "$url"; return 0 ;;
    esac
    printf 'change-watch: %s already registered for %s\n' "$id" "$url"
    return 0
  fi

  cw_kubeconfig_init
  derived=$(cw_derive_targets "$url" "$provider" "$owner" "$repo" "$number" "$repo_name" 2>/dev/null || true)
  targets=$(printf '%s\n' "$derived" | awk -F'\t' '$1 == "target" && $2 != "" && $3 != "" { print $2 "\t" $3 }' | sort -u)
  sentries=$(printf '%s\n' "$derived" | awk -F'\t' '$1 == "sentry" && $2 != "" { print $2 }' | sort -u)
  runs=$(printf '%s\n' "$derived" | awk -F'\t' '$1 == "run" && $2 != "" && $3 != "" { print $2 "\t" $3 }' | sort -u)
  notes=$(printf '%s\n' "$derived" | awk -F'\t' '$1 == "note" { print $2 }' | sort -u | paste -sd ';' - | sed 's/;/; /g')
  # A Sentry project this home cannot authenticate is not a target: keeping it
  # would arm a watch whose every sample reads nothing, and whose end-of-schedule
  # verdict would then read as a clean release.
  sentry_unreadable=''
  if [ -n "$sentries" ] && [ -z "${FM_CW_SENTRY_DIR:-}" ] && ! cw_sentry_vault_ready; then
    notes="$notes${notes:+; }sentry unmeasured: no token in $SENTRY_VAULT"
    sentries=''
    sentry_unreadable=1
  fi
  if [ -z "$targets" ] && [ -z "$sentries" ] && [ -z "$runs" ]; then
    unread=$(printf '%s\n' "$derived" | grep -c '^note	manifest unread: ' || true)
    inventory_unread=$(printf '%s\n' "$derived" | grep -c '^note	image inventory unread: ' || true)
    if ! cw_forge_files "$url" "$provider" "$owner" "$repo" "$number" >/dev/null 2>&1; then
      printf 'change-watch: cannot read the merged file list for %s; nothing registered\n' "$url"
    elif [ "$unread" -gt 0 ]; then
      printf 'change-watch: could not read %s manifest(s) for %s; nothing registered\n' "$unread" "$url"
    elif [ "$inventory_unread" -gt 0 ]; then
      printf 'change-watch: could not read the image inventory for %s%s; nothing registered\n' "$url" "${notes:+ ($notes)}"
    elif [ -n "$sentry_unreadable" ]; then
      printf 'change-watch: nothing measurable for %s (%s); nothing registered\n' "$url" "$notes"
    else
      printf 'change-watch: no deployable service touched by %s%s; nothing registered\n' "$url" "${notes:+ ($notes)}"
    fi
    return 0
  fi

  now=$(cw_now)
  t0=$(cw_forge_merge_epoch "$url" "$provider" 2>/dev/null || true)
  case "$t0" in
    ''|*[!0-9]*) t0=$now ;;
  esac
  [ "$t0" -le "$now" ] || t0=$now

  mkdir -p "$(cw_watch_dir "$id")" || die "cannot create watch directory"
  chmod 0700 "$(cw_watch_dir "$id")" 2>/dev/null || true
  [ -z "$targets" ] || printf '%s\n' "$targets" | cw_write "$(cw_targets_path "$id")"
  [ -z "$sentries" ] || printf '%s\n' "$sentries" | cw_write "$(cw_sentry_path "$id")"
  [ -z "$runs" ] || printf '%s\n' "$runs" | cw_write "$(cw_runs_path "$id")"
  {
    printf 'version=fm-change-watch-v1\n'
    printf 'task=%s\n' "$task"
    printf 'pr_url=%s\n' "$url"
    printf 'watch_id=%s\n' "$id"
    printf 'provider=%s\n' "$provider"
    printf 'owner=%s\n' "$owner"
    printf 'repo=%s\n' "$repo"
    printf 'number=%s\n' "$number"
    printf 't0=%s\n' "$t0"
    printf 'created=%s\n' "$now"
  } | cw_write "$(cw_meta_path "$id")"
  cw_write_schedule "$id" "$t0"
  cw_capture_baseline "$id" "$t0"
  # The rollout evidence: the images these Deployments run before the release
  # reaches them. A sample scores a target only after they change.
  cw_budget_start
  cw_record_images "$id"
  landed_unread=$(awk -F'\t' '$2 == "" { print $1 }' "$(cw_landed_path "$id")" 2>/dev/null | paste -sd ',' - | sed 's/,/, /g')
  [ -z "$landed_unread" ] \
    || notes="$notes${notes:+; }images unread, so the deploy landing cannot be proven for: $landed_unread"

  when_name="cw-$(cw_hash "$id" | cut -c1-40)"
  {
    printf 'when_name=%s\n' "$when_name"
    printf 'arm_attempt=1\n'
  } >> "$(cw_meta_path "$id")"
  cw_arm "$id" "$when_name" "$url"

  printf 'change-watch: registered %s for %s (%s target(s)%s)\n' \
    "$id" "$url" "$(( $(cw_target_ids "$id" | grep -c '' || true) ))" "${notes:+; $notes}"
}

cmd_due() {
  local id=$1 now
  cw_watch_exists "$id" || return 1
  cw_watch_done "$id" && return 1
  now=$(cw_now)
  cw_next_due_offset "$id" "$now" >/dev/null
}

cmd_sample() {
  local id=$1 offset=${2:-} now t0 first metric target value baseline
  cw_watch_exists "$id" || die "unknown watch: $id"
  now=$(cw_now)
  t0=$(cw_meta_get "$id" t0 || true)
  [ -n "$t0" ] || die "watch $id has no rollout epoch"
  if [ -z "$offset" ]; then
    offset=$(cw_next_due_offset "$id" "$now" || true)
    if [ -z "$offset" ]; then
      offset=$(awk -F'\t' -v now="$now" '$2 <= now { o=$1 } END { if (o != "") print o }' \
        "$(cw_schedule_path "$id")" 2>/dev/null || true)
    fi
    [ -n "$offset" ] || offset=$(awk -F'\t' 'NR == 1 { print $1 }' "$(cw_schedule_path "$id")")
  fi
  first=$(cw_take_sample "$id" "$offset" "$now" "$t0" || true)
  cw_mark_sampled "$id" "$offset"
  [ -z "$first" ] && return 0
  metric=$(printf '%s' "$first" | cut -f1)
  target=$(printf '%s' "$first" | cut -f2)
  value=$(printf '%s' "$first" | cut -f3)
  baseline=$(printf '%s' "$first" | cut -f4)
  cw_record_regression "$id" "$offset" "$metric" "$target" "$value" "$baseline"
  cw_report_regression "$id"
}

CW_DRIVE_ID=''
CW_DRIVE_PIDFILE=''
CW_DRIVE_IDENTITY_FILE=''
CW_SLEEPER=''

cw_drive_interrupted() {
  trap '' TERM INT HUP
  [ -z "$CW_SLEEPER" ] || kill "$CW_SLEEPER" 2>/dev/null || true
  cw_record_interrupted "$CW_DRIVE_ID" "$(cw_now)"
  exit 143
}

cmd_drive() {
  local id=$1 sleep_cmd offset epoch now remaining identity
  cw_watch_exists "$id" || die "unknown watch: $id"
  sleep_cmd=${FM_CW_SLEEP_CMD:-sleep}
  cw_meta_get "$id" t0 >/dev/null || die "watch $id has no rollout epoch"
  identity=$(fm_pid_identity "$$") || die "cannot read the drive's own process identity"

  CW_DRIVE_ID=$id
  CW_DRIVE_PIDFILE=$(cw_drive_pid_path "$id")
  CW_DRIVE_IDENTITY_FILE=$(cw_drive_identity_path "$id")
  printf '%s\n' "$$" > "$CW_DRIVE_PIDFILE" || die "cannot record the drive pid"
  printf '%s\n' "$identity" > "$CW_DRIVE_IDENTITY_FILE" || die "cannot record the drive identity"
  trap 'cw_pool_memo_clear; rm -f -- "$CW_DRIVE_PIDFILE" "$CW_DRIVE_IDENTITY_FILE"' EXIT
  trap cw_drive_interrupted TERM INT HUP

  while IFS=$'\t' read -r offset epoch; do
    [ -n "$offset" ] || continue
    grep -qx "$offset" "$(cw_sampled_path "$id")" 2>/dev/null && continue
    while :; do
      now=$(cw_now)
      printf '%s\n' "$now" > "$(cw_drive_alive_path "$id")" 2>/dev/null || true
      [ "$now" -ge "$epoch" ] && break
      remaining=$(( epoch - now ))
      [ "$remaining" -gt 60 ] && remaining=60
      "$sleep_cmd" "$remaining" 2>/dev/null &
      CW_SLEEPER=$!
      wait "$CW_SLEEPER" 2>/dev/null || true
      CW_SLEEPER=''
    done
    cmd_sample "$id" "$offset" >/dev/null || true
    if cw_watch_done "$id"; then
      cw_report_regression "$id"
      return 0
    fi
  done < "$(cw_schedule_path "$id")"

  cw_record_completion "$id"
  return 0
}

cmd_verdict() {
  local id=$1 line
  cw_watch_exists "$id" || die "unknown watch: $id"
  cw_reconcile_drive "$id"
  if [ -f "$(cw_verdict_path "$id")" ]; then
    line=$(cat "$(cw_verdict_path "$id")")
    printf 'change-watch %s\n' "$line"
    return 0
  fi
  cw_verdict_line "$id"
}

# One status line per watch, with the metrics no sample ever scored and any
# target whose rollout was never proven appended when there are any: a watch is
# never summarized as clean without saying what it did not measure.
cw_status_line() {  # <watch-id>
  local id=$1 gaps unproven line
  gaps=$(cw_measured_gaps "$id")
  unproven=$(cw_unproven_landing "$id" | paste -sd ',' - | sed 's/,/, /g')
  line=$(cw_verdict_line "$id")
  [ -z "$gaps" ] || line="$line	unmeasured: $gaps"
  [ -z "$unproven" ] || line="$line	rollout never proven: $unproven"
  printf '%s\t%s\n' "$id" "$line"
}

cmd_status() {
  local id=${1:-} meta count=0
  [ -d "$WATCH_ROOT" ] || { printf 'change-watch: no watches registered\n'; return 0; }
  if [ -n "$id" ]; then
    cw_watch_exists "$id" || die "unknown watch: $id"
    cw_reconcile_drive "$id"
    cw_status_line "$id"
    return 0
  fi
  for meta in "$WATCH_ROOT"/*/watch.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$(dirname "$meta")")
    cw_reconcile_drive "$id"
    cw_status_line "$id"
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] || printf 'change-watch: no watches registered\n'
}

# One pool console read for the doctor: a stated ok or FAIL line, never silence.
cw_doctor_pool() {  # <label> <host> <port> <database>
  local label=$1 host=$2 port=$3 db=$4 where err out rc reason rows
  where="${label:+$label }pool read $POOLER_SSH_USER@$host:$port"
  err=$(mktemp "${TMPDIR:-/tmp}/fm-cw-doctor.XXXXXX" 2>/dev/null) || err=/dev/null
  cw_budget_start
  out=$(cw_pool_console "$host" "$port" 2>"$err")
  rc=$?
  reason=$(tail -1 "$err" 2>/dev/null || true)
  [ "$err" = /dev/null ] || rm -f -- "$err"
  if [ "$rc" -eq 124 ]; then
    printf 'doctor: FAIL %s: timed out after %ss\n' "$where" "$SAMPLE_DEADLINE_SECONDS"
    return 1
  fi
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    printf 'doctor: FAIL %s: %s\n' "$where" "${reason:-exit $rc with no rows}"
    return 1
  fi
  rows=$(printf '%s\n' "$out" | awk -F'|' -v db="$db" '
    NR == 1 { for (i = 1; i <= NF; i++) if ($i == "database") d = i; next }
    NF > 1 && (db == "" || (d && $d == db)) { n++ }
    END { print n + 0 }
  ')
  if [ "$rows" -eq 0 ]; then
    printf 'doctor: FAIL %s: no pool row%s\n' "$where" "${db:+ for database $db}"
    return 1
  fi
  printf 'doctor: ok %s returned %s pool row(s)%s\n' "$where" "$rows" "${db:+ for database $db}"
}

# The doctor's two halves: the cluster read path itself, then every target's own
# live read. Each line is a stated ok or FAIL, so an unmeasured watch never has to
# be diagnosed by re-reading its samples by hand.
cw_doctor_open_target() {  # <ns> <deploy>
  local ns=$1 deploy=$2 target="$1/$2" images
  if images=$(cw_live_images "$ns" "$deploy" 2>/dev/null) && [ -n "$images" ]; then
    printf 'doctor: ok %s pods read, images %s\n' "$target" "$images"
    return 0
  fi
  printf 'doctor: FAIL %s pods unreadable through %s\n' "$target" "${CW_KUBECONFIG:-the ambient kubectl default}"
  return 1
}

cw_doctor_reasons() {  # <watch-id>
  local id=$1 lines
  lines=$(awk -F'\t' '$2 != "" { printf "%s: %s\n", $1, $2 }' "$(cw_reasons_path "$id")" 2>/dev/null | head -20 || true)
  [ -n "$lines" ] || return 0
  printf '%s\n' "$lines" | while IFS= read -r line; do
    case "$line" in
      # A wait the watch expects to end by itself is reported as a wait, so a
      # doctor run between the merge and the rollout does not read as breakage.
      *"awaiting the deploy"*|*"no "*"run since the merge"*|*"no run created at or after the merge"*|*"run in flight"*)
        printf 'doctor: awaiting %s\n' "$line" ;;
      *) printf 'doctor: last read FAIL %s\n' "$line" ;;
    esac
  done
}

cmd_doctor() {
  local id=${1:-} ns deploy target spec failed=0 project run_repo workflow value last
  cw_kubeconfig_init
  printf 'doctor: kubeconfig %s (%s)\n' "${CW_KUBECONFIG:-ambient kubectl default}" "$CW_KUBECONFIG_SOURCE"
  if probe=$(cw_cluster_probe); then
    printf 'doctor: ok cluster answers\n'
  else
    printf 'doctor: FAIL cluster unreachable: %s\n' "$probe"
    failed=1
  fi
  if [ -z "$id" ]; then
    cw_doctor_pool '' "$POOLER_DEFAULT_HOST" "$POOLER_DEFAULT_PORT" '' || failed=1
    return "$failed"
  fi
  cw_watch_exists "$id" || die "unknown watch: $id"
  cw_budget_start
  if [ -f "$(cw_targets_path "$id")" ]; then
    while IFS=$'\t' read -r ns deploy; do
      [ -n "${ns:-}" ] || continue
      target="$ns/$deploy"
      cw_doctor_open_target "$ns" "$deploy" || failed=1
      if spec=$(cw_pool_spec "$id" "$target"); then
        cw_doctor_pool "$target" "$(printf '%s' "$spec" | cut -f1)" \
          "$(printf '%s' "$spec" | cut -f2)" "$(printf '%s' "$spec" | cut -f3)" || failed=1
      else
        printf 'doctor: FAIL %s pool unresolved; its pool metric is unmeasured for the whole watch\n' "$target"
        failed=1
      fi
    done < "$(cw_targets_path "$id")"
  fi
  if [ -f "$(cw_sentry_path "$id")" ]; then
    while IFS= read -r project; do
      [ -n "$project" ] || continue
      if value=$(cw_live_sentry_new_issues "$project" "$(($(cw_now) - 86400))" 2>&1) \
        && printf '%s' "$value" | grep -qE '^[0-9]+$'; then
        printf 'doctor: ok sentry/%s read %s new error issue(s) in the last 24h\n' "$project" "$value"
      else
        printf 'doctor: FAIL sentry/%s unreadable: %s\n' "$project" "$(printf '%s' "$value" | tail -1)"
        failed=1
      fi
    done < "$(cw_sentry_path "$id")"
  fi
  if [ -f "$(cw_runs_path "$id")" ]; then
    while IFS=$'\t' read -r run_repo workflow; do
      [ -n "${run_repo:-}" ] || continue
      cw_budget_start
      if value=$(cw_live_deploy_run "$run_repo" "$workflow" "$(cw_meta_get "$id" t0 || true)" 2>&1) \
        && printf '%s' "$value" | grep -qE '^[01]$'; then
        printf 'doctor: ok run/%s#%s read %s\n' "$run_repo" "$workflow" "$value"
      else
        last=$(printf '%s' "$value" | tail -1)
        case "$last" in
          "no "*run*|*"in flight"*)
            printf 'doctor: awaiting run/%s#%s: %s\n' "$run_repo" "$workflow" "$last" ;;
          *)
            printf 'doctor: FAIL run/%s#%s unreadable: %s\n' "$run_repo" "$workflow" "$last"
            failed=1 ;;
        esac
      fi
    done < "$(cw_runs_path "$id")"
  fi
  cw_doctor_reasons "$id"
  return "$failed"
}

# --- entry --------------------------------------------------------------------

# Every command that reads the cluster resolves the kubeconfig first, so a
# by-hand reproduction and the armed watch read the same cluster.
cw_kubeconfig_init
trap cw_pool_memo_clear EXIT

case "${1:-}" in
  register) [ "$#" -eq 3 ] || usage; shift; cmd_register "$@" ;;
  due) [ "$#" -eq 2 ] || usage; shift; cmd_due "$@" ;;
  drive) [ "$#" -eq 2 ] || usage; shift; cmd_drive "$@" ;;
  sample) if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then usage; fi; shift; cmd_sample "$@" ;;
  verdict) [ "$#" -eq 2 ] || usage; shift; cmd_verdict "$@" ;;
  status) [ "$#" -le 2 ] || usage; shift; cmd_status "$@" ;;
  doctor) [ "$#" -le 2 ] || usage; shift; cmd_doctor "$@" ;;
  ""|-h|--help|help) usage ;;
  *) usage ;;
esac
