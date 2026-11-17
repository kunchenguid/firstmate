#!/usr/bin/env bash
# ak47/hdevops/apply.sh - land the ak47 hygiene deployment in H-DevOps as a PR.
#
# The hygiene system's code lives in firstmate. This script captures both the
# code and the deployment into an H-DevOps clone: the ak47 scripts, the two user
# timers, and the two sysctls that were hand-written on the box and recorded
# nowhere. It commits on a branch, pushes the branch, and opens a PR.
#
# It never pushes to the default branch, never merges, and never touches the
# clone's working tree beyond the payload paths it owns.
#
# The payload under ansible/playbooks/files/ak47/ is generated from the
# canonical ak47/ tree. Never edit it by hand.
#
# Usage: apply.sh [--repo DIR] [--branch NAME] [--dry-run] [--no-pr]
#                 [--check] [--write-payload]
#   --repo DIR       H-DevOps clone (default $FM_HOME/projects/H-DevOps)
#   --branch NAME    branch to create (default fm/ak47-hygiene-deployment)
#   --dry-run        show what would be copied and committed, change nothing
#   --no-pr          commit and push, but do not open a PR
#   --check          regenerate into a temp dir and diff the committed payload
#   --write-payload  regenerate the committed payload and exit
#
# Exit: 0 landed, 1 a step failed, 2 bad usage.
set -u

AK47_ROOT=${AK47_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}
# shellcheck source=../lib/common.sh
. "$AK47_ROOT/lib/common.sh"

REPO=$FM_HOME/projects/H-DevOps
BRANCH=fm/ak47-hygiene-deployment
DRY=0; OPEN_PR=1; CHECK=0; WRITE_PAYLOAD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO=${2:?--repo needs a path}; shift 2 ;;
    --branch) BRANCH=${2:?--branch needs a name}; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --no-pr) OPEN_PR=0; shift ;;
    --check) CHECK=1; shift ;;
    --write-payload) WRITE_PAYLOAD=1; shift ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "apply.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

PAYLOAD=$AK47_ROOT/hdevops
PAYLOAD_DIR=$PAYLOAD/ansible/playbooks/files/ak47
PAYLOAD_FILES=(
  budget.conf
  census-producers.conf
  census.sh
  guards/agent-reclaim.sh
  guards/cleanup-patterns.conf
  guards/guard-producers.sh
  lib/classify.py
  lib/common.sh
  lib/protected.sh
  lib/safe-delete.sh
  status.sh
  swap-reclaim.sh
  tick.sh
  tmp-takedown.sh
  weekly-review.sh
)

generate_payload() {
  local dest=$1 f
  mkdir -p "$dest" || return 1
  for f in "${PAYLOAD_FILES[@]}"; do
    mkdir -p "$dest/$(dirname "$f")" || return 1
    cp -p "$AK47_ROOT/$f" "$dest/$f" || return 1
  done
}

[ -d "$PAYLOAD/ansible" ] || { echo "apply.sh: payload missing at $PAYLOAD" >&2; exit 1; }

if [ "$CHECK" = 1 ] || [ "$WRITE_PAYLOAD" = 1 ]; then
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/ak47-payload.XXXXXX") || exit 1
  trap 'rm -rf "$tmp"' EXIT
  generate_payload "$tmp" || { echo "apply.sh: could not generate the payload" >&2; exit 1; }
  if [ "$WRITE_PAYLOAD" = 1 ]; then
    rm -rf "$PAYLOAD_DIR"
    mkdir -p "$(dirname "$PAYLOAD_DIR")"
    mv "$tmp" "$PAYLOAD_DIR" || exit 1
    trap - EXIT
    echo "regenerated: $PAYLOAD_DIR"
    exit 0
  fi
  if [ ! -d "$PAYLOAD_DIR" ]; then
    echo "apply.sh: committed payload missing at $PAYLOAD_DIR" >&2
    exit 1
  fi
  if diff -ru "$PAYLOAD_DIR" "$tmp"; then
    echo "payload is up to date"
    exit 0
  fi
  echo "apply.sh: committed payload differs from ak47/; run apply.sh --write-payload" >&2
  exit 1
fi

# -e, not -d: a linked worktree has .git as a file, and a worktree is the
# right place to run this from when the main clone is busy on another branch.
[ -e "$REPO/.git" ] || { echo "apply.sh: $REPO is not a git clone" >&2; exit 1; }

# The paths this script owns inside H-DevOps. Nothing else is staged, so a
# dirty clone with unrelated work in it is safe to run against.
OWNED=(
  ansible/inventory/local/hosts.yml
  ansible/playbooks/07-ak47-hygiene.yml
  ansible/playbooks/files/ak47/budget.conf
  ansible/playbooks/files/ak47/census-producers.conf
  ansible/playbooks/files/ak47/census.sh
  ansible/playbooks/files/ak47/guards/agent-reclaim.sh
  ansible/playbooks/files/ak47/guards/cleanup-patterns.conf
  ansible/playbooks/files/ak47/guards/guard-producers.sh
  ansible/playbooks/files/ak47/lib/classify.py
  ansible/playbooks/files/ak47/lib/common.sh
  ansible/playbooks/files/ak47/lib/protected.sh
  ansible/playbooks/files/ak47/lib/safe-delete.sh
  ansible/playbooks/files/ak47/status.sh
  ansible/playbooks/files/ak47/swap-reclaim.sh
  ansible/playbooks/files/ak47/tick.sh
  ansible/playbooks/files/ak47/tmp-takedown.sh
  ansible/playbooks/files/ak47/weekly-review.sh
  ansible/playbooks/templates/60-ak47-inotify.conf
  ansible/playbooks/templates/60-ak47-swap.conf
  ansible/playbooks/templates/60-ak47-oomd-swap.conf
  ansible/playbooks/templates/60-ak47-oomd-avoid.conf
  ansible/playbooks/templates/60-ak47-tasksmax-user.conf
  ansible/playbooks/templates/60-ak47-tasksmax-slice.conf
  ansible/playbooks/templates/ak47-health.sh
  ansible/playbooks/templates/ak47-health.service
  ansible/playbooks/templates/ak47-health.timer
  ansible/playbooks/templates/ak47-devops.service
  ansible/playbooks/templates/ak47-devops.timer
  ansible/playbooks/templates/ak47-agent-reclaim.service
  ansible/playbooks/templates/ak47-agent-reclaim.timer
  ansible/playbooks/templates/ak47-devops-weekly.service
  ansible/playbooks/templates/ak47-devops-weekly.timer
  ansible/playbooks/templates/ak47-swap-reclaim.service
)

echo "== ak47 hygiene deployment -> H-DevOps =="
echo "repo:    $REPO"
echo "branch:  $BRANCH"
echo "payload: $PAYLOAD"
echo

default_branch=$(git -C "$REPO" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
default_branch=${default_branch:-main}
if [ "$BRANCH" = "$default_branch" ]; then
  echo "apply.sh: refusing to commit to the default branch ($default_branch)" >&2
  exit 1
fi

if [ "$DRY" = 1 ]; then
  echo "would: git -C $REPO checkout -b $BRANCH"
  for p in "${OWNED[@]}"; do
    echo "would: copy $PAYLOAD/$p -> $REPO/$p"
  done
  echo "would: git add ${OWNED[*]}"
  echo "would: git commit -m 'ak47: capture the hygiene deployment as code'"
  echo "would: git push -u origin $BRANCH"
  [ "$OPEN_PR" = 1 ] && echo "would: gh-axi pr create ..."
  exit 0
fi

# ---- branch --------------------------------------------------------------------
current=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)
if [ "$current" = "$BRANCH" ]; then
  echo "already on $BRANCH"
elif git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "apply.sh: branch $BRANCH already exists; delete it or pass --branch" >&2
  exit 1
else
  git -C "$REPO" checkout -b "$BRANCH" || exit 1
fi

# ---- payload -------------------------------------------------------------------
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ak47-payload.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
generate_payload "$tmp" || { echo "apply.sh: could not generate the payload" >&2; exit 1; }
rm -rf "$PAYLOAD_DIR"
mkdir -p "$(dirname "$PAYLOAD_DIR")"
mv "$tmp" "$PAYLOAD_DIR" || exit 1
trap - EXIT
echo "regenerated: $PAYLOAD_DIR"

# ---- copy ----------------------------------------------------------------------
for p in "${OWNED[@]}"; do
  mkdir -p "$(dirname "$REPO/$p")"
  cp "$PAYLOAD/$p" "$REPO/$p" || { echo "apply.sh: copy failed for $p" >&2; exit 1; }
  echo "copied: $p"
done

# ---- commit --------------------------------------------------------------------
git -C "$REPO" add -- "${OWNED[@]}" || exit 1
if git -C "$REPO" diff --cached --quiet; then
  echo "apply.sh: nothing to commit; H-DevOps already matches the payload"
  exit 0
fi

git -C "$REPO" commit -q -F - <<'MSG' || exit 1
ak47: capture the hygiene deployment as code

ak47's /tmp held 950,700 entries on 2026-11-10, 831,000 of them the default
temp directory of a test suite that never removed it. Disk was 14% full, so
nothing that watched bytes ever looked; the cost landed on every glob, every
ls, every find and every test run, and showed up as load rather than as a
disk alert.

The same box locked up on 2026-11-10 with swap at 99-100% of 32 GB while 77 GB
of RAM sat free: nothing was watching swap, because systemd-oomd was not
installed and the health beat paged on load15 only, which never crossed 64.

What this commit captures is everything a rebuild would otherwise lose:

- the ak47 scripts, libraries, budget and producer table, installed under
  ~/.local/lib/ak47 so the units run without a firstmate checkout
- the two user timers that run the 5-minute tick and the Monday review
- the two sysctls that were hand-written on the box on 2026-11-03 and
  2026-11-10 and recorded nowhere else: vm.swappiness=10, which stopped the
  kernel paging 20 GB of idle agents to disk while 77 GB of RAM sat free, and
  fs.inotify.max_user_instances=8192, which ~250 agents need
- systemd-oomd, with ManagedOOMSwap=kill on user@1000.service (systemd 255
  monitors swap only for `kill`, never for `auto`) and
  ManagedOOMPreference=avoid on the six units that are the fleet's spine
- ak47-health.sh and its 10-minute timer, now paging on swap >= 70%,
  available RAM < 15 GB, load, and 80% of the user task cap, and paging when
  the hygiene tick itself stops writing for 30 minutes
- the user task cap, both bounds: DefaultTasksMax=4096 in
  /etc/systemd/user.conf.d/60-ak47-tasksmax-user.conf, so one transient tmux
  pane scope can no longer take the whole slice, and TasksMax=24576 on
  user@1000.service, because on 2026-11-14 the uid reached pids.max 12000 and
  every fork in it returned EAGAIN for five hours

The playbook is not in site.yml on purpose: site.yml targets the OVH cluster,
and this targets one workstation over a local connection.

Revert is in the playbook header and keeps every log and quarantine directory.
MSG

echo "committed: $(git -C "$REPO" rev-parse --short HEAD)"

# ---- push ----------------------------------------------------------------------
git -C "$REPO" push -u origin "$BRANCH" || { echo "apply.sh: push failed" >&2; exit 1; }
echo "pushed: $BRANCH"

# ---- PR ------------------------------------------------------------------------
if [ "$OPEN_PR" = 1 ]; then
  command -v gh-axi >/dev/null || { echo "apply.sh: gh-axi not found; branch is pushed, open the PR by hand" >&2; exit 1; }
  ( cd "$REPO" && gh-axi pr create \
      --base "$default_branch" \
      --head "$BRANCH" \
      --title "ak47: capture the hygiene deployment as code" \
      --body "Captures the ak47 factory box's hygiene system so a rebuild reproduces it: the ak47 scripts, libraries, budget and producer table installed under ~/.local/lib/ak47, the two user timers (5-minute deterministic tick, Monday review), and the two sysctls that were hand-written on the box and recorded nowhere else.

The hygiene code is developed in firstmate (\`ak47/\`); this PR carries the payload a rebuild installs.

Revert is in the playbook header and keeps every log and every quarantine directory." ) || exit 1
fi

echo
echo "== done =="
echo "Review the PR, then merge it yourself; this script never merges."
