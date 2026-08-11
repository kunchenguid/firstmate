#!/usr/bin/env bash
# fm-fleet-lib.sh — FirstMate federated multi-operator KB library.
#
# Cross-uid-safe coordination through a SHARED group-writable data dir only.
# Operators never write each other's private homes; they share this KB and use
# flock advisory locks on the backlog for atomic, no-overlap claims.
# The KB is data only: nothing in it is executed or sourced, and it must never
# hold a git repository the fleet runs git against, because git executes hooks,
# fsmonitor, and filter commands from repo-local config, which in a
# group-writable dir is another operator's code. events.log is the audit
# trail; scripts/fleet-root-prereq.sh's header owns the required modes.
#
# KB layout ($dir):
#   operators.md  md table: | operator | scope | home | accounts | status | seen | quota |
#   projects.md   md table: | project | owner | path |
#   backlog.md    sections ## Queued / ## Claimed / ## In-flight / ## Done
#                 item line: - [id:<ID>] scope:<S> | <DESC> | [claimed-by:<op>@<ISO>] status:<st>
#   events.log    append-only TSV: <ISO8601>\t<operator>\t<event>\t<id>\t<detail>
#   locks/        flock targets (backlog.lock)
#
# Every mutating function takes the backlog lock and asserts the target is a
# shared/own dir (never a foreign private home).

# The quota/pace SURFACE layer is a separate leaf library (zero KB dependencies).
# fm_fleet_register/fm_fleet_heartbeat below call fm_fleet_quota_now from it.
# Resolved from THIS file's own directory: every consumer still sources only
# bin/fm-fleet-lib.sh, so no caller's sourcing contract changes.
_FM_FLEET_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-home-boundary-lib.sh
. "$_FM_FLEET_LIB_DIR/fm-home-boundary-lib.sh"
# shellcheck source=bin/fm-fleet-quota-lib.sh
. "$_FM_FLEET_LIB_DIR/fm-fleet-quota-lib.sh"
unset _FM_FLEET_LIB_DIR

fm_fleet_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ISO8601(Z) -> epoch seconds, as awk source shared by every awk program here that
# has to age a timestamp (reap's staleness test, route's heartbeat freshness).
#
# BSD `date` has no `-d` for parsing — there it is the DST flag — so the GNU form
# ALONE yields nothing on a non-GNU host and every stamp silently reads as epoch 0:
# route would treat a crashed operator as fresh forever, and reap would requeue
# every claim. Probe order matches bin/fm-fleet-snapshot.sh: BSD `-j -f` first,
# GNU `-d` second.
#
# The shape check is also the injection guard: the stamp is interpolated into a
# shell command, and operators.md/backlog.md are group-writable. Anything that is
# not exactly <YYYY-MM-DDThh:mm:ssZ> returns -1 (unknown), and callers must treat
# a non-positive result as "cannot age this" -> leave the row alone.
_FM_FLEET_AWK_EPOCH='
function epoch(iso,   cmd, out) {
  if (iso !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/) return -1
  cmd = "date -u -j -f \"%Y-%m-%dT%H:%M:%SZ\" \"" iso "\" +%s 2>/dev/null || date -u -d \"" iso "\" +%s 2>/dev/null"
  out = ""
  cmd | getline out
  close(cmd)
  if (out == "") return -1
  return out + 0
}
'

# Built-in last-resort fleet dir. Only reached when neither FM_FLEET_DIR nor
# $FM_HOME/config/fleet-dir is set. It is a *convention*, not a guarantee: on a
# shared host it may already belong to another team, so fm_fleet_assert_initialized
# tells the operator exactly which dir was chosen and how it was chosen.
FM_FLEET_DEFAULT_DIR=${FM_FLEET_DEFAULT_DIR:-/opt/agents/fleet}

fm_fleet_dir() {
  local d="${FM_FLEET_DIR:-}"
  if [ -z "$d" ] && [ -n "${FM_HOME:-}" ] && [ -f "$FM_HOME/config/fleet-dir" ]; then
    d=$(head -n1 "$FM_HOME/config/fleet-dir")
  fi
  [ -n "$d" ] || d=$FM_FLEET_DEFAULT_DIR
  printf '%s\n' "$d"
}

# How the dir was chosen: env|config|default. Deliberately a FUNCTION, not a global
# set inside fm_fleet_dir: callers do `DIR=$(fm_fleet_dir)`, and a variable assigned
# inside command substitution dies with the subshell — a global here would silently
# read as empty and any guard keyed on it would never fire.
fm_fleet_dir_source() {
  if [ -n "${FM_FLEET_DIR:-}" ]; then printf 'env\n'
  elif [ -n "${FM_HOME:-}" ] && [ -f "$FM_HOME/config/fleet-dir" ]; then printf 'config\n'
  else printf 'default\n'; fi
}

# Guard for every verb that READS an existing fleet. Without this, an uninitialized
# or wrong dir surfaces as `awk: fatal: cannot open .../operators.md` with exit 0 —
# a raw internal error that also *looks* like success to a caller. Fail loudly with
# the dir, how it was chosen, and the one command that fixes it.
fm_fleet_assert_initialized() { # dir
  local dir=$1 how; how=$(fm_fleet_dir_source)
  if [ -d "$dir" ] && [ -f "$dir/operators.md" ]; then return 0; fi

  {
    printf 'fm-fleet: no initialized fleet at %s\n' "$dir"
    case "$how" in
      env)     printf '  (chosen by FM_FLEET_DIR)\n' ;;
      config)  printf '  (chosen by %s/config/fleet-dir)\n' "${FM_HOME:-\$FM_HOME}" ;;
      default) printf '  (nothing configured, so the built-in default %s was used)\n' "$FM_FLEET_DEFAULT_DIR" ;;
    esac
    if [ ! -d "$dir" ]; then
      printf '  the directory does not exist.\n'
    else
      printf '  the directory exists but has no operators.md, so it is not a fleet.\n'
    fi
    printf '\nPick one:\n'
    printf '  solo / trying it out   FM_FLEET_DIR=~/.firstmate-fleet bin/fm-fleet.sh init\n'
    printf '  shared, multi-operator sudo bash scripts/fleet-root-prereq.sh   # then: bin/fm-fleet.sh init\n'
    printf '  already have one       export FM_FLEET_DIR=/path/to/fleet   (or write it to %s/config/fleet-dir)\n' "${FM_HOME:-\$FM_HOME}"
    printf '\nSee docs/fleet-quickstart.md.\n'
  } >&2
  return 1
}

# Refuse to silently attach to a fleet the operator never chose.
#
# The built-in default is a shared, conventional path. On a multi-tenant host it may
# already be a DIFFERENT team's fleet, and those dirs are group-writable/world-readable
# by design — so a bare clone that configured nothing could read another team's
# operator table and event log without ever asking. Membership is the opt-in signal:
# if you are already an operator in that fleet it is yours, otherwise say so
# explicitly. Only applies when the dir came from the built-in default; an operator
# who set FM_FLEET_DIR or config/fleet-dir has already chosen.
fm_fleet_assert_owned() { # dir
  local dir=$1 me
  [ "$(fm_fleet_dir_source)" = default ] || return 0
  [ -z "${FM_FLEET_ACCEPT_DEFAULT:-}" ] || return 0
  me=$(id -un)
  fm_fleet_operator_exists "$dir" "$me" && return 0

  {
    printf 'fm-fleet: %s is an existing fleet, but you are not one of its operators\n' "$dir"
    printf '  and you have not chosen this fleet — it is only the built-in default.\n\n'
    printf '  On a shared host that path may belong to another team. Refusing to read it.\n\n'
    printf 'If it IS yours:\n'
    printf '  bin/fm-fleet-join.sh %s <scopes-csv>     # become an operator\n' "$me"
    printf '  export FM_FLEET_ACCEPT_DEFAULT=1          # or just acknowledge the default\n\n'
    printf 'If it is NOT yours, choose your own:\n'
    printf '  FM_FLEET_DIR=~/.firstmate-fleet bin/fm-fleet.sh init\n\n'
    printf 'See docs/fleet-quickstart.md.\n'
  } >&2
  return 1
}

# The one guard every entry point that CONSUMES an existing fleet must pass:
# initialized AND chosen/owned. fm-fleet.sh, fm-fleet-wait.sh, and any future
# reader call this right after resolving the dir, so no entry point can reach a
# fleet the operator never set up or never opted into.
fm_fleet_assert_usable() { # dir
  fm_fleet_assert_initialized "$1" && fm_fleet_assert_owned "$1"
}

# Refuse any fleet dir that resolves into ANOTHER operator's home. Own home (dev
# test dir) and /opt/... shared dirs are allowed.
fm_fleet_assert_shared() {
  local dir rp owner me; dir=$1
  rp=$(fm_home_boundary_resolve "$dir")
  me=$(id -un)
  owner=$(fm_home_boundary_private_owner "$rp" || true)
  if [ -n "$owner" ] && [ "$owner" != "$me" ]; then
    echo "fm-fleet: refusing to touch another operator's home: $rp" >&2
    return 1
  fi
  return 0
}

fm_fleet_event() { # dir operator event id detail
  local dir=$1 op=$2 ev=$3 id=$4 detail=${5:-}
  printf '%s\t%s\t%s\t%s\t%s\n' "$(fm_fleet_now)" "$op" "$ev" "$id" "$detail" >> "$dir/events.log"
}

# Unpredictable same-dir temp file for an atomic table rewrite. mktemp creates
# it 0600 with O_EXCL, so a pre-placed symlink at a guessable name can never
# redirect the write into another operator's files; 0664 restores the shared
# mode of the table it replaces.
fm_fleet_tmpfile() { # dir table-basename
  local t
  t=$(mktemp "$1/$2.XXXXXX") || return 1
  chmod 0664 "$t" || { rm -f "$t"; return 1; }
  printf '%s\n' "$t"
}

fm_fleet_init() {
  local dir=$1
  fm_fleet_assert_shared "$dir" || return 1
  mkdir -p "$dir/locks"
  [ -f "$dir/operators.md" ] || printf '# Fleet operators\n\n| operator | scope | home | accounts | status | seen | quota |\n|---|---|---|---|---|---|---|\n' > "$dir/operators.md"
  [ -f "$dir/projects.md" ]  || printf '# Fleet projects\n\n| project | owner | path |\n|---|---|---|\n' > "$dir/projects.md"
  [ -f "$dir/backlog.md" ]   || printf '# Fleet backlog\n\n## Queued\n\n## Claimed\n\n## In-flight\n\n## Done\n' > "$dir/backlog.md"
  [ -f "$dir/events.log" ]   || : > "$dir/events.log"
}

# --- backlog mutation (all under flock) ---------------------------------------

# Open fd 9 on the backlog lock and block until held. Caller runs fm_fleet_unlock
# when done. Returns non-zero if the dir is unsafe.
fm_fleet_lock() { # dir
  local dir=$1
  fm_fleet_assert_shared "$dir" || return 1
  mkdir -p "$dir/locks"
  exec 9>"$dir/locks/backlog.lock" || return 1
  flock 9
}
fm_fleet_unlock() { flock -u 9 2>/dev/null || true; }

fm_fleet_operator_exists() { # dir operator
  awk -F'|' -v op="$2" '
    function trim(x){ gsub(/^ +| +$/,"",x); return x }
    trim($2)==op { found=1; exit }
    END { exit found ? 0 : 1 }
  ' "$1/operators.md" 2>/dev/null
}

fm_fleet_backlog_id_present() { # dir id
  awk -v id="$2" '
    function item_id(line){ if (match(line, /\[id:[^]]+\]/)) return substr(line, RSTART+4, RLENGTH-5); return "" }
    item_id($0)==id { found=1; exit }
    END { exit found ? 0 : 1 }
  ' "$1/backlog.md" 2>/dev/null
}

fm_fleet_backlog_id_status_present() { # dir id status
  awk -v id="$2" -v status="$3" '
    function item_id(line){ if (match(line, /\[id:[^]]+\]/)) return substr(line, RSTART+4, RLENGTH-5); return "" }
    item_id($0)==id && index($0, "status:" status) { found=1; exit }
    END { exit found ? 0 : 1 }
  ' "$1/backlog.md" 2>/dev/null
}

fm_fleet_count_operator_status() { # dir operator status
  awk -v op="$2" -v status="$3" '
    function claimed_by(line){ if (match(line, /claimed-by:[^ @]+@/)) return substr(line, RSTART+11, RLENGTH-12); return "" }
    claimed_by($0)==op && index($0, "status:" status) { count++ }
    END { print count + 0 }
  ' "$1/backlog.md" 2>/dev/null
}

# Append an item to ## Queued. The id is the KB's primary key — claim/handoff/reap
# all address items by it — so a duplicate is rejected under the lock we already
# hold. Without this, two items share an id and the single-match awk rules below
# silently drop one of them from backlog.md. Returns 1 if the id is already present.
fm_fleet_queue() { # dir id scope desc
  local dir=$1 id=$2 scope=$3 desc=$4 tmp
  fm_fleet_lock "$dir" || return 1
  if fm_fleet_backlog_id_present "$dir" "$id"; then
    echo "fm-fleet: id already in the backlog, refusing to queue a duplicate: $id" >&2
    fm_fleet_unlock
    return 1
  fi
  tmp=$(fm_fleet_tmpfile "$dir" backlog.md) || { fm_fleet_unlock; return 1; }
  awk -v line="- [id:$id] scope:$scope | $desc | status:queued" '
    { print }
    /^## Queued$/ { print ""; print line }
  ' "$dir/backlog.md" > "$tmp" && mv "$tmp" "$dir/backlog.md"
  fm_fleet_event "$dir" "-" queue "$id" "scope:$scope"
  fm_fleet_unlock
}

# Move a queued item to Claimed, stamp claimed-by + status:claimed. Returns 0 on
# win, 1 if the item is not currently queued (already claimed / absent).
fm_fleet_claim() { # dir id operator
  local dir=$1 id=$2 op=$3 ts rc=1 tmp
  ts=$(fm_fleet_now)
  fm_fleet_lock "$dir" || return 1
  if fm_fleet_backlog_id_status_present "$dir" "$id" queued; then
    tmp=$(fm_fleet_tmpfile "$dir" backlog.md) || { fm_fleet_unlock; return 1; }
    awk -v id="$id" -v op="$op" -v ts="$ts" '
      function item_id(line){ if (match(line, /\[id:[^]]+\]/)) return substr(line, RSTART+4, RLENGTH-5); return "" }
      held == "" && item_id($0)==id && $0 ~ /status:queued/ {
        sub(/status:queued/, "claimed-by:" op "@" ts " status:claimed"); held=$0; next
      }
      /^## Claimed$/ { print; if (held != "") { print ""; print held; held="" } ; next }
      { print }
    ' "$dir/backlog.md" > "$tmp" && mv "$tmp" "$dir/backlog.md"
    fm_fleet_event "$dir" "$op" claim "$id" ""
    rc=0
  fi
  fm_fleet_unlock
  return $rc
}

# Reassign an item to another operator (handoff): stamp claimed-by:<to>. An item
# that is already claimed or in-flight keeps its status and its section. A still-
# QUEUED item is moved into ## Claimed as status:claimed, exactly as fm_fleet_claim
# does, because a handoff IS an assignment: stamping the new owner while leaving
# status:queued reported success but stranded the work — fm-fleet-wait.sh wakes only
# on `claimed-by:<op>@<ts> status:claimed`, so the recipient never saw it, and the
# line stayed queued for anyone else to claim on top of the stamp.
# Returns 0 if the item exists.
fm_fleet_handoff() { # dir id to_operator
  local dir=$1 id=$2 to=$3 ts rc=1 tmp
  ts=$(fm_fleet_now)
  fm_fleet_lock "$dir" || return 1
  if fm_fleet_backlog_id_present "$dir" "$id"; then
    tmp=$(fm_fleet_tmpfile "$dir" backlog.md) || { fm_fleet_unlock; return 1; }
    awk -v id="$id" -v to="$to" -v ts="$ts" '
      function item_id(line){ if (match(line, /\[id:[^]]+\]/)) return substr(line, RSTART+4, RLENGTH-5); return "" }
      item_id($0)==id {
        if ($0 ~ /claimed-by:[^ ]+/) { sub(/claimed-by:[^ ]+/, "claimed-by:" to "@" ts); print; next }
        if (held == "" && $0 ~ /status:queued/) {
          sub(/status:queued/, "claimed-by:" to "@" ts " status:claimed"); held=$0; next
        }
        sub(/status:/, "claimed-by:" to "@" ts " status:"); print; next
      }
      /^## Claimed$/ { print; if (held != "") { print ""; print held; held="" } ; next }
      { print }
    ' "$dir/backlog.md" > "$tmp" && mv "$tmp" "$dir/backlog.md"
    fm_fleet_event "$dir" "$to" handoff "$id" "assigned"
    rc=0
  fi
  fm_fleet_unlock
  return $rc
}

# Cross-operator overflow on token drain (Task 18). When the operator holding
# <id> is drained (published quota below FM_FLEET_QUOTA_MIN, so route no longer
# considers them eligible), hand the item to an operator whose published quota
# shows headroom, reusing fm_fleet_route's priority (scope-owner >
# overflow-designated > any-with-headroom). A per-item handoff counter
# (handoffs:N, tracked in the item line) is capped at FM_FLEET_HANDOFF_CAP
# (default 3) so a fully-drained fleet cannot ping-pong an item forever; on
# exhaustion (cap reached or no operator has headroom) the item is left with an
# explicit status:drained ("fleet out of tokens") state rather than silently
# dropping it. Reuses the route/handoff stamping, not a new mechanism.
# Prints the chosen operator on a handoff, "drained" on exhaustion, "unchanged"
# if the holder still has headroom. Returns 0 on a decision, 1 if the item absent.
fm_fleet_drain_handoff() { # dir id
  local dir=$1 id=$2 holder scope to ts hc rc=1 handoffs tmp
  hc=${FM_FLEET_HANDOFF_CAP:-3}
  fm_fleet_lock "$dir" || return 1
  if fm_fleet_backlog_id_present "$dir" "$id"; then
    rc=0
    scope=$(awk -v id="$id" '
      function item_id(line){ if (match(line, /\[id:[^]]+\]/)) return substr(line, RSTART+4, RLENGTH-5); return "" }
      item_id($0)==id { if(match($0,/scope:[^ |]+/)){print substr($0,RSTART+6,RLENGTH-6);exit} print ""; exit }
    ' "$dir/backlog.md")
    holder=$(awk -v id="$id" '
      function item_id(line){ if (match(line, /\[id:[^]]+\]/)) return substr(line, RSTART+4, RLENGTH-5); return "" }
      item_id($0)==id { if(match($0,/claimed-by:[^ @]+/)){print substr($0,RSTART+11,RLENGTH-11);exit} print ""; exit }
    ' "$dir/backlog.md")
    handoffs=$(awk -v id="$id" '
      function item_id(line){ if (match(line, /\[id:[^]]+\]/)) return substr(line, RSTART+4, RLENGTH-5); return "" }
      item_id($0)==id { if(match($0,/handoffs:[0-9]+/)){print substr($0,RSTART+9,RLENGTH-9);exit} print "0"; exit }
    ' "$dir/backlog.md")
    handoffs=${handoffs:-0}
    to=$(fm_fleet_route "$dir" "$scope")
    ts=$(fm_fleet_now)
    if [ -n "$holder" ] && [ "$to" = "$holder" ]; then
      # The holder still has headroom (route returned them): no migration needed.
      echo "unchanged"
    elif [ -n "$to" ] && [ "$handoffs" -lt "$hc" ]; then
      # Hand off to an operator with headroom; stamp claimed-by + bump handoffs.
      tmp=$(fm_fleet_tmpfile "$dir" backlog.md) || { fm_fleet_unlock; return 1; }
      awk -v id="$id" -v to="$to" -v ts="$ts" -v h="$((handoffs + 1))" '
        function item_id(line){ if (match(line, /\[id:[^]]+\]/)) return substr(line, RSTART+4, RLENGTH-5); return "" }
        item_id($0)==id {
          if ($0 ~ /claimed-by:[^ ]+/) sub(/claimed-by:[^ ]+/, "claimed-by:" to "@" ts)
          else sub(/status:[a-z-]+/, "claimed-by:" to "@" ts " status:claimed")
          if ($0 ~ /handoffs:[0-9]+/) sub(/handoffs:[0-9]+/, "handoffs:" h)
          else $0=$0" handoffs:"h
          print; next
        }
        { print }
      ' "$dir/backlog.md" > "$tmp" && mv "$tmp" "$dir/backlog.md"
      fm_fleet_event "$dir" "$to" handoff "$id" "drain-overflow"
      echo "$to"
    else
      # No operator with headroom or the per-item cap is reached: explicit
      # "fleet out of tokens" (status:drained) instead of a silent drop.
      tmp=$(fm_fleet_tmpfile "$dir" backlog.md) || { fm_fleet_unlock; return 1; }
      awk -v id="$id" '
        function item_id(line){ if (match(line, /\[id:[^]]+\]/)) return substr(line, RSTART+4, RLENGTH-5); return "" }
        item_id($0)==id {
          sub(/claimed-by:[^ ]+ /, "", $0)
          if ($0 !~ /status:drained/) sub(/status:[a-z-]+/, "status:drained")
          print; next
        }
        { print }
      ' "$dir/backlog.md" > "$tmp" && mv "$tmp" "$dir/backlog.md"
      fm_fleet_event "$dir" "-" drain "$id" "fleet out of tokens"
      echo "drained"
    fi
  fi
  fm_fleet_unlock
  return $rc
}

# Requeue stale claims: items still status:claimed whose claimed-by:@<ts> is older
# than ttl seconds go back to Queued (never-started work from an offline operator).
# status:in-flight items are left alone.
fm_fleet_reap() { # dir ttl_seconds
  local dir=$1 ttl=${2:-86400} now tmp
  now=$(date -u +%s)
  fm_fleet_lock "$dir" || return 1
  tmp=$(fm_fleet_tmpfile "$dir" backlog.md) || { fm_fleet_unlock; return 1; }
  # Buffered two-pass: collect stale claimed lines (removing them in place),
  # then re-emit and insert the requeued copies under ## Queued.
  awk -v ttl="$ttl" -v now="$now" "$_FM_FLEET_AWK_EPOCH"'
    { lines[NR]=$0
      if ($0 ~ /status:claimed/ && $0 ~ /claimed-by:[^@]+@[0-9TZ:-]+/) {
        match($0, /@[0-9TZ:-]+/); iso=substr($0, RSTART+1, RLENGTH-1)
        # ep<=0 means the stamp is unreadable, NOT that it is ancient: requeue
        # nothing rather than yanking every claim out from under its owner.
        ep=epoch(iso)
        if (ep > 0 && (now - ep) > ttl) {
          remove[NR]=1
          r=$0; gsub(/claimed-by:[^ ]+ /, "", r); sub(/status:claimed/, "status:queued", r)
          rn++; req[rn]=r
        }
      }
    }
    END {
      for (i=1;i<=NR;i++) {
        if (i in remove) continue
        print lines[i]
        if (lines[i]=="## Queued") for (j=1;j<=rn;j++) { print ""; print req[j] }
      }
    }
  ' "$dir/backlog.md" > "$tmp" && mv "$tmp" "$dir/backlog.md"
  fm_fleet_event "$dir" "-" reap "-" "ttl=$ttl"
  fm_fleet_unlock
}

# --- routing ------------------------------------------------------------------

# Echo the operator who should own a task of the given scope.
# scope-primary: the online operator whose scope column contains the scope.
# overflow: if the scope-owner is unavailable, the operator whose scope contains "overflow".
# any-headroom: if neither scope-owner nor the overflow-designated operator is
#   eligible, the first eligible operator with published headroom (Task 18:
#   cross-operator overflow on token drain - a drained scope-owner's work
#   migrates to ANY operator with headroom, not only the designated fallback).
# Echo the operator who should own a task of the given scope.
# An operator is ELIGIBLE only when all three hold:
#   status:online AND heartbeat fresh (seen within FM_FLEET_HEARTBEAT_TTL, default 90s)
#   AND published quota headroom >= FM_FLEET_QUOTA_MIN (default 5), unless quota is '-'.
# Freshness + quota are self-healing: a crashed firstmate stops heartbeating and a
# low-headroom operator publishes it, so routing skips both without cross-user auth.
# 5-column legacy rows (no seen/quota) skip the freshness/quota checks (back-compat).
# Priority: scope-owner first; else the overflow-designated operator; else any
# eligible operator with headroom; else empty (caller may mark "fleet out of tokens").
# One awk pass over operators.md.
fm_fleet_route() { # dir scope
  local dir=$1 scope=$2 now ttl floor
  now=$(date -u +%s); ttl=${FM_FLEET_HEARTBEAT_TTL:-90}; floor=${FM_FLEET_QUOTA_MIN:-5}
	  awk -F'|' -v s="$scope" -v now="$now" -v ttl="$ttl" -v floor="$floor" "$_FM_FLEET_AWK_EPOCH"'
	    function trim(x){ gsub(/^ +| +$/,"",x); return x }
	    function has_scope(sc,wanted,   parts,n,i){
	      gsub(/ /,"",sc)
	      n=split(sc,parts,",")
	      for(i=1;i<=n;i++) if(parts[i]==wanted) return 1
	      return 0
	    }
	    function eligible(st,seen,q,   ep){
	      if(st!="online") return 0
	      ep=epoch(seen); if(ep>0 && (now-ep)>ttl) return 0
	      if(q!="" && q!="-" && (q+0)<floor) return 0
	      return 1
	    }
	    /^\| *[a-zA-Z0-9_.-]+ *\|/ {
	      op=trim($2); sc=$3; st=trim($6); seen=trim($7); q=trim($8)
	      if(op=="operator") next
	      if(!eligible(st,seen,q)) next
	      if(any=="") any=op
	      if(owner=="" && has_scope(sc,s)) owner=op
	      if(ov=="" && has_scope(sc,"overflow")) ov=op
	    }
	    END{ print (owner!=""?owner:(ov!=""?ov:any)) }
	  ' "$dir/operators.md"
	}

# --- visibility ---------------------------------------------------------------

fm_fleet_view() { # dir [--follow]
  local dir=$1 follow=${2:-}
  if [ "$follow" = "--follow" ]; then
    tail -f "$dir/events.log"
  else
    awk -F'\t' '{ printf "%-20s %-10s %-8s %-8s %s\n", $1, $2, $3, $4, $5 }' "$dir/events.log"
  fi
}

fm_fleet_status() { # dir
  local dir=$1 op c inflt last
  echo "operator            claimed  in-flight  last-event"
  while IFS= read -r op; do
    [ -n "$op" ] || continue
    c=$(fm_fleet_count_operator_status "$dir" "$op" claimed)
    inflt=$(fm_fleet_count_operator_status "$dir" "$op" in-flight)
    last=$(awk -F'\t' -v o="$op" '$2==o{t=$1} END{print t}' "$dir/events.log" 2>/dev/null)
    printf "%-20s %-8s %-10s %s\n" "$op" "${c:-0}" "${inflt:-0}" "${last:--}"
  done < <(awk -F'|' '/^\| *[a-zA-Z0-9_.-]+ *\|/{op=$2; gsub(/^ +| +$/,"",op); if(op!="operator" && op !~ /^-+$/) print op}' "$dir/operators.md")
}

# --- operator lifecycle + token economy (each user runs these AS THEMSELVES) ---
# operators.md row: | op | scope | home | accounts | status | seen(iso) | quota(%|-) |
# seen + quota are self-published by that operator's own heartbeat, so routing can
# treat a crashed (stale) or low-headroom peer as unavailable WITHOUT reading that
# peer's home or auth. The recorded home is validated under the caller's own $HOME.

# Refuse a recorded home outside the caller's own $HOME (cross-uid safety).
fm_fleet_assert_own_home() { # home
  local home=${1%/}
  case "$home" in
    "$HOME"|"$HOME"/*) return 0 ;;
    *) echo "error: refusing to register a home outside your own \$HOME ($HOME): $1" >&2; return 1 ;;
  esac
}

# Upsert this operator's row (self-onboard / update). Idempotent: an existing row for
# <op> is replaced, not duplicated. Stamps status:online, seen:now, quota:now.
fm_fleet_register() { # dir op scopes home [accounts]
  local dir=$1 op=$2 scopes=$3 home=$4 accounts=${5:-} ts q tmp
  fm_fleet_assert_own_home "$home" || return 1
  ts=$(fm_fleet_now); q=$(fm_fleet_quota_now)
  fm_fleet_lock "$dir" || return 1
  tmp=$(fm_fleet_tmpfile "$dir" operators.md) || { fm_fleet_unlock; return 1; }
  awk -F'|' -v OFS='|' -v op="$op" '
    function trim(x){ gsub(/^ +| +$/,"",x); return x }
    trim($2)!=op { print }
  ' "$dir/operators.md" > "$tmp" && mv "$tmp" "$dir/operators.md"
  printf '| %s | %s | %s | %s | online | %s | %s |\n' "$op" "$scopes" "$home" "$accounts" "$ts" "$q" >> "$dir/operators.md"
  fm_fleet_event "$dir" "$op" register "-" "scope:$scopes"
  fm_fleet_unlock
}

# Refresh this operator's liveness: seen:now + quota:now + status:online. Bash-only,
# meant to run on a cheap timer/daemon (NOT the LLM) so being "online" costs 0 tokens.
fm_fleet_heartbeat() { # dir op
  local dir=$1 op=$2 ts q rc=1 tmp
  ts=$(fm_fleet_now); q=$(fm_fleet_quota_now)
  fm_fleet_lock "$dir" || return 1
  if fm_fleet_operator_exists "$dir" "$op"; then
    tmp=$(fm_fleet_tmpfile "$dir" operators.md) || { fm_fleet_unlock; return 1; }
    awk -F'|' -v OFS='|' -v op="$op" -v ts=" $ts " -v q=" $q " '
      function trim(x){ gsub(/^ +| +$/,"",x); return x }
      trim($2)==op { $6=" online "; $7=ts; $8=q; NF=(NF<9?9:NF); print; next }
      { print }
    ' "$dir/operators.md" > "$tmp" && mv "$tmp" "$dir/operators.md"
    # No event line: heartbeat is transient liveness, not audit history.
    # Logging every beat would bloat events.log and churn the lock. The seen
    # column IS the liveness record; on a same-machine shared FS the file write is
    # visible to every operator immediately.
    rc=0
  fi
  fm_fleet_unlock
  return $rc
}

# Mark this operator offline (clean shutdown). Routing skips it immediately.
fm_fleet_leave() { # dir op
  local dir=$1 op=$2 rc=1 tmp
  fm_fleet_lock "$dir" || return 1
  if fm_fleet_operator_exists "$dir" "$op"; then
    tmp=$(fm_fleet_tmpfile "$dir" operators.md) || { fm_fleet_unlock; return 1; }
    awk -F'|' -v OFS='|' -v op="$op" '
      function trim(x){ gsub(/^ +| +$/,"",x); return x }
      trim($2)==op { $6=" offline "; print; next }
      { print }
    ' "$dir/operators.md" > "$tmp" && mv "$tmp" "$dir/operators.md"
    fm_fleet_event "$dir" "$op" leave "-" ""
    rc=0
  fi
  fm_fleet_unlock
  return $rc
}
