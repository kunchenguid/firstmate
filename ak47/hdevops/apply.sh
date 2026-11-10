#!/usr/bin/env bash
# ak47/hdevops/apply.sh - land the ak47 hygiene deployment in H-DevOps as a PR.
#
# The hygiene system's code lives in firstmate. What a rebuild would lose is the
# deployment: two user timers and two sysctls that were hand-written on the box
# and recorded nowhere. This script copies that payload into an H-DevOps clone,
# commits it on a branch, pushes the branch, and opens a PR.
#
# It never pushes to the default branch, never merges, and never touches the
# clone's working tree beyond the payload paths it owns.
#
# Usage: apply.sh [--repo DIR] [--branch NAME] [--dry-run] [--no-pr]
#   --repo DIR     H-DevOps clone (default $FM_HOME/projects/H-DevOps)
#   --branch NAME  branch to create (default fm/ak47-hygiene-deployment)
#   --dry-run      show what would be copied and committed, change nothing
#   --no-pr        commit and push, but do not open a PR
#
# Exit: 0 landed, 1 a step failed, 2 bad usage.
set -u

AK47_ROOT=${AK47_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}
# shellcheck source=../lib/common.sh
. "$AK47_ROOT/lib/common.sh"

REPO=$FM_HOME/projects/H-DevOps
BRANCH=fm/ak47-hygiene-deployment
DRY=0; OPEN_PR=1
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO=${2:?--repo needs a path}; shift 2 ;;
    --branch) BRANCH=${2:?--branch needs a name}; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --no-pr) OPEN_PR=0; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "apply.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

PAYLOAD=$AK47_ROOT/hdevops
[ -d "$REPO/.git" ] || { echo "apply.sh: $REPO is not a git clone" >&2; exit 1; }
[ -d "$PAYLOAD/ansible" ] || { echo "apply.sh: payload missing at $PAYLOAD" >&2; exit 1; }

# The paths this script owns inside H-DevOps. Nothing else is staged, so a
# dirty clone with unrelated work in it is safe to run against.
OWNED=(
  ansible/inventory/local/hosts.yml
  ansible/playbooks/07-ak47-hygiene.yml
  ansible/playbooks/templates/60-ak47-inotify.conf
  ansible/playbooks/templates/60-ak47-swap.conf
  ansible/playbooks/templates/ak47-devops.service
  ansible/playbooks/templates/ak47-devops.timer
  ansible/playbooks/templates/ak47-devops-weekly.service
  ansible/playbooks/templates/ak47-devops-weekly.timer
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

The fix lives in firstmate (ak47/tick.sh, status.sh, census.sh, guards/,
weekly-review.sh, and a per-task TMPDIR in bin/fm-spawn.sh). What this commit
captures is everything a rebuild would otherwise lose:

- the two user timers that run the 5-minute tick and the Monday review
- the two sysctls that were hand-written on the box on 2026-11-03 and
  2026-11-10 and recorded nowhere else: vm.swappiness=10, which stopped the
  kernel paging 20 GB of idle agents to disk while 77 GB of RAM sat free, and
  fs.inotify.max_user_instances=8192, which ~250 agents need

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
      --body "Captures the ak47 factory box's hygiene deployment so a rebuild reproduces it: the two user timers (5-minute deterministic tick, Monday review) and the two sysctls that were hand-written on the box and recorded nowhere else.

The hygiene code itself lives in firstmate (\`ak47/\`). This PR is the drift capture only.

Revert is in the playbook header and keeps every log and every quarantine directory." ) || exit 1
fi

echo
echo "== done =="
echo "Review the PR, then merge it yourself; this script never merges."
