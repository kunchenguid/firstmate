#!/usr/bin/env bash
# Execute a task merge through one shared exact-candidate boundary.
#
# Usage: fm-merge-execute.sh local <task-id>
#        fm-merge-execute.sh github <task-id> <pr-url> [-- <merge-options>]
# GitHub merge options are --squash, --merge, --rebase,
# --method <squash|merge|rebase>, --method=<squash|merge|rebase>, and
# --delete-branch.
#
# Both sanctioned merge entry points delegate here.
# The boundary validates task metadata, repository identity, clean exact
# candidate and base commits, and literal-source inventory receipts before the
# merge itself.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MERGE_EXECUTE_ARGS=("$@")

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

die() { echo "error: $*" >&2; exit 1; }

meta_value() {
  local key=$1 values count
  values=$(sed -n "s/^${key}=//p" "$META")
  count=$(printf '%s\n' "$values" | awk 'NF { count++ } END { print count + 0 }')
  [ "$count" -eq 1 ] || die "task metadata must contain exactly one nonempty ${key}= value"
  printf '%s\n' "$values"
}

meta_optional_value() {
  local key=$1 values count
  values=$(sed -n "s/^${key}=//p" "$META")
  count=$(grep -c "^${key}=" "$META" || true)
  [ "$count" -le 1 ] || die "task metadata must contain at most one ${key}= value"
  [ "$count" -eq 0 ] || [ -n "$values" ] || die "task metadata contains an empty ${key}= value"
  printf '%s\n' "$values"
}

git_top() { git -C "$1" rev-parse --show-toplevel 2>/dev/null || return 1; }

git_common() {
  local root=$1 common
  common=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) (cd "$common" 2>/dev/null && pwd -P) ;;
    *) (cd "$root/$common" 2>/dev/null && pwd -P) ;;
  esac
}

require_clean() {
  local root=$1 label=$2 status
  status=$(git -C "$root" status --porcelain --untracked-files=all 2>/dev/null) || die "cannot inspect $label state"
  [ -z "$status" ] || die "$label is dirty; refusing merge execution"
}

require_repository_state() {
  local worktree_top project_top worktree_common project_common
  [ -d "$WORKTREE" ] && [ ! -L "$WORKTREE" ] || die "task worktree is unavailable"
  [ -d "$PROJECT" ] && [ ! -L "$PROJECT" ] || die "task project checkout is unavailable"
  worktree_top=$(git_top "$WORKTREE") || die "task worktree is not a git checkout"
  project_top=$(git_top "$PROJECT") || die "task project is not a git checkout"
  [ "$(cd "$WORKTREE" && pwd -P)" = "$(cd "$worktree_top" && pwd -P)" ] || die "task worktree path does not match its git top-level"
  [ "$(cd "$PROJECT" && pwd -P)" = "$(cd "$project_top" && pwd -P)" ] || die "task project path does not match its git top-level"
  worktree_common=$(git_common "$WORKTREE") || die "cannot resolve task worktree repository"
  project_common=$(git_common "$PROJECT") || die "cannot resolve task project repository"
  [ "$worktree_common" = "$project_common" ] || die "task worktree and project metadata name different repositories"
  require_clean "$WORKTREE" "task worktree"
  require_clean "$PROJECT" "project checkout"
}

ensure_repository_lock() {
  local common lock_path
  common=$(git_common "$PROJECT") || die "cannot resolve repository lock path"
  lock_path="$common/firstmate-merge.lock"
  if [ -n "${FM_MERGE_LOCK_FD:-}" ]; then
    python3 - "$FM_MERGE_LOCK_FD" "$lock_path" <<'PY' || die "repository merge lock is invalid"
import fcntl
import os
import pathlib
import sys

fd = int(sys.argv[1])
path = pathlib.Path(sys.argv[2])
held = os.fstat(fd)
current = path.stat()
if (held.st_dev, held.st_ino) != (current.st_dev, current.st_ino):
    raise SystemExit(1)
fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
PY
    return
  fi
  python3 - "$lock_path" "$SCRIPT_DIR/fm-merge-execute.sh" "${MERGE_EXECUTE_ARGS[@]}" <<'PY'
import fcntl
import os
import subprocess
import sys

lock_path, script, *args = sys.argv[1:]
fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
os.set_inheritable(fd, True)
environment = os.environ.copy()
environment["FM_MERGE_LOCK_FD"] = str(fd)
result = subprocess.run([script, *args], env=environment, pass_fds=(fd,))
raise SystemExit(result.returncode)
PY
  exit $?
}

default_branch() {
  local ref branch
  ref=$(git -C "$PROJECT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then printf '%s\n' "${ref#origin/}"; return 0; fi
  for branch in main master; do
    if git -C "$PROJECT" show-ref --verify --quiet "refs/heads/$branch"; then printf '%s\n' "$branch"; return 0; fi
  done
  return 1
}

api_value() {
  local key=$1 payload=$2 value count
  value=$(printf '%s\n' "$payload" | sed -n "s/^[[:space:]]*${key}: //p")
  count=$(printf '%s\n' "$value" | awk 'NF { count++ } END { print count + 0 }')
  [ "$count" -eq 1 ] || die "GitHub response did not contain exactly one ${key} value"
  printf '%s\n' "$value"
}

urlencode_ref() { python3 - "$1" <<'PY'
import sys
import urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=""))
PY
}

land_local_exact() {
  python3 - "$PROJECT" "$DEFAULT" "$1" "$2" <<'PY'
import os
import pathlib
import shlex
import subprocess
import sys
import tempfile

project, default, base, candidate = sys.argv[1:]
ref = f"refs/heads/{default}"


class LandingError(Exception):
    pass


def git(*args, check=True, input_data=None):
    result = subprocess.run(
        ["git", "-C", project, *args],
        text=True,
        input=input_data,
        capture_output=True,
    )
    if check and result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise LandingError(detail or f"git {' '.join(args)} failed")
    return result


def configured_hooks_path():
    configured = git("config", "--path", "core.hooksPath", check=False)
    if configured.returncode == 0 and configured.stdout.strip():
        path = pathlib.Path(configured.stdout.strip())
        return path if path.is_absolute() else pathlib.Path(project, path).resolve()
    return pathlib.Path(git("rev-parse", "--path-format=absolute", "--git-path", "hooks").stdout.strip())


def install_hooks(directory):
    # Local landing assumes a quiescent checkout; concurrent uncooperative writers are outside the supported boundary.
    # Best-effort dirty-state checks keep observed drift from proceeding silently.
    original_directory = configured_hooks_path()
    original_reference = original_directory / "reference-transaction"
    if original_directory.is_dir():
        for source in original_directory.iterdir():
            if source.name != "reference-transaction" and os.access(source, os.X_OK):
                (directory / source.name).symlink_to(source.resolve())
    original_command = shlex.quote(str(original_reference)) if os.access(original_reference, os.X_OK) else ":"
    hook = directory / "reference-transaction"
    hook.write_text(
        "#!/usr/bin/env bash\n"
        "set -eu\n"
        "payload=$(mktemp \"${TMPDIR:-/tmp}/fm-merge-ref.XXXXXX\")\n"
        "trap 'rm -f \"$payload\"' EXIT HUP INT TERM\n"
        "cat > \"$payload\"\n"
        f"{original_command} \"$1\" < \"$payload\"\n"
        "[ \"$1\" = prepared ] || exit 0\n"
        "awk -v ref=\"$FM_MERGE_EXPECTED_REF\" -v base=\"$FM_MERGE_EXPECTED_BASE\" -v candidate=\"$FM_MERGE_EXPECTED_CANDIDATE\" -v zero=0000000000000000000000000000000000000000 '\n"
        "  NF != 3 { invalid = 1; next }\n"
        "  $3 == ref { if ($1 != base || $2 != candidate) invalid = 1; expected++; next }\n"
        "  $3 == \"ORIG_HEAD\" { if ($2 != base) invalid = 1; original++; next }\n"
        "  $3 == \"AUTO_MERGE\" { if ($2 != zero) invalid = 1; automatic++; next }\n"
        "  { invalid = 1 }\n"
        "  END {\n"
        "    if (invalid) exit 1\n"
        "    if (expected == 1 && original <= 1 && automatic <= 1) exit 0\n"
        "    if (expected == 0 && NR == 1 && original + automatic == 1) exit 0\n"
        "    exit 1\n"
        "  }\n"
        "' \"$payload\" || exit 1\n"
        "if grep -qF \" $FM_MERGE_EXPECTED_REF\" \"$payload\"; then\n"
        "  [ \"$(git -C \"$FM_MERGE_PROJECT\" symbolic-ref --quiet HEAD)\" = \"$FM_MERGE_EXPECTED_REF\" ] || exit 1\n"
        "  grep -qxF \"$FM_MERGE_EXPECTED_BASE $FM_MERGE_EXPECTED_CANDIDATE $FM_MERGE_EXPECTED_REF\" \"$payload\" || exit 1\n"
        "  git -C \"$FM_MERGE_PROJECT\" diff --quiet \"$FM_MERGE_EXPECTED_CANDIDATE\" -- || exit 1\n"
        "  [ -z \"$(git -C \"$FM_MERGE_PROJECT\" ls-files --others --exclude-standard)\" ] || exit 1\n"
        "fi\n"
    )
    hook.chmod(0o700)


def rollback_checkout():
    changed = git("diff-tree", "--no-commit-id", "--name-only", "-r", "-z", base, candidate).stdout
    dirty = git("diff", "--name-only", "-z", candidate, "--").stdout
    dirty_paths = set(dirty.split("\0"))
    restore = [path for path in changed.split("\0") if path and path not in dirty_paths]
    if restore:
        git(
            "restore",
            f"--source={base}",
            "--worktree",
            "--pathspec-from-file=-",
            "--pathspec-file-nul",
            input_data="\0".join(restore) + "\0",
        )
    git("read-tree", base)


with tempfile.TemporaryDirectory(prefix="fm-merge-hooks-") as temporary:
    hooks = pathlib.Path(temporary)
    install_hooks(hooks)
    environment = os.environ.copy()
    environment.update(
        FM_MERGE_PROJECT=project,
        FM_MERGE_EXPECTED_REF=ref,
        FM_MERGE_EXPECTED_BASE=base,
        FM_MERGE_EXPECTED_CANDIDATE=candidate,
    )
    result = subprocess.run(
        ["git", "-C", project, "-c", f"core.hooksPath={hooks}", "merge", "--ff-only", candidate],
        text=True,
        capture_output=True,
        env=environment,
    )

if result.returncode == 0:
    if git("rev-parse", ref).stdout.strip() != candidate:
        print("error: local merge did not land the exact candidate", file=sys.stderr)
        raise SystemExit(1)
    raise SystemExit(0)

error = (result.stderr or result.stdout).strip()
try:
    rollback_checkout()
except LandingError as rollback_error:
    print(f"error: {error or 'local merge failed'}; checkout rollback also failed: {rollback_error}", file=sys.stderr)
    raise SystemExit(1)
print(f"error: {error or 'local merge transaction was refused'}", file=sys.stderr)
raise SystemExit(1)
PY
}

execute_local() {
  local branch current candidate base before after
  [ "$MODE" = local-only ] || die "task $ID is mode=$MODE, not local-only"
  [ "$KIND" = ship ] || die "task $ID is kind=$KIND, not ship"
  require_repository_state
  branch="fm/$ID"
  git -C "$PROJECT" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null || die "branch $branch does not exist in $PROJECT"
  current=$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ "$current" = "$branch" ] || die "task worktree is on '$current', expected '$branch'"
  candidate=$(git -C "$WORKTREE" rev-parse HEAD)
  [ "$(git -C "$PROJECT" rev-parse "refs/heads/$branch")" = "$candidate" ] || die "task worktree HEAD does not match its branch ref"
  DEFAULT=$(default_branch) || die "cannot determine default branch for $PROJECT"
  current=$(git -C "$PROJECT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ "$current" = "$DEFAULT" ] || die "$PROJECT is on '$current', expected default branch '$DEFAULT'"
  base=$(git -C "$PROJECT" rev-parse "refs/heads/$DEFAULT")
  git -C "$PROJECT" merge-base --is-ancestor "$base" "$candidate" || die "$branch is not a fast-forward of $DEFAULT"
  "$SCRIPT_DIR/fm-test-inventory.sh" merge-check "$WORKTREE" "$candidate" "$base"
  require_clean "$WORKTREE" "task worktree"
  require_clean "$PROJECT" "project checkout"
  [ "$(git -C "$WORKTREE" rev-parse HEAD)" = "$candidate" ] || die "task worktree HEAD changed during merge verification"
  [ "$(git -C "$PROJECT" rev-parse "refs/heads/$DEFAULT")" = "$base" ] || die "local merge base changed during merge verification"
  before=${base:0:12}
  land_local_exact "$base" "$candidate" || die "local checkout or base changed before the exact candidate could land"
  after=$(git -C "$PROJECT" rev-parse "refs/heads/$DEFAULT")
  [ "$after" = "$candidate" ] || die "local merge did not land the verified candidate SHA"
  echo "merged $branch into local $DEFAULT ($before -> ${after:0:12}) in $PROJECT"
}

execute_github() {
  local query payload head base base_ref state draft merged strict admin_enforced recorded_pr recorded_head merge_output head_repo head_ref encoded_ref
  [ "$MODE" = no-mistakes ] || [ "$MODE" = direct-PR ] || die "task $ID is mode=$MODE, not a PR merge mode"
  [ "$KIND" = ship ] || die "task $ID is kind=$KIND, not ship"
  require_repository_state
  fm_pr_merge_args_parse "$@" || exit $?
  MERGE_METHOD=$FM_PR_MERGE_METHOD
  DELETE_BRANCH=$FM_PR_MERGE_DELETE_BRANCH
  recorded_pr=$(meta_value pr)
  recorded_head=$(meta_optional_value pr_head)
  [ "$recorded_pr" = "$URL" ] || die "task PR metadata does not match the requested PR"
  query="{repository(owner:\"$PR_OWNER\",name:\"$PR_REPO\"){pullRequest(number:$PR_NUMBER){headRefOid baseRefOid baseRefName headRefName state isDraft merged headRepository{nameWithOwner} baseRef{branchProtectionRule{requiresStrictStatusChecks isAdminEnforced}}}}}"
  payload=$(gh-axi api POST /graphql --field "query=$query") || die "cannot read the exact GitHub merge candidate"
  head=$(api_value headRefOid "$payload"); base=$(api_value baseRefOid "$payload"); base_ref=$(api_value baseRefName "$payload")
  head_ref=$(api_value headRefName "$payload"); head_repo=$(api_value nameWithOwner "$payload"); state=$(api_value state "$payload")
  draft=$(api_value isDraft "$payload"); merged=$(api_value merged "$payload"); strict=$(api_value requiresStrictStatusChecks "$payload"); admin_enforced=$(api_value isAdminEnforced "$payload")
  [ "$state" = OPEN ] && [ "$draft" = false ] && [ "$merged" = false ] || die "GitHub pull request is not an open, mergeable candidate"
  [ -z "$recorded_head" ] || fm_pr_head_valid "$recorded_head" || die "task PR head metadata is invalid"
  [ -z "$recorded_head" ] || [ "$recorded_head" = "$head" ] || die "task PR head metadata does not match the current GitHub head"
  [ "$(git -C "$WORKTREE" rev-parse HEAD)" = "$head" ] || die "task worktree HEAD does not match the current GitHub PR head"
  git -C "$WORKTREE" cat-file -e "$base^{commit}" 2>/dev/null || git -C "$WORKTREE" fetch --quiet "https://github.com/$PR_OWNER/$PR_REPO.git" "$base"
  git -C "$WORKTREE" merge-base --is-ancestor "$base" "$head" || die "GitHub PR head does not contain the current base; update the branch and retry"
  [ "$strict" = true ] && [ "$admin_enforced" = true ] || die "exact GitHub merge execution requires strict, admin-enforced base branch protection"
  "$SCRIPT_DIR/fm-test-inventory.sh" merge-check "$WORKTREE" "$head" "$base"
  require_clean "$WORKTREE" "task worktree"
  require_clean "$PROJECT" "project checkout"
  [ "$(git -C "$WORKTREE" rev-parse HEAD)" = "$head" ] || die "task worktree HEAD changed during merge verification"
  merge_output=$(gh-axi api PUT "/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER/merge" --field "sha=$head" --field "merge_method=$MERGE_METHOD") || die "GitHub rejected the exact conditional merge"
  [ "$(api_value merged "$merge_output")" = true ] || die "GitHub did not merge the verified candidate"
  if [ "$DELETE_BRANCH" -eq 1 ]; then
    [ "$head_repo" = "$PR_OWNER/$PR_REPO" ] || die "PR merged, but cross-repository head deletion is unsupported"
    encoded_ref=$(urlencode_ref "$head_ref")
    gh-axi api DELETE "/repos/$PR_OWNER/$PR_REPO/git/refs/heads/$encoded_ref" >/dev/null || die "PR merged, but deleting the head branch failed"
  fi
  echo "merged exact GitHub candidate $head into $base_ref at base $base"
}

ENTRY=${1:-}
ID=${2:-}
case "$ENTRY" in
  local) [ "$#" -eq 2 ] || { echo "usage: fm-merge-execute.sh local <task-id>" >&2; exit 2; }; fm_pr_task_id_valid "$ID" || die "invalid task ID" ;;
  github)
    [ "$#" -ge 3 ] || { echo "usage: fm-merge-execute.sh github <task-id> <pr-url> [-- <merge-args>]" >&2; exit 2; }
    RAW_URL=$3
    fm_pr_task_id_valid "$ID" && fm_pr_url_parse "$RAW_URL" && [ "$FM_PR_PROVIDER" = github ] || die "invalid GitHub merge request"
    URL=$FM_PR_URL; PR_OWNER=$FM_PR_OWNER; PR_REPO=$FM_PR_REPO; PR_NUMBER=$FM_PR_NUMBER
    shift 3; [ "${1:-}" != -- ] || shift; GITHUB_ARGS=("$@")
    ;;
  *) echo "usage: fm-merge-execute.sh <local|github> ..." >&2; exit 2 ;;
esac

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || die "task metadata is unavailable"
WORKTREE=$(meta_value worktree); PROJECT=$(meta_value project); KIND=$(meta_value kind); MODE=$(meta_value mode)
ensure_repository_lock
case "$ENTRY" in local) execute_local ;; github) execute_github "${GITHUB_ARGS[@]+"${GITHUB_ARGS[@]}"}" ;; esac
