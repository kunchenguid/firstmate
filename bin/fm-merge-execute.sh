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

RECURSION_EXIT=70

die() { echo "error: $*" >&2; exit 1; }
die_recursion() { echo "fm-merge-execute: $*" >&2; exit "$RECURSION_EXIT"; }

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

# The origin cloned by fm-home-seed.sh owns cross-clone source identity.
# Exactly one local origin URL is required so remotes with similar names cannot
# supply or override identity evidence.
checkout_repository_identity() {
  local root=$1 label=$2 urls count identity
  urls=$(git -C "$root" config --local --get-all remote.origin.url 2>/dev/null || true)
  count=$(git -C "$root" config --local --get-all remote.origin.url 2>/dev/null \
    | awk 'END { print NR + 0 }')
  [ "$count" -eq 1 ] && [ -n "$urls" ] \
    || die "$label canonical repository identity is missing or ambiguous"
  identity=$(github_repository_identity "$urls") \
    || die "$label origin is not an unambiguous github.com repository identity"
  printf '%s\n' "$identity"
}

require_cross_clone_project_ownership() {
  local state_dir home project_top home_projects project_parent
  [ -d "$STATE" ] && [ ! -L "$STATE" ] \
    || die "task state home is unavailable"
  state_dir=$(cd "$STATE" 2>/dev/null && pwd -P) || die "task state home is unavailable"
  [ "$(basename "$state_dir")" = state ] \
    || die "task state directory does not identify an active Firstmate home"
  home=$(dirname "$state_dir")
  project_top=$(cd "$PROJECT" 2>/dev/null && pwd -P) \
    || die "cannot resolve task project ownership"
  # Project-less secondmates own the repository at the home root itself.
  [ "$project_top" != "$home" ] || return 0
  # Provisioned project clones have exactly one path component below projects/.
  home_projects="$home/projects"
  [ -d "$home_projects" ] && [ ! -L "$home_projects" ] \
    || die "task project metadata is not owned by the active Firstmate home"
  home_projects=$(cd "$home_projects" && pwd -P)
  project_parent=$(cd "$(dirname "$PROJECT")" 2>/dev/null && pwd -P) \
    || die "cannot resolve task project ownership"
  [ "$project_parent" = "$home_projects" ] \
    || die "task project metadata is not owned by the active Firstmate home"
}

require_repository_state() {
  local worktree_top project_top expected_identity
  [ -d "$WORKTREE" ] && [ ! -L "$WORKTREE" ] || die "task worktree is unavailable"
  [ -d "$PROJECT" ] && [ ! -L "$PROJECT" ] || die "task project checkout is unavailable"
  worktree_top=$(git_top "$WORKTREE") || die "task worktree is not a git checkout"
  project_top=$(git_top "$PROJECT") || die "task project is not a git checkout"
  [ "$(cd "$WORKTREE" && pwd -P)" = "$(cd "$worktree_top" && pwd -P)" ] || die "task worktree path does not match its git top-level"
  [ "$(cd "$PROJECT" && pwd -P)" = "$(cd "$project_top" && pwd -P)" ] || die "task project path does not match its git top-level"
  WORKTREE_COMMON=$(git_common "$WORKTREE") || die "cannot resolve task worktree repository"
  PROJECT_COMMON=$(git_common "$PROJECT") || die "cannot resolve task project repository"
  CROSS_CLONE_IDENTITY=0
  WORKTREE_REPOSITORY_IDENTITY=
  PROJECT_REPOSITORY_IDENTITY=
  if [ "$WORKTREE_COMMON" != "$PROJECT_COMMON" ]; then
    [ "$ENTRY" = github ] \
      || die "task worktree and project metadata name different repositories"
    require_cross_clone_project_ownership
    WORKTREE_REPOSITORY_IDENTITY=$(checkout_repository_identity "$WORKTREE" "task worktree")
    PROJECT_REPOSITORY_IDENTITY=$(checkout_repository_identity "$PROJECT" "task project")
    expected_identity=$(github_repository_identity "https://github.com/$PR_OWNER/$PR_REPO.git") \
      || die "cannot resolve the requested PR repository identity"
    [ "$WORKTREE_REPOSITORY_IDENTITY" = "$PROJECT_REPOSITORY_IDENTITY" ] \
      && [ "$PROJECT_REPOSITORY_IDENTITY" = "$expected_identity" ] \
      || die "task worktree, project metadata, and requested PR name different repositories"
    CROSS_CLONE_IDENTITY=1
  fi
  require_clean "$WORKTREE" "task worktree"
  require_clean "$PROJECT" "project checkout"
}

require_repository_identity_unchanged() {
  local worktree_common project_common worktree_identity project_identity expected_identity
  [ "$CROSS_CLONE_IDENTITY" -eq 1 ] || return 0
  [ -f "$META" ] && [ ! -L "$META" ] \
    || die "task metadata changed during merge verification"
  [ "$(meta_value worktree)" = "$WORKTREE" ] \
    && [ "$(meta_value project)" = "$PROJECT" ] \
    && [ "$(meta_value kind)" = "$KIND" ] \
    && [ "$(meta_value mode)" = "$MODE" ] \
    && [ "$(meta_value pr)" = "$URL" ] \
    && [ "$(meta_optional_value pr_head)" = "$recorded_head" ] \
    || die "task metadata changed during merge verification"
  require_cross_clone_project_ownership
  worktree_common=$(git_common "$WORKTREE") \
    || die "task worktree repository identity changed during merge verification"
  project_common=$(git_common "$PROJECT") \
    || die "task project repository identity changed during merge verification"
  [ "$worktree_common" = "$WORKTREE_COMMON" ] \
    && [ "$project_common" = "$PROJECT_COMMON" ] \
    || die "repository identity changed during merge verification"
  worktree_identity=$(checkout_repository_identity "$WORKTREE" "task worktree")
  project_identity=$(checkout_repository_identity "$PROJECT" "task project")
  expected_identity=$(github_repository_identity "https://github.com/$PR_OWNER/$PR_REPO.git") \
    || die "cannot resolve the requested PR repository identity"
  [ "$worktree_identity" = "$WORKTREE_REPOSITORY_IDENTITY" ] \
    && [ "$project_identity" = "$PROJECT_REPOSITORY_IDENTITY" ] \
    && [ "$worktree_identity" = "$project_identity" ] \
    && [ "$project_identity" = "$expected_identity" ] \
    || die "repository identity changed during merge verification"
}

ensure_repository_lock() {
  local common lock_path depth
  common=$(git_common "$PROJECT") || die "cannot resolve repository lock path"
  lock_path="$common/firstmate-merge.lock"
  depth=${FM_MERGE_EXECUTE_DEPTH:-0}
  case "$depth" in
    '' | *[!0-9]*) die_recursion "invalid merge-execution depth; refusing recursive entry" ;;
  esac
  if [ -n "${FM_MERGE_LOCK_FD:-}" ]; then
    [ "$depth" -eq 1 ] \
      || die_recursion "inherited repository lock has contradictory merge-execution depth; retry from a stable Firstmate home"
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
    export FM_MERGE_EXECUTE_DEPTH=2
    return
  fi
  [ "$depth" -eq 0 ] \
    || die_recursion "merge execution re-entered without its repository lock; retry from a stable Firstmate home"
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
environment["FM_MERGE_EXECUTE_DEPTH"] = "1"
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

GITHUB_GRAPHQL_PAYLOAD=
GITHUB_GRAPHQL_RAW=

# Resolve a path through symlinks so the capture boundary can identify the
# repository's installed gh shim regardless of the PATH directory that names it.
# This intentionally mirrors fm-gh-shim.sh rather than sharing a helper: the shim
# needs this resolver before it can locate its own source-relative helper scripts.
capture_resolve_path() {
  local target=$1
  if command -v realpath > /dev/null 2>&1; then
    realpath "$target" 2> /dev/null || printf '%s\n' "$target"
  else
    local dir base
    dir=$(cd "$(dirname "$target")" 2> /dev/null && pwd) || {
      printf '%s\n' "$target"
      return 0
    }
    base=$(basename "$target")
    while [ -L "$dir/$base" ]; do
      local link
      link=$(readlink "$dir/$base") || break
      case "$link" in
        /*) dir=$(cd "$(dirname "$link")" && pwd) ;;
        *) dir=$(cd "$dir" && cd "$(dirname "$link")" && pwd) ;;
      esac
      base=$(basename "$link")
    done
    printf '%s\n' "$dir/$base"
  fi
}

# The capture wrapper places a temporary gh first on PATH.  Its target must be
# the genuine gh executable, never this repository's PATH-installed shim, or the
# shim will rediscover the temporary wrapper and recurse.
capture_find_real_gh() {
  local shim_real entry candidate probe
  shim_real=$(capture_resolve_path "$SCRIPT_DIR/fm-gh-shim.sh")
  local IFS=:
  for entry in $PATH; do
    [ -n "$entry" ] || entry=.
    candidate="$entry/gh"
    [ -f "$candidate" ] && [ -x "$candidate" ] || continue
    [ "$(capture_resolve_path "$candidate")" = "$shim_real" ] && continue
    probe=
    if probe=$(FM_GH_SHIM_PROBE=1 "$candidate" --firstmate-gh-shim-probe 2> /dev/null) \
      && [ "$probe" = firstmate-gh-shim-v1 ]; then
      continue
    fi
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

capture_github_graphql() {
  local query=$1 capture_dir capture_body capture_shim real_gh old_umask output raw rc=0
  real_gh=$(capture_find_real_gh) || return 1
  old_umask=$(umask)
  umask 077
  capture_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-github-response.XXXXXX") || {
    umask "$old_umask"
    return 1
  }
  umask "$old_umask"
  capture_body=$capture_dir/body
  capture_shim=$capture_dir/gh
  if ! cat > "$capture_shim" <<'SH'
#!/usr/bin/env bash
set -o pipefail
case "${FM_GITHUB_CAPTURE_WRAPPER_DEPTH:-0}" in
  0) export FM_GITHUB_CAPTURE_WRAPPER_DEPTH=1 ;;
  *)
    echo "fm-merge-execute: GitHub capture wrapper recursion detected; selected gh re-entered PATH instead of executing the captured command" >&2
    exit 70
    ;;
esac
"$FM_GITHUB_CAPTURE_GH" "$@" | tee "$FM_GITHUB_CAPTURE_BODY"
SH
  then
    rmdir "$capture_dir" 2>/dev/null || true
    return 1
  fi
  if ! chmod 0700 "$capture_shim"; then
    rm -f "$capture_shim"
    rmdir "$capture_dir" 2>/dev/null || true
    return 1
  fi
  if output=$(FM_GITHUB_CAPTURE_GH="$real_gh" FM_GITHUB_CAPTURE_BODY="$capture_body" \
    PATH="$capture_dir:$PATH" gh-axi api POST /graphql --field "query=$query"); then
    [ -f "$capture_body" ] && raw=$(cat "$capture_body") || rc=1
  else
    rc=$?
  fi
  rm -f "$capture_body" "$capture_shim"
  rmdir "$capture_dir" 2>/dev/null || rc=1
  [ "$rc" -eq 0 ] || return "$rc"
  GITHUB_GRAPHQL_PAYLOAD=$output
  GITHUB_GRAPHQL_RAW=$raw
}

require_github_capture() {
  local query=$1 failure=$2 rc
  capture_github_graphql "$query" && return 0
  rc=$?
  [ "$rc" -ne "$RECURSION_EXIT" ] || exit "$rc"
  die "$failure"
}

decode_github_pull() {
  python3 - "$1" <<'PY'
import json
import re
import sys


class InvalidPayload(Exception):
    pass


class Pairs(list):
    pass


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise InvalidPayload
        result[key] = unique_value(value)
    return result


def unique_value(value):
    if isinstance(value, Pairs):
        return unique_object(value)
    if isinstance(value, list):
        return [unique_value(item) for item in value]
    return value


def single_value(record, key):
    if not isinstance(record, Pairs):
        raise InvalidPayload
    values = [value for candidate, value in record if candidate == key]
    if len(values) != 1:
        raise InvalidPayload
    return values[0]


def count_key(value, key):
    if isinstance(value, Pairs):
        return sum(
            (1 if candidate == key else 0) + count_key(child, key)
            for candidate, child in value
        )
    if isinstance(value, list):
        return sum(count_key(child, key) for child in value)
    return 0


def required_string(record, key):
    value = record.get(key)
    if not isinstance(value, str) or not value:
        raise InvalidPayload
    return value


try:
    raw_document = json.loads(sys.argv[1], object_pairs_hook=Pairs)
    if count_key(raw_document, "branchProtectionRule") != 1:
        raise InvalidPayload
    raw_data = single_value(raw_document, "data")
    raw_repository = single_value(raw_data, "repository")
    raw_pull = single_value(raw_repository, "pullRequest")
    raw_base_record = single_value(raw_pull, "baseRef")
    raw_protection = single_value(raw_base_record, "branchProtectionRule")
    if isinstance(raw_protection, Pairs):
        protection = unique_object(raw_protection)
        if set(protection) != {
            "requiresStrictStatusChecks",
            "isAdminEnforced",
        }:
            raise InvalidPayload
        if type(protection["requiresStrictStatusChecks"]) is not bool:
            raise InvalidPayload
        if type(protection["isAdminEnforced"]) is not bool:
            raise InvalidPayload
        print("protected")
        raise SystemExit(0)
    if raw_protection is not None:
        raise InvalidPayload
    document = unique_value(raw_document)
    if "errors" in document or set(document) != {"data"}:
        raise InvalidPayload
    data = document["data"]
    if not isinstance(data, dict) or "repository" not in data:
        raise InvalidPayload
    repository = data["repository"]
    if not isinstance(repository, dict) or "pullRequest" not in repository:
        raise InvalidPayload
    pull = repository["pullRequest"]
    if set(data) != {"repository"} or set(repository) != {"pullRequest"}:
        raise InvalidPayload
    expected = {
        "headRefOid",
        "baseRefOid",
        "baseRefName",
        "headRefName",
        "state",
        "isDraft",
        "merged",
        "headRepository",
        "baseRef",
    }
    if not isinstance(pull, dict) or set(pull) != expected:
        raise InvalidPayload
    base_record = pull["baseRef"]
    if not isinstance(base_record, dict) or set(base_record) != {"branchProtectionRule"}:
        raise InvalidPayload
    head = required_string(pull, "headRefOid")
    base = required_string(pull, "baseRefOid")
    if re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", head) is None:
        raise InvalidPayload
    if re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", base) is None:
        raise InvalidPayload
    base_ref = required_string(pull, "baseRefName")
    head_ref = required_string(pull, "headRefName")
    state = required_string(pull, "state")
    if type(pull["isDraft"]) is not bool or type(pull["merged"]) is not bool:
        raise InvalidPayload
    head_repository = pull["headRepository"]
    if not isinstance(head_repository, dict) or set(head_repository) != {"nameWithOwner"}:
        raise InvalidPayload
    head_repo = required_string(head_repository, "nameWithOwner")
except (InvalidPayload, json.JSONDecodeError, UnicodeDecodeError):
    raise SystemExit(1)

values = (
    "unprotected",
    head,
    base,
    base_ref,
    head_ref,
    state,
    str(pull["isDraft"]).lower(),
    str(pull["merged"]).lower(),
    head_repo,
    "unprotected",
    "absent",
    "absent",
)
print("\n".join(values))
PY
}

decode_github_merge_object() {
  python3 - "$1" "$2" <<'PY'
import base64
import binascii
import json
import re
import sys


class InvalidPayload(Exception):
    pass


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise InvalidPayload
        result[key] = value
    return result


def oid(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", value) is not None


try:
    lines = sys.argv[1].splitlines()
    if len(lines) != 3 or lines[0] != "api_response:" or lines[2] != "  truncated: false":
        raise InvalidPayload
    match = re.fullmatch(r"  body: ([A-Za-z0-9+/]+={0,2})", lines[1])
    if match is None:
        raise InvalidPayload
    decoded = base64.b64decode(match.group(1), validate=True)
    document = json.loads(decoded, object_pairs_hook=unique_object)
    mode = sys.argv[2]
    if mode == "result":
        if not isinstance(document, dict) or set(document) != {"merged", "sha"}:
            raise InvalidPayload
        if type(document["merged"]) is not bool or not oid(document["sha"]):
            raise InvalidPayload
        values = (str(document["merged"]).lower(), document["sha"])
    elif mode == "ref":
        if not isinstance(document, dict) or set(document) != {"sha", "type"}:
            raise InvalidPayload
        if not oid(document["sha"]) or document["type"] != "commit":
            raise InvalidPayload
        values = (document["sha"],)
    elif mode == "commit":
        if not isinstance(document, dict) or set(document) != {"sha", "parents"}:
            raise InvalidPayload
        parents = document["parents"]
        if not oid(document["sha"]) or not isinstance(parents, list) or not parents or not all(oid(parent) for parent in parents):
            raise InvalidPayload
        values = (document["sha"], *parents)
    elif mode == "compare":
        expected = {"status", "aheadBy", "behindBy", "mergeBaseOid", "firstOid", "firstParents"}
        if not isinstance(document, dict) or set(document) != expected:
            raise InvalidPayload
        parents = document["firstParents"]
        if document["status"] not in {"ahead", "identical"}:
            raise InvalidPayload
        if type(document["aheadBy"]) is not int or document["aheadBy"] < 0:
            raise InvalidPayload
        if type(document["behindBy"]) is not int or document["behindBy"] < 0:
            raise InvalidPayload
        if not oid(document["mergeBaseOid"]) or not oid(document["firstOid"]):
            raise InvalidPayload
        if not isinstance(parents, list) or not parents or not all(oid(parent) for parent in parents):
            raise InvalidPayload
        values = (
            document["status"],
            str(document["aheadBy"]),
            str(document["behindBy"]),
            document["mergeBaseOid"],
            document["firstOid"],
            *parents,
        )
    else:
        raise InvalidPayload
except (InvalidPayload, binascii.Error, json.JSONDecodeError, UnicodeDecodeError):
    raise SystemExit(1)

print("\n".join(values))
PY
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
  local query payload raw_values pull_values confirm_raw_values confirm_values head base base_ref state draft merged strict admin_enforced recorded_pr recorded_head merge_output merge_values merge_result merge_sha head_repo head_ref encoded_ref
  local confirm_head confirm_base confirm_base_ref confirm_state confirm_draft confirm_merged confirm_head_repo confirm_head_ref
  local protection_path protection_strict protection_admin
  local post_base_output post_base commit_output commit_values commit_sha commit_parent_one commit_parent_two
  local compare_output compare_values transition_status transition_ahead transition_behind transition_base transition_first transition_parent candidate_count
  local candidate_commits candidate_commit diff_status
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
  require_github_capture "$query" "cannot read the exact GitHub merge candidate"
  payload=$GITHUB_GRAPHQL_PAYLOAD
  raw_values=$(decode_github_pull "$GITHUB_GRAPHQL_RAW") \
    || die "GitHub response contained malformed or ambiguous pull request data"
  if [ "$raw_values" = protected ]; then
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
    require_repository_identity_unchanged
    merge_output=$(gh-axi api PUT "/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER/merge" --field "sha=$head" --field "merge_method=$MERGE_METHOD") || die "GitHub rejected the exact conditional merge"
    [ "$(api_value merged "$merge_output")" = true ] || die "GitHub did not merge the verified candidate"
    if [ "$DELETE_BRANCH" -eq 1 ]; then
      [ "$head_repo" = "$PR_OWNER/$PR_REPO" ] || die "PR merged, but cross-repository head deletion is unsupported"
      encoded_ref=$(urlencode_ref "$head_ref")
      gh-axi api DELETE "/repos/$PR_OWNER/$PR_REPO/git/refs/heads/$encoded_ref" >/dev/null || die "PR merged, but deleting the head branch failed"
    fi
    echo "merged exact GitHub candidate $head into $base_ref at base $base"
    return
  fi
  [ "$(printf '%s\n' "$raw_values" | sed -n '1p')" = unprotected ] \
    || die "GitHub response contained malformed or ambiguous pull request data"
  pull_values=$(printf '%s\n' "$raw_values" | sed -n '2,$p')
  head=$(printf '%s\n' "$pull_values" | sed -n '1p'); base=$(printf '%s\n' "$pull_values" | sed -n '2p')
  base_ref=$(printf '%s\n' "$pull_values" | sed -n '3p'); head_ref=$(printf '%s\n' "$pull_values" | sed -n '4p')
  state=$(printf '%s\n' "$pull_values" | sed -n '5p'); draft=$(printf '%s\n' "$pull_values" | sed -n '6p')
  merged=$(printf '%s\n' "$pull_values" | sed -n '7p'); head_repo=$(printf '%s\n' "$pull_values" | sed -n '8p')
  protection_path=$(printf '%s\n' "$pull_values" | sed -n '9p')
  protection_strict=$(printf '%s\n' "$pull_values" | sed -n '10p')
  protection_admin=$(printf '%s\n' "$pull_values" | sed -n '11p')
  # GitHub binds only the verified head at mutation; adjacent pre/post base observations attribute the result but cannot close every external-writer race.
  # This path requires Firstmate single merge authority with no concurrent uncooperative base writer.
  echo "diagnostic: GitHub reports branchProtectionRule: null; using the sanctioned unprotected repository path" >&2
  echo "diagnostic: GitHub pins the verified head but not the base; proceeding under the Firstmate single-merge-authority assumption" >&2
  [ "$state" = OPEN ] && [ "$draft" = false ] && [ "$merged" = false ] || die "GitHub pull request is not an open, mergeable candidate"
  [ -z "$recorded_head" ] || fm_pr_head_valid "$recorded_head" || die "task PR head metadata is invalid"
  [ -z "$recorded_head" ] || [ "$recorded_head" = "$head" ] || die "task PR head metadata does not match the current GitHub head"
  [ "$(git -C "$WORKTREE" rev-parse HEAD)" = "$head" ] || die "task worktree HEAD does not match the current GitHub PR head"
  git -C "$WORKTREE" cat-file -e "$base^{commit}" 2>/dev/null || git -C "$WORKTREE" fetch --quiet "https://github.com/$PR_OWNER/$PR_REPO.git" "$base"
  git -C "$WORKTREE" merge-base --is-ancestor "$base" "$head" || die "GitHub PR head does not contain the current base; update the branch and retry"
  "$SCRIPT_DIR/fm-test-inventory.sh" merge-check "$WORKTREE" "$head" "$base"
  require_github_capture "$query" "cannot confirm the exact GitHub merge candidate"
  confirm_raw_values=$(decode_github_pull "$GITHUB_GRAPHQL_RAW") \
    || die "GitHub response contained malformed or ambiguous pull request data"
  [ "$(printf '%s\n' "$confirm_raw_values" | sed -n '1p')" = unprotected ] \
    || die "GitHub pull request identity or exact candidate changed during merge verification"
  confirm_values=$(printf '%s\n' "$confirm_raw_values" | sed -n '2,$p')
  confirm_head=$(printf '%s\n' "$confirm_values" | sed -n '1p'); confirm_base=$(printf '%s\n' "$confirm_values" | sed -n '2p')
  confirm_base_ref=$(printf '%s\n' "$confirm_values" | sed -n '3p'); confirm_head_ref=$(printf '%s\n' "$confirm_values" | sed -n '4p')
  confirm_state=$(printf '%s\n' "$confirm_values" | sed -n '5p'); confirm_draft=$(printf '%s\n' "$confirm_values" | sed -n '6p')
  confirm_merged=$(printf '%s\n' "$confirm_values" | sed -n '7p'); confirm_head_repo=$(printf '%s\n' "$confirm_values" | sed -n '8p')
  [ "$confirm_head" = "$head" ] && [ "$confirm_base" = "$base" ] \
    && [ "$confirm_base_ref" = "$base_ref" ] && [ "$confirm_head_ref" = "$head_ref" ] \
    && [ "$confirm_head_repo" = "$head_repo" ] && [ "$confirm_state" = "$state" ] \
    && [ "$confirm_draft" = "$draft" ] && [ "$confirm_merged" = "$merged" ] \
    && [ "$(printf '%s\n' "$confirm_values" | sed -n '9p')" = "$protection_path" ] \
    && [ "$(printf '%s\n' "$confirm_values" | sed -n '10p')" = "$protection_strict" ] \
    && [ "$(printf '%s\n' "$confirm_values" | sed -n '11p')" = "$protection_admin" ] \
    || die "GitHub pull request identity or exact candidate changed during merge verification"
  require_clean "$WORKTREE" "task worktree"
  require_clean "$PROJECT" "project checkout"
  [ "$(git -C "$WORKTREE" rev-parse HEAD)" = "$head" ] || die "task worktree HEAD changed during merge verification"
  if [ "$MERGE_METHOD" = rebase ]; then
    candidate_commits=$(git -C "$WORKTREE" rev-list --reverse "$base..$head") \
      || die "cannot inspect the verified GitHub rebase candidate"
    while IFS= read -r candidate_commit; do
      [ -n "$candidate_commit" ] || continue
      if git -C "$WORKTREE" diff-tree --quiet "$candidate_commit^" "$candidate_commit" --; then
        die "unprotected GitHub rebase does not support originally empty candidate commits"
      else
        diff_status=$?
        [ "$diff_status" -eq 1 ] || die "cannot inspect the verified GitHub rebase candidate"
      fi
    done <<EOF
$candidate_commits
EOF
  fi
  require_repository_identity_unchanged
  merge_output=$(gh-axi api PUT "/repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER/merge" --field "sha=$head" --field "merge_method=$MERGE_METHOD" --jq '{merged: .merged, sha: .sha} | @base64') \
    || die "GitHub rejected the exact conditional merge"
  merge_values=$(decode_github_merge_object "$merge_output" result) || die "GitHub returned malformed merge confirmation data"
  merge_result=$(printf '%s\n' "$merge_values" | sed -n '1p')
  merge_sha=$(printf '%s\n' "$merge_values" | sed -n '2p')
  [ "$merge_result" = true ] || die "GitHub did not merge the verified candidate"
  encoded_ref=$(urlencode_ref "$base_ref")
  post_base_output=$(gh-axi api GET "/repos/$PR_OWNER/$PR_REPO/git/ref/heads/$encoded_ref" --jq '{sha: .object.sha, type: .object.type} | @base64') \
    || die "cannot observe the post-mutation GitHub base"
  post_base=$(decode_github_merge_object "$post_base_output" ref) || die "GitHub returned malformed post-mutation base data"
  [ "$post_base" = "$merge_sha" ] || die "post-mutation base transition was not attributable to the verified candidate and merge result"
  commit_output=$(gh-axi api GET "/repos/$PR_OWNER/$PR_REPO/git/commits/$merge_sha" --jq '{sha: .sha, parents: [.parents[].sha]} | @base64') \
    || die "cannot inspect the post-mutation GitHub merge result"
  commit_values=$(decode_github_merge_object "$commit_output" commit) || die "GitHub returned malformed post-mutation merge result data"
  commit_sha=$(printf '%s\n' "$commit_values" | sed -n '1p')
  commit_parent_one=$(printf '%s\n' "$commit_values" | sed -n '2p')
  commit_parent_two=$(printf '%s\n' "$commit_values" | sed -n '3p')
  [ "$commit_sha" = "$merge_sha" ] || die "post-mutation base transition was not attributable to the verified candidate and merge result"
  case "$MERGE_METHOD" in
    merge)
      [ "$commit_parent_one" = "$base" ] && [ "$commit_parent_two" = "$head" ] \
        && [ "$(printf '%s\n' "$commit_values" | wc -l | tr -d ' ')" -eq 3 ] \
        || die "post-mutation base transition was not attributable to the verified candidate and merge result"
      ;;
    squash)
      [ "$commit_parent_one" = "$base" ] && [ -z "$commit_parent_two" ] \
        || die "post-mutation base transition was not attributable to the verified candidate and merge result"
      ;;
    rebase)
      [ -n "$commit_parent_one" ] && [ -z "$commit_parent_two" ] \
        || die "post-mutation base transition was not attributable to the verified candidate and merge result"
      candidate_count=$(git -C "$WORKTREE" rev-list --count "$base..$head") \
        || die "cannot count the verified GitHub candidate commits"
      compare_output=$(gh-axi api GET "/repos/$PR_OWNER/$PR_REPO/compare/$base...$merge_sha?per_page=1&page=1" --jq '{status: .status, aheadBy: .ahead_by, behindBy: .behind_by, mergeBaseOid: .merge_base_commit.sha, firstOid: .commits[0].sha, firstParents: [.commits[0].parents[].sha]} | @base64') \
        || die "cannot attribute the rebased GitHub merge result"
      compare_values=$(decode_github_merge_object "$compare_output" compare) || die "GitHub returned malformed rebased transition data"
      transition_status=$(printf '%s\n' "$compare_values" | sed -n '1p')
      transition_ahead=$(printf '%s\n' "$compare_values" | sed -n '2p')
      transition_behind=$(printf '%s\n' "$compare_values" | sed -n '3p')
      transition_base=$(printf '%s\n' "$compare_values" | sed -n '4p')
      transition_first=$(printf '%s\n' "$compare_values" | sed -n '5p')
      transition_parent=$(printf '%s\n' "$compare_values" | sed -n '6p')
      [ "$transition_status" = ahead ] && [ "$transition_ahead" -eq "$candidate_count" ] \
        && [ "$transition_behind" -eq 0 ] && [ "$transition_base" = "$base" ] \
        && [ -n "$transition_first" ] && [ "$transition_parent" = "$base" ] \
        && [ "$(printf '%s\n' "$compare_values" | wc -l | tr -d ' ')" -eq 6 ] \
        || die "post-mutation base transition was not attributable to the verified candidate and merge result"
      ;;
  esac
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
