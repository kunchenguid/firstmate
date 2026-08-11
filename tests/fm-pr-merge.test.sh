#!/usr/bin/env bash
# Behavior tests for the shared exact-candidate merge execution boundary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_EXECUTE="$ROOT/bin/fm-merge-execute.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge)

make_case() {
  local name=$1 case_dir base candidate
  case_dir=$TMP_ROOT/$name
  mkdir -p "$case_dir/state"
  fm_git_worktree "$case_dir/project" "$case_dir/wt" fm/task-x1
  git -C "$case_dir/project" branch -M main
  mkdir -p "$case_dir/wt/.firstmate" "$case_dir/wt/tests"
  cat > "$case_dir/wt/.firstmate/test-inventory.json" <<'EOF'
{"schema_version":1,"status":"test-bearing","baseline":{"version":1,"declarations":1,"test_files":1},"maximum_unreviewed_deletion":0}
EOF
  cat > "$case_dir/wt/tests/test_receipt.py" <<'EOF'
def test_literal():
    pass
EOF
  git -C "$case_dir/wt" add .firstmate tests
  "$ROOT/bin/fm-test-inventory.sh" collect "$case_dir/wt" >/dev/null
  git -C "$case_dir/wt" add .firstmate/test-inventory-receipt.json
  git -C "$case_dir/wt" commit -qm inventory
  git -C "$case_dir/project" merge --ff-only fm/task-x1 >/dev/null
  base=$(git -C "$case_dir/project" rev-parse main)
  printf 'candidate\n' > "$case_dir/wt/change.txt"
  git -C "$case_dir/wt" add change.txt
  git -C "$case_dir/wt" commit -qm candidate
  candidate=$(git -C "$case_dir/wt" rev-parse HEAD)
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=local-only"
  printf '%s\n%s\n%s\n' "$case_dir" "$base" "$candidate"
}

make_secondmate_cross_clone_case() {
  local name=$1 shape=${2:-projectless} values case_dir base candidate secondmate_home secondmate_project state_dir
  values=$(make_case "$name")
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  secondmate_home="$case_dir/secondmate-home"
  case "$shape" in
    projectless)
      secondmate_project=$secondmate_home
      ;;
    provisioned)
      secondmate_project="$secondmate_home/projects/repo"
      mkdir -p "$(dirname "$secondmate_project")"
      ;;
    *) fail "unknown secondmate fixture shape: $shape" ;;
  esac
  git clone --quiet "$case_dir/project" "$secondmate_project"
  state_dir="$secondmate_home/state"
  mkdir -p "$state_dir"
  if [ "$shape" = projectless ]; then
    printf '/state/\n' >> "$secondmate_home/.git/info/exclude"
  fi
  git -C "$case_dir/project" remote add origin https://github.com/example/repo.git
  git -C "$secondmate_project" remote set-url origin git@github.com:example/repo.git
  fm_write_meta "$state_dir/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$secondmate_project" \
    "kind=ship" \
    "mode=direct-PR"
  printf '%s\n%s\n%s\n%s\n%s\n' "$case_dir" "$base" "$candidate" "$secondmate_project" "$state_dir"
}

run_local_merge() {
  local case_dir=$1 state_dir
  state_dir=${FM_TEST_CASE_STATE:-$case_dir/state}
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state_dir" "$MERGE_EXECUTE" local task-x1
}

run_local_merge_with_path() {
  local case_dir=$1 fakebin=$2 real_git=$3
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_RACE_PROJECT="$case_dir/project" FM_TEST_REAL_GIT="$real_git" \
    PATH="$fakebin:$PATH" "$MERGE_EXECUTE" local task-x1
}

add_github_mocks() {
  local case_dir=$1
  mkdir -p "$case_dir/fakebin"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
[ "${1:-}" = api ] || exit 2
shift
method=GET
case "${1:-}" in
  GET | POST | PUT | PATCH | DELETE | HEAD)
    method=$1
    shift
    ;;
esac
[ "$#" -ge 1 ] || exit 2
endpoint=$1
shift
gh_args=(api "$endpoint" --method "$method")
while [ "$#" -gt 0 ]; do
  case "$1" in
    --field | --header | --jq | --template)
      [ "$#" -ge 2 ] || exit 2
      gh_args+=("$1" "$2")
      shift 2
      ;;
    --field=* | --header=* | --jq=* | --template=* | --paginate)
      gh_args+=("$1")
      shift
      ;;
    *) exit 2 ;;
  esac
done
raw=$(gh "${gh_args[@]}") || exit $?
python3 - "$raw" <<'PY'
import json
import re
import sys


def scalar(value):
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, (int, float)):
        return json.dumps(value, separators=(",", ":"))
    if (
        not value
        or value in {"true", "false", "null"}
        or re.fullmatch(r"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?", value)
        or re.fullmatch(r"[A-Za-z0-9_./+=-]+", value) is None
    ):
        return json.dumps(value, ensure_ascii=False)
    return value


def emit_mapping(value, depth=0):
    prefix = "  " * depth
    for key, child in value.items():
        if isinstance(child, dict):
            print(f"{prefix}{key}:")
            emit_mapping(child, depth + 1)
        elif isinstance(child, list):
            if all(not isinstance(item, (dict, list)) for item in child):
                rendered = ",".join(scalar(item) for item in child)
                print(f"{prefix}{key}[{len(child)}]: {rendered}")
            else:
                print(f"{prefix}{key}: {scalar(json.dumps(child, separators=(',', ':')))}")
        else:
            print(f"{prefix}{key}: {scalar(child)}")


raw = sys.argv[1]
try:
    document = json.loads(raw)
except json.JSONDecodeError:
    body = raw.strip()
    print("api_response:")
    print(f"  body: {scalar(body[:4000])}")
    print(f"  truncated: {'true' if len(body) > 4000 else 'false'}")
    if len(body) > 4000:
        print(f"  original_length: {len(body)}")
else:
    if isinstance(document, dict):
        emit_mapping(document)
    else:
        print(scalar(document))
PY
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "api /graphql")
    post_count=$(grep -c '^api POST ' "$FM_TEST_GH_AXI_LOG")
    api_head=$FM_TEST_GH_API_HEAD
    api_base=$FM_TEST_GH_BASE
    protection=${FM_TEST_GH_PROTECTION:-protected}
    if [ "$post_count" -eq 1 ] && [ -n "${FM_TEST_GH_IDENTITY_RACE_PROJECT:-}" ]; then
      git -C "$FM_TEST_GH_IDENTITY_RACE_PROJECT" remote set-url origin "$FM_TEST_GH_IDENTITY_RACE_URL"
    fi
    if [ "$post_count" -gt 1 ]; then
      api_head=${FM_TEST_GH_API_HEAD_AFTER:-$api_head}
      api_base=${FM_TEST_GH_BASE_AFTER:-$api_base}
      protection=${FM_TEST_GH_PROTECTION_AFTER:-$protection}
    fi
    python3 - "$api_head" "$api_base" "$protection" <<'PY'
import json
import sys

head, base, mode = sys.argv[1:]
pull = {
    "headRefOid": head,
    "baseRefOid": base,
    "baseRefName": "main",
    "headRefName": "fm/task-x1",
    "state": "OPEN",
    "isDraft": False,
    "merged": False,
    "headRepository": {"nameWithOwner": "example/repo"},
    "baseRef": {},
}
if mode == "protected":
    rule = {"requiresStrictStatusChecks": True, "isAdminEnforced": True}
elif mode in {"null", "malformed-occurrence", "graphql-error-null"}:
    rule = None
elif mode == "partial":
    rule = {"requiresStrictStatusChecks": True}
elif mode == "non-strict":
    rule = {"requiresStrictStatusChecks": False, "isAdminEnforced": True}
elif mode == "scalar":
    rule = "null"
elif mode == "absent":
    rule = ...
elif mode == "misplaced":
    rule = ...
    pull["branchProtectionRule"] = None
elif mode == "null-child":
    rule = None
    pull["baseRef"]["requiresStrictStatusChecks"] = True
elif mode in {"duplicate-null", "duplicate-strict", "duplicate-admin"}:
    rule = None if mode == "duplicate-null" else {
        "requiresStrictStatusChecks": True,
        "isAdminEnforced": True,
    }
else:
    raise SystemExit(97)
if rule is not ...:
    pull["baseRef"]["branchProtectionRule"] = rule
document = {"data": {"repository": {"pullRequest": pull}}}
if mode == "graphql-error-null":
    document["errors"] = [{"message": "branch protection resolver failed"}]
raw = json.dumps(document, separators=(",", ":"))
if mode == "duplicate-null":
    raw = raw.replace(
        '"branchProtectionRule":null',
        '"branchProtectionRule":null,"branchProtectionRule":null',
    )
elif mode == "duplicate-strict":
    raw = raw.replace(
        '"requiresStrictStatusChecks":true',
        '"requiresStrictStatusChecks":true,"requiresStrictStatusChecks":true',
    )
elif mode == "duplicate-admin":
    raw = raw.replace(
        '"isAdminEnforced":true',
        '"isAdminEnforced":true,"isAdminEnforced":true',
    )
elif mode == "malformed-occurrence":
    raw = raw.replace('"baseRef":{', '"branchProtectionRule":null,"baseRef":{')
print(raw)
PY
    ;;
  api\ *)
    method=GET
    previous=
    for argument in "$@"; do
      if [ "$previous" = --method ]; then
        method=$argument
        break
      fi
      previous=$argument
    done
    endpoint=${2:-}
    case "$method $endpoint" in
      PUT\ */pulls/*/merge)
        [ -z "${FM_TEST_GH_BASE_AT_MUTATION:-}" ] \
          || printf 'mutation base: %s\n' "$FM_TEST_GH_BASE_AT_MUTATION" >> "$FM_TEST_GH_AXI_LOG"
        python3 - "${FM_TEST_GH_MERGED:-true}" "$FM_TEST_GH_MERGE_SHA" "$*" <<'PY'
import base64
import json
import sys

merged, sha, arguments = sys.argv[1:]
if merged not in {"true", "false"}:
    raise SystemExit(98)
raw = json.dumps({"merged": merged == "true", "sha": sha}, separators=(",", ":"))
print(base64.b64encode(raw.encode()).decode() if " --jq " in f" {arguments} " else raw)
PY
        ;;
      */git/ref/heads/*)
        python3 - "$FM_TEST_GH_MERGE_SHA" <<'PY'
import base64
import json
import sys

raw = json.dumps({"sha": sys.argv[1], "type": "commit"}, separators=(",", ":"))
print(base64.b64encode(raw.encode()).decode())
PY
        ;;
      */git/commits/*)
        python3 - "$FM_TEST_GH_MERGE_SHA" "${FM_TEST_GH_BASE_AT_MUTATION:-$FM_TEST_GH_BASE}" "$FM_TEST_GH_API_HEAD" "$FM_TEST_GH_METHOD" <<'PY'
import base64
import json
import sys

sha, base, head, method = sys.argv[1:]
parents = [base] if method in {"rebase", "squash"} else [base, head]
raw = json.dumps({"sha": sha, "parents": parents}, separators=(",", ":"))
print(base64.b64encode(raw.encode()).decode())
PY
        ;;
      */compare/*)
        python3 - "${FM_TEST_GH_REBASE_AHEAD:-1}" "${FM_TEST_GH_REBASE_FIRST:-$FM_TEST_GH_MERGE_SHA}" "$FM_TEST_GH_BASE" <<'PY'
import base64
import json
import sys

ahead, first, base = sys.argv[1:]
raw = json.dumps(
    {
        "status": "ahead",
        "aheadBy": int(ahead),
        "behindBy": 0,
        "mergeBaseOid": base,
        "firstOid": first,
        "firstParents": [base],
    },
    separators=(",", ":"),
)
print(base64.b64encode(raw.encode()).decode())
PY
        ;;
      DELETE\ *) ;;
      *) exit 99 ;;
    esac
    ;;
  *) exit 99 ;;
esac
SH
  chmod +x "$case_dir/fakebin/gh" "$case_dir/fakebin/gh-axi"
  : > "$case_dir/gh-axi.log"
}

run_github_merge() {
  local case_dir=$1 head=$2 api_head=$3 base=$4 method=${5:-merge} path_prefix=${6:-}
  local state_dir=${FM_TEST_CASE_STATE:-$case_dir/state}
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state_dir" \
    FM_TEST_GH_HEAD="$head" FM_TEST_GH_API_HEAD="$api_head" FM_TEST_GH_BASE="$base" \
    FM_TEST_GH_API_HEAD_AFTER="${FM_TEST_GH_API_HEAD_AFTER:-}" \
    FM_TEST_GH_BASE_AFTER="${FM_TEST_GH_BASE_AFTER:-}" \
    FM_TEST_GH_PROTECTION="${FM_TEST_GH_PROTECTION:-protected}" \
    FM_TEST_GH_PROTECTION_AFTER="${FM_TEST_GH_PROTECTION_AFTER:-}" \
    FM_TEST_GH_BASE_AT_MUTATION="${FM_TEST_GH_BASE_AT_MUTATION:-}" \
    FM_TEST_GH_MERGE_SHA=9999999999999999999999999999999999999999 \
    FM_TEST_GH_MERGED="${FM_TEST_GH_MERGED:-true}" \
    FM_TEST_GH_METHOD="$method" \
    FM_TEST_GH_REBASE_AHEAD="${FM_TEST_GH_REBASE_AHEAD:-}" \
    FM_TEST_GH_REBASE_FIRST="${FM_TEST_GH_REBASE_FIRST:-}" \
    FM_TEST_GH_IDENTITY_RACE_PROJECT="${FM_TEST_GH_IDENTITY_RACE_PROJECT:-}" \
    FM_TEST_GH_IDENTITY_RACE_URL="${FM_TEST_GH_IDENTITY_RACE_URL:-}" \
    FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" PATH="$path_prefix$case_dir/fakebin:$PATH" \
    "$PR_MERGE" task-x1 https://github.com/example/repo/pull/9 -- "--$method"
}

run_github_execute() {
  local case_dir=$1 head=$2 api_head=$3 base=$4 method=${5:-merge} path_prefix=${6:-}
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_GH_HEAD="$head" FM_TEST_GH_API_HEAD="$api_head" FM_TEST_GH_BASE="$base" \
    FM_TEST_GH_API_HEAD_AFTER="${FM_TEST_GH_API_HEAD_AFTER:-}" \
    FM_TEST_GH_BASE_AFTER="${FM_TEST_GH_BASE_AFTER:-}" \
    FM_TEST_GH_PROTECTION="${FM_TEST_GH_PROTECTION:-protected}" \
    FM_TEST_GH_PROTECTION_AFTER="${FM_TEST_GH_PROTECTION_AFTER:-}" \
    FM_TEST_GH_BASE_AT_MUTATION="${FM_TEST_GH_BASE_AT_MUTATION:-}" \
    FM_TEST_GH_MERGE_SHA=9999999999999999999999999999999999999999 \
    FM_TEST_GH_MERGED="${FM_TEST_GH_MERGED:-true}" \
    FM_TEST_GH_METHOD="$method" \
    FM_TEST_GH_REBASE_AHEAD="${FM_TEST_GH_REBASE_AHEAD:-}" \
    FM_TEST_GH_REBASE_FIRST="${FM_TEST_GH_REBASE_FIRST:-}" \
    FM_TEST_GH_IDENTITY_RACE_PROJECT="${FM_TEST_GH_IDENTITY_RACE_PROJECT:-}" \
    FM_TEST_GH_IDENTITY_RACE_URL="${FM_TEST_GH_IDENTITY_RACE_URL:-}" \
    FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" PATH="$path_prefix$case_dir/fakebin:$PATH" \
    "$MERGE_EXECUTE" github task-x1 https://github.com/example/repo/pull/9 -- "--$method"
}

test_exact_literal_receipt_lands_candidate() {
  local values case_dir base candidate
  values=$(make_case exact)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  run_local_merge "$case_dir" >/dev/null || fail "shared boundary refused an exact literal receipt"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$candidate" ] || fail "boundary did not land the exact candidate SHA"
  [ "$base" != "$candidate" ] || fail "fixture did not create a distinct candidate SHA"
  pass "shared boundary verifies and lands the exact literal-source candidate"
}

test_uncommitted_receipt_source_refuses_before_merge() {
  local values case_dir before rc
  values=$(make_case dirty-source)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  before=$(git -C "$case_dir/project" rev-parse main)
  printf 'def test_uncommitted():\n    pass\n' >> "$case_dir/wt/tests/test_receipt.py"
  set +e
  run_local_merge "$case_dir" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "dirty candidate source must refuse exact merge verification"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$before" ] || fail "boundary merged after receipt source changed"
  grep -q 'task worktree is dirty' "$case_dir/err" || fail "dirty receipt refusal was unclear"
  pass "shared boundary preserves the base when literal source changes after receipt generation"
}

test_raced_local_edit_is_preserved() {
  local values case_dir base fakebin real_git rc
  values=$(make_case raced-edit)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  fakebin="$case_dir/fakebin"
  real_git=$(command -v git)
  mkdir -p "$fakebin"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -C ] && [ "${2:-}" = "$FM_TEST_RACE_PROJECT" ] && [[ " $* " = *" merge --ff-only "* ]]; then
  printf 'raced local edit\n' > "$FM_TEST_RACE_PROJECT/change.txt"
fi
exec "$FM_TEST_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
  set +e
  run_local_merge_with_path "$case_dir" "$fakebin" "$real_git" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "a raced project edit must refuse local landing"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$base" ] || fail "raced edit advanced the default ref"
  [ "$(cat "$case_dir/project/change.txt")" = 'raced local edit' ] || fail "raced edit was discarded"
  pass "local merge preserves an edit raced into the checkout"
}

test_intervening_base_movement_is_refused() {
  local values case_dir base intervening candidate fakebin real_git rc
  values=$(make_case raced-base)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  intervening=$(printf '%s\n' "$values" | sed -n '3p')
  printf 'final candidate\n' > "$case_dir/wt/final.txt"
  git -C "$case_dir/wt" add final.txt
  git -C "$case_dir/wt" commit -qm final-candidate
  candidate=$(git -C "$case_dir/wt" rev-parse HEAD)
  fakebin="$case_dir/fakebin"
  real_git=$(command -v git)
  mkdir -p "$fakebin"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -C ] && [ "${2:-}" = "$FM_TEST_RACE_PROJECT" ] && [[ " $* " = *" merge --ff-only "* ]]; then
  "$FM_TEST_REAL_GIT" -C "$FM_TEST_RACE_PROJECT" update-ref refs/heads/main "$FM_TEST_INTERVENING" "$FM_TEST_BASE"
fi
exec "$FM_TEST_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
  set +e
  FM_TEST_BASE="$base" FM_TEST_INTERVENING="$intervening" \
    run_local_merge_with_path "$case_dir" "$fakebin" "$real_git" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "intervening base movement must refuse local landing"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$intervening" ] || fail "boundary overwrote intervening base movement"
  [ "$(git -C "$case_dir/wt" rev-parse HEAD)" = "$candidate" ] || fail "fixture lost the final candidate"
  [ ! -e "$case_dir/project/final.txt" ] || fail "refused base race changed the project checkout"
  pass "local merge refuses an intervening base before checkout transition"
}

test_unchanged_path_drift_is_preserved() {
  local values case_dir base fakebin real_git rc
  values=$(make_case unchanged-path-drift)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  fakebin="$case_dir/fakebin"
  real_git=$(command -v git)
  mkdir -p "$fakebin"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -C ] && [ "${2:-}" = "$FM_TEST_RACE_PROJECT" ] && [[ " $* " = *" merge --ff-only "* ]]; then
  printf 'raced unchanged path\n' > "$FM_TEST_RACE_PROJECT/README.md"
fi
exec "$FM_TEST_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
  set +e
  run_local_merge_with_path "$case_dir" "$fakebin" "$real_git" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "unchanged-path drift must refuse local landing"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$base" ] || fail "unchanged-path drift advanced the default ref"
  [ "$(cat "$case_dir/project/README.md")" = 'raced unchanged path' ] || fail "unchanged-path drift was discarded"
  [ ! -e "$case_dir/project/change.txt" ] || fail "refused unchanged-path drift retained candidate checkout changes"
  pass "local merge preserves unchanged-path drift and refuses landing"
}

test_prepared_transaction_drift_is_preserved() {
  local values case_dir base hooks rc
  values=$(make_case prepared-drift)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  hooks=$(git -C "$case_dir/project" rev-parse --path-format=absolute --git-path hooks)
  cat > "$hooks/reference-transaction" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = prepared ]; then
  while read -r _old _new ref; do
    if [ "$ref" = refs/heads/main ]; then
      printf 'raced after checkout observation\n' > "$FM_TEST_LATE_PROJECT/change.txt"
    fi
  done
fi
SH
  chmod +x "$hooks/reference-transaction"
  set +e
  FM_TEST_LATE_PROJECT="$case_dir/project" run_local_merge "$case_dir" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "prepared-transaction drift must refuse local landing"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$base" ] || fail "prepared drift advanced the default ref"
  [ "$(cat "$case_dir/project/change.txt")" = 'raced after checkout observation' ] || fail "prepared drift was discarded"
  [ "$(git -C "$case_dir/project" status --short)" = '?? change.txt' ] || fail "prepared drift did not leave the base checkout coherent"
  pass "prepared transaction drift is preserved before the ref commits"
}

test_wrong_branch_transaction_is_refused() {
  local values case_dir base fakebin real_git rc
  values=$(make_case wrong-branch)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  git -C "$case_dir/project" branch other "$base"
  fakebin="$case_dir/fakebin"
  real_git=$(command -v git)
  mkdir -p "$fakebin"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -C ] && [ "${2:-}" = "$FM_TEST_RACE_PROJECT" ] && [[ " $* " = *" merge --ff-only "* ]]; then
  "$FM_TEST_REAL_GIT" -C "$FM_TEST_RACE_PROJECT" symbolic-ref HEAD refs/heads/other
fi
exec "$FM_TEST_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
  set +e
  run_local_merge_with_path "$case_dir" "$fakebin" "$real_git" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "a wrong-branch transaction must refuse local landing"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$base" ] || fail "wrong-branch transaction advanced the default ref"
  [ "$(git -C "$case_dir/project" rev-parse other)" = "$base" ] || fail "wrong-branch transaction advanced the other ref"
  [ "$(git -C "$case_dir/project" symbolic-ref HEAD)" = refs/heads/other ] || fail "boundary overwrote the raced branch switch"
  [ ! -e "$case_dir/project/change.txt" ] || fail "refused wrong-branch transaction retained candidate checkout changes"
  [ -z "$(git -C "$case_dir/project" status --short)" ] || fail "refused wrong-branch transaction left an incoherent checkout"
  pass "local merge refuses a transaction for an unexpected branch"
}

test_github_merge_uses_verified_exact_sha() {
  local values case_dir base candidate
  values=$(make_case github-exact)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"
  add_github_mocks "$case_dir"
  run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >/dev/null \
    || fail "GitHub boundary refused the verified candidate"
  grep -qxF "api PUT /repos/example/repo/pulls/9/merge --field sha=$candidate --field merge_method=merge" "$case_dir/gh-axi.log" \
    || fail "GitHub boundary did not condition the merge on the verified exact SHA"
  [ "$(grep -c '^api POST ' "$case_dir/gh-axi.log")" -eq 1 ] \
    || fail "protected GitHub merge changed the legacy request sequence"
  pass "GitHub merge conditions its REST request on the verified candidate SHA"
}

test_secondmate_cross_clone_github_merge_accepts_same_repository() {
  local values case_dir base candidate secondmate_project state_dir pooled_common home_common
  values=$(make_secondmate_cross_clone_case secondmate-cross-clone-projectless)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  secondmate_project=$(printf '%s\n' "$values" | sed -n '4p')
  state_dir=$(printf '%s\n' "$values" | sed -n '5p')
  [ "$secondmate_project" = "$(dirname "$state_dir")" ] \
    || fail "project-less fixture did not name the secondmate home root as project metadata"
  grep -qxF "project=$secondmate_project" "$state_dir/task-x1.meta" \
    || fail "project-less fixture did not reproduce the handed-off project metadata"
  pooled_common=$(git -C "$case_dir/wt" rev-parse --path-format=absolute --git-common-dir)
  home_common=$(git -C "$secondmate_project" rev-parse --path-format=absolute --git-common-dir)
  [ "$pooled_common" != "$home_common" ] \
    || fail "project-less fixture did not exercise the cross-clone repository refusal"
  add_github_mocks "$case_dir"
  FM_TEST_CASE_STATE="$state_dir" \
    run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >"$case_dir/out" 2>"$case_dir/err" \
    || fail "guarded merge refused the project-less secondmate home and equivalent pooled worktree: $(cat "$case_dir/err")"
  grep -qxF "api PUT /repos/example/repo/pulls/9/merge --field sha=$candidate --field merge_method=merge" "$case_dir/gh-axi.log" \
    || fail "cross-clone merge did not retain the exact-candidate mutation"
  pass "guarded merge accepts the project-less secondmate home and pooled worktree for the same repository"
}

test_provisioned_secondmate_cross_clone_github_merge_accepts_same_repository() {
  local values case_dir base candidate secondmate_project state_dir
  values=$(make_secondmate_cross_clone_case secondmate-cross-clone-provisioned provisioned)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  secondmate_project=$(printf '%s\n' "$values" | sed -n '4p')
  state_dir=$(printf '%s\n' "$values" | sed -n '5p')
  add_github_mocks "$case_dir"
  FM_TEST_CASE_STATE="$state_dir" \
    run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >"$case_dir/out" 2>"$case_dir/err" \
    || fail "guarded merge refused an equivalent provisioned secondmate clone: $(cat "$case_dir/err")"
  grep -qxF "api PUT /repos/example/repo/pulls/9/merge --field sha=$candidate --field merge_method=merge" "$case_dir/gh-axi.log" \
    || fail "provisioned cross-clone merge did not retain the exact-candidate mutation"
  [ "$(dirname "$secondmate_project")" = "$(dirname "$state_dir")/projects" ] \
    || fail "provisioned fixture did not use the seeded project path contract"
  pass "guarded merge accepts an immediate provisioned project clone for the same repository"
}

test_cross_clone_merge_refuses_different_repositories() {
  local values case_dir base candidate secondmate_project state_dir variant rc
  for variant in similar-repository same-name-other-owner similar-host qualified-url; do
    values=$(make_secondmate_cross_clone_case "cross-clone-$variant")
    case_dir=$(printf '%s\n' "$values" | sed -n '1p')
    base=$(printf '%s\n' "$values" | sed -n '2p')
    candidate=$(printf '%s\n' "$values" | sed -n '3p')
    secondmate_project=$(printf '%s\n' "$values" | sed -n '4p')
    state_dir=$(printf '%s\n' "$values" | sed -n '5p')
    case "$variant" in
      similar-repository)
        git -C "$secondmate_project" remote set-url origin https://github.com/example/repo-tools.git
        ;;
      same-name-other-owner)
        git -C "$secondmate_project" remote set-url origin https://github.com/example-tools/repo.git
        ;;
      similar-host)
        git -C "$secondmate_project" remote set-url origin https://github.com.example/example/repo.git
        ;;
      qualified-url)
        git -C "$secondmate_project" remote set-url origin 'https://github.com/example/repo.git?mirror'
        ;;
    esac
    git -C "$secondmate_project" remote add lookalike https://github.com/example/repo.git
    add_github_mocks "$case_dir"
    set +e
    FM_TEST_CASE_STATE="$state_dir" \
      run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >"$case_dir/out" 2>"$case_dir/err"
    rc=$?
    set -e
    expect_code 1 "$rc" "$variant cross-clone identity must refuse merging"
    ! grep -q '^api PUT ' "$case_dir/gh-axi.log" \
      || fail "$variant cross-clone identity reached the merge mutation"
  done
  pass "cross-clone merge refuses similar paths, owners, hosts, qualified URLs, and non-origin evidence"
}

test_cross_clone_merge_refuses_missing_or_ambiguous_identity() {
  local values case_dir base candidate secondmate_project state_dir variant rc
  for variant in missing ambiguous; do
    values=$(make_secondmate_cross_clone_case "cross-clone-$variant-identity")
    case_dir=$(printf '%s\n' "$values" | sed -n '1p')
    base=$(printf '%s\n' "$values" | sed -n '2p')
    candidate=$(printf '%s\n' "$values" | sed -n '3p')
    secondmate_project=$(printf '%s\n' "$values" | sed -n '4p')
    state_dir=$(printf '%s\n' "$values" | sed -n '5p')
    if [ "$variant" = missing ]; then
      git -C "$secondmate_project" remote remove origin
      git -C "$secondmate_project" remote add upstream https://github.com/example/repo.git
    else
      git -C "$secondmate_project" config --add remote.origin.url https://github.com/example/repo.git
    fi
    add_github_mocks "$case_dir"
    set +e
    FM_TEST_CASE_STATE="$state_dir" \
      run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >"$case_dir/out" 2>"$case_dir/err"
    rc=$?
    set -e
    expect_code 1 "$rc" "$variant cross-clone identity must refuse merging"
    assert_grep 'canonical repository identity is missing or ambiguous' "$case_dir/err" \
      "$variant cross-clone identity refusal was unclear"
    ! grep -q '^api PUT ' "$case_dir/gh-axi.log" \
      || fail "$variant cross-clone identity reached the merge mutation"
  done
  pass "cross-clone merge refuses missing and ambiguous canonical origin identity"
}

test_cross_clone_merge_refuses_stale_home_metadata() {
  local values case_dir base candidate state_dir stale_project rc
  values=$(make_secondmate_cross_clone_case cross-clone-stale-home)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  state_dir=$(printf '%s\n' "$values" | sed -n '5p')
  stale_project="$case_dir/retired-home"
  git clone --quiet "$case_dir/project" "$stale_project"
  git -C "$stale_project" remote set-url origin https://github.com/example/repo.git
  fm_write_meta "$state_dir/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$stale_project" \
    "kind=ship" \
    "mode=direct-PR"
  add_github_mocks "$case_dir"
  set +e
  FM_TEST_CASE_STATE="$state_dir" \
    run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "stale cross-home project metadata must refuse merging"
  assert_grep 'not owned by the active Firstmate home' "$case_dir/err" \
    "stale cross-home project metadata refusal was unclear"
  ! grep -q '^api PUT ' "$case_dir/gh-axi.log" \
    || fail "stale cross-home project metadata reached the merge mutation"
  pass "cross-clone merge refuses stale project metadata from another Firstmate home"
}

test_cross_clone_merge_refuses_unowned_home_paths() {
  local values case_dir base candidate state_dir home unowned_project variant rc
  for variant in home-sibling nested-project; do
    values=$(make_secondmate_cross_clone_case "cross-clone-unowned-$variant")
    case_dir=$(printf '%s\n' "$values" | sed -n '1p')
    base=$(printf '%s\n' "$values" | sed -n '2p')
    candidate=$(printf '%s\n' "$values" | sed -n '3p')
    state_dir=$(printf '%s\n' "$values" | sed -n '5p')
    home=$(dirname "$state_dir")
    case "$variant" in
      home-sibling) unowned_project="$home/repo" ;;
      nested-project) unowned_project="$home/projects/team/repo" ;;
    esac
    mkdir -p "$(dirname "$unowned_project")"
    git clone --quiet "$case_dir/project" "$unowned_project"
    git -C "$unowned_project" remote set-url origin https://github.com/example/repo.git
    fm_write_meta "$state_dir/task-x1.meta" \
      "window=fm-task-x1" \
      "worktree=$case_dir/wt" \
      "project=$unowned_project" \
      "kind=ship" \
      "mode=direct-PR"
    add_github_mocks "$case_dir"
    set +e
    FM_TEST_CASE_STATE="$state_dir" \
      run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >"$case_dir/out" 2>"$case_dir/err"
    rc=$?
    set -e
    expect_code 1 "$rc" "$variant project path must not satisfy secondmate home ownership"
    assert_grep 'not owned by the active Firstmate home' "$case_dir/err" \
      "$variant project path refusal was unclear"
    ! grep -q '^api PUT ' "$case_dir/gh-axi.log" \
      || fail "$variant project path reached the merge mutation"
  done
  pass "cross-clone merge accepts only the home root or one immediate seeded project path"
}

test_cross_clone_merge_refuses_midflight_identity_change() {
  local values case_dir base candidate secondmate_project state_dir rc
  values=$(make_secondmate_cross_clone_case cross-clone-identity-race)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  secondmate_project=$(printf '%s\n' "$values" | sed -n '4p')
  state_dir=$(printf '%s\n' "$values" | sed -n '5p')
  add_github_mocks "$case_dir"
  set +e
  FM_TEST_CASE_STATE="$state_dir" \
    FM_TEST_GH_IDENTITY_RACE_PROJECT="$secondmate_project" \
    FM_TEST_GH_IDENTITY_RACE_URL=https://github.com/example/repo-tools.git \
    run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "mid-flight cross-clone identity change must refuse merging"
  assert_grep 'repository identity changed during merge verification' "$case_dir/err" \
    "mid-flight repository identity refusal was unclear"
  ! grep -q '^api PUT ' "$case_dir/gh-axi.log" \
    || fail "mid-flight repository identity change reached the merge mutation"
  pass "cross-clone merge revalidates repository identity immediately before mutation"
}

test_local_merge_still_refuses_cross_clone_identity() {
  local values case_dir base secondmate_project state_dir rc
  values=$(make_secondmate_cross_clone_case local-cross-clone)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  secondmate_project=$(printf '%s\n' "$values" | sed -n '4p')
  state_dir=$(printf '%s\n' "$values" | sed -n '5p')
  fm_write_meta "$state_dir/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$secondmate_project" \
    "kind=ship" \
    "mode=local-only"
  set +e
  FM_TEST_CASE_STATE="$state_dir" run_local_merge "$case_dir" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "local merge must not accept cross-clone repository identity"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$base" ] \
    || fail "refused local cross-clone identity advanced the main-home project"
  assert_grep 'task worktree and project metadata name different repositories' "$case_dir/err" \
    "local cross-clone identity changed the existing wrong-repository refusal"
  pass "local merge retains the exact common-repository requirement"
}

test_github_merge_capture_without_shim_preserves_request_sequence() {
  local values case_dir base candidate
  values=$(make_case github-capture-no-shim)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"
  add_github_mocks "$case_dir"
  run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >/dev/null \
    || fail "GitHub boundary refused the verified candidate without an installed shim"
  [ "$(grep -c '^api POST ' "$case_dir/gh-axi.log")" -eq 1 ] \
    || fail "no-shim GitHub merge changed the GraphQL request sequence"
  grep -qxF "api PUT /repos/example/repo/pulls/9/merge --field sha=$candidate --field merge_method=merge" "$case_dir/gh-axi.log" \
    || fail "no-shim GitHub merge did not preserve the exact conditional mutation"
  pass "GitHub capture preserves the protected merge path without an installed shim"
}

test_github_merge_capture_bypasses_installed_shim() {
  local values case_dir base candidate shim_dir
  values=$(make_case github-capture-shim)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"
  add_github_mocks "$case_dir"
  shim_dir="$case_dir/shim"
  mkdir -p "$shim_dir"
  ln -s "$ROOT/bin/fm-gh-shim.sh" "$shim_dir/gh"
  run_github_merge "$case_dir" "$candidate" "$candidate" "$base" merge "$shim_dir:" >/dev/null \
    || fail "GitHub boundary could not capture GraphQL through an installed shim"
  [ "$(grep -c '^api POST ' "$case_dir/gh-axi.log")" -eq 1 ] \
    || fail "installed shim caused the GraphQL capture to recurse or repeat"
  grep -qxF "api PUT /repos/example/repo/pulls/9/merge --field sha=$candidate --field merge_method=merge" "$case_dir/gh-axi.log" \
    || fail "installed shim capture did not preserve the exact conditional mutation"
  pass "GitHub capture bypasses the installed shim and reaches the genuine gh"
}

test_github_merge_capture_bypasses_foreign_current_shim() {
  local values case_dir base candidate foreign_bin
  values=$(make_case github-capture-foreign-current-shim)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"
  add_github_mocks "$case_dir"
  foreign_bin="$case_dir/foreign-home/bin"
  mkdir -p "$foreign_bin"
  cp "$ROOT/bin/fm-gh-shim.sh" "$foreign_bin/fm-gh-shim.sh"
  chmod +x "$foreign_bin/fm-gh-shim.sh"
  ln -s "$foreign_bin/fm-gh-shim.sh" "$foreign_bin/gh"
  run_github_merge "$case_dir" "$candidate" "$candidate" "$base" merge "$foreign_bin:" >/dev/null \
    || fail "GitHub boundary could not bypass a current shim from another Firstmate home"
  [ "$(grep -c '^api POST ' "$case_dir/gh-axi.log")" -eq 1 ] \
    || fail "foreign current shim caused the GraphQL capture to recurse or repeat"
  grep -qxF "api PUT /repos/example/repo/pulls/9/merge --field sha=$candidate --field merge_method=merge" "$case_dir/gh-axi.log" \
    || fail "foreign current shim changed the exact conditional mutation"
  pass "GitHub capture recognizes a current shim from another home and stays one-pass"
}

test_github_merge_capture_bounds_reentrant_gh() {
  local values case_dir base candidate reentrant_dir rc count
  values=$(make_case github-capture-reentrant)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes" \
    "pr=https://github.com/example/repo/pull/9"
  add_github_mocks "$case_dir"
  reentrant_dir="$case_dir/reentrant"
  mkdir -p "$reentrant_dir"
  cat > "$reentrant_dir/gh" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${FM_GH_SHIM_PROBE:-}" = 1 ] && [ "${1:-}" = --firstmate-gh-shim-probe ]; then
  echo not-a-firstmate-shim
  exit 0
fi
count=0
[ ! -f "$FM_TEST_REENTRANT_COUNT" ] || count=$(cat "$FM_TEST_REENTRANT_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$FM_TEST_REENTRANT_COUNT"
if [ "$count" -gt 4 ]; then
  echo "fixture safety cap: reentrant gh exceeded four invocations" >&2
  exit 99
fi
exec gh "$@"
SH
  chmod +x "$reentrant_dir/gh"
  set +e
  FM_TEST_REENTRANT_COUNT="$case_dir/reentrant.count" \
    run_github_execute "$case_dir" "$candidate" "$candidate" "$base" merge "$reentrant_dir:" \
      >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 70 "$rc" "capture-wrapper re-entry must retain its typed recursion failure"
  count=$(cat "$case_dir/reentrant.count")
  [ "$count" -eq 1 ] || fail "capture recursion reached the reentrant gh $count times instead of once"
  assert_grep 'fm-merge-execute: GitHub capture wrapper recursion detected' "$case_dir/err" \
    "capture-wrapper recursion failure was not actionable"
  assert_no_grep 'fixture safety cap' "$case_dir/err" \
    "product recursion guard did not stop before the fixture safety cap"
  [ "$(grep -c '^api POST ' "$case_dir/gh-axi.log")" -eq 1 ] \
    || fail "capture recursion repeated the GraphQL request"
  assert_no_grep '^api PUT ' "$case_dir/gh-axi.log" \
    "capture recursion reached the merge mutation"
  pass "GitHub capture fails typed and bounded when its selected gh re-enters PATH"
}

test_merge_execute_bounds_inherited_lock_reentry() {
  local values case_dir base candidate reentrant_dir rc count
  values=$(make_case merge-inherited-lock-reentry)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes" \
    "pr=https://github.com/example/repo/pull/9"
  add_github_mocks "$case_dir"
  reentrant_dir="$case_dir/reentrant"
  mkdir -p "$reentrant_dir"
  cat > "$reentrant_dir/gh" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${FM_GH_SHIM_PROBE:-}" = 1 ] && [ "${1:-}" = --firstmate-gh-shim-probe ]; then
  echo not-a-firstmate-shim
  exit 0
fi
count=0
[ ! -f "$FM_TEST_REENTRANT_COUNT" ] || count=$(cat "$FM_TEST_REENTRANT_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$FM_TEST_REENTRANT_COUNT"
if [ "$count" -gt 4 ]; then
  echo "fixture safety cap: merge execution exceeded four inherited-lock reentries" >&2
  exit 99
fi
exec "$FM_TEST_MERGE_EXECUTE" github task-x1 https://github.com/example/repo/pull/9 -- --merge
SH
  chmod +x "$reentrant_dir/gh"
  set +e
  FM_TEST_REENTRANT_COUNT="$case_dir/reentrant.count" FM_TEST_MERGE_EXECUTE="$MERGE_EXECUTE" \
    run_github_execute "$case_dir" "$candidate" "$candidate" "$base" merge "$reentrant_dir:" \
      >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 70 "$rc" "merge re-entry with the inherited lock must fail typed"
  count=$(cat "$case_dir/reentrant.count")
  [ "$count" -eq 1 ] || fail "inherited-lock recursion reached the reentrant gh $count times instead of once"
  assert_grep 'inherited repository lock has contradictory merge-execution depth' "$case_dir/err" \
    "inherited-lock recursion failure did not identify the repeated handoff"
  assert_no_grep 'fixture safety cap' "$case_dir/err" \
    "merge recursion reached the fixture safety cap"
  [ "$(grep -c '^api POST ' "$case_dir/gh-axi.log")" -eq 1 ] \
    || fail "inherited-lock recursion repeated the GraphQL request"
  assert_no_grep '^api PUT ' "$case_dir/gh-axi.log" \
    "inherited-lock recursion reached the merge mutation"
  pass "merge execution bounds inherited-lock re-entry after one valid handoff"
}

test_merge_execute_reentry_without_lock_fails_typed() {
  local values case_dir base rc
  values=$(make_case merge-reentry-without-lock)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_MERGE_EXECUTE_DEPTH=1 \
    "$MERGE_EXECUTE" local task-x1 >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 70 "$rc" "merge re-entry without the inherited lock must fail typed"
  assert_grep 'merge execution re-entered without its repository lock' "$case_dir/err" \
    "merge re-entry refusal did not identify its lost lock"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$base" ] \
    || fail "merge re-entry without a lock advanced the project"
  pass "merge execution permits one lock handoff and refuses any unlocked re-entry"
}

test_unprotected_github_merge_uses_verified_exact_sha() {
  local values case_dir base candidate
  values=$(make_case github-unprotected-exact)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"
  add_github_mocks "$case_dir"
  FM_TEST_GH_PROTECTION=null run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >"$case_dir/out" 2>"$case_dir/err" \
    || fail "GitHub boundary refused the verified candidate for an unprotected repository"
  grep -qxF "api PUT /repos/example/repo/pulls/9/merge --field sha=$candidate --field merge_method=merge --jq {merged: .merged, sha: .sha} | @base64" "$case_dir/gh-axi.log" \
    || fail "unprotected GitHub boundary did not condition the merge on the verified exact SHA"
  grep -qxF "api GET /repos/example/repo/git/ref/heads/main --jq {sha: .object.sha, type: .object.type} | @base64" "$case_dir/gh-axi.log" \
    || fail "unprotected GitHub boundary did not observe the post-mutation base"
  grep -q 'unprotected repository' "$case_dir/err" \
    || fail "unprotected GitHub merge did not diagnose the sanctioned path"
  pass "GitHub merge sanctions a null protection rule without weakening the exact candidate mutation"
}

test_github_merge_refuses_changed_remote_head() {
  local values case_dir base candidate rc
  values=$(make_case github-changed-head)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"
  add_github_mocks "$case_dir"
  set +e
  FM_TEST_GH_PROTECTION=null FM_TEST_GH_API_HEAD_AFTER="$base" \
    run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "GitHub head drift during verification must refuse merging"
  grep -q 'exact candidate changed during merge verification' "$case_dir/err" \
    || fail "GitHub head drift refusal did not identify the verification race"
  ! grep -q '^api PUT ' "$case_dir/gh-axi.log" || fail "changed GitHub head reached the merge API"
  pass "unprotected GitHub merge refuses remote head drift during verification"
}

test_unprotected_github_merge_refuses_changed_remote_base() {
  local values case_dir base candidate advanced_base rc
  values=$(make_case github-changed-base)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  advanced_base=$(printf '%s\n' "$values" | sed -n '3p')
  printf 'final candidate\n' > "$case_dir/wt/final.txt"
  git -C "$case_dir/wt" add final.txt
  git -C "$case_dir/wt" commit -qm final-candidate
  candidate=$(git -C "$case_dir/wt" rev-parse HEAD)
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"
  add_github_mocks "$case_dir"
  set +e
  FM_TEST_GH_PROTECTION=null FM_TEST_GH_BASE_AFTER="$advanced_base" \
    run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "GitHub base drift during verification must refuse an unprotected merge"
  git -C "$case_dir/wt" merge-base --is-ancestor "$advanced_base" "$candidate" \
    || fail "base drift fixture did not remain inside candidate ancestry"
  grep -q 'exact candidate changed during merge verification' "$case_dir/err" \
    || fail "GitHub base drift refusal did not identify the verification race"
  ! grep -q '^api PUT ' "$case_dir/gh-axi.log" || fail "changed GitHub base reached the merge API"
  pass "unprotected GitHub merge refuses remote base drift even when the new base remains an ancestor"
}

test_unprotected_github_merge_refuses_unattributed_mutation_base_drift() {
  local values case_dir base candidate advanced_base tree rc
  values=$(make_case github-mutation-base-race)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  tree=$(git -C "$case_dir/wt" rev-parse "$base^{tree}")
  advanced_base=$(printf 'unrelated base writer\n' | git -C "$case_dir/wt" commit-tree "$tree" -p "$base")
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"
  add_github_mocks "$case_dir"
  set +e
  FM_TEST_GH_PROTECTION=null FM_TEST_GH_BASE_AT_MUTATION="$advanced_base" \
    run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "unrelated base advancement during mutation must fail attribution"
  ! git -C "$case_dir/wt" merge-base --is-ancestor "$advanced_base" "$candidate" \
    || fail "mutation-drift fixture did not create an unrelated base advancement"
  grep -qxF "mutation base: $advanced_base" "$case_dir/gh-axi.log" \
    || fail "mutation-race fixture did not advance the base after adjacent verification"
  grep -q 'post-mutation base transition was not attributable' "$case_dir/err" \
    || fail "unprotected GitHub merge did not diagnose unattributed mutation-time drift"
  pass "unprotected GitHub merge refuses mutation-time drift outside the verified candidate"
}

test_unprotected_github_rebase_accepts_nonempty_candidate() {
  local values case_dir base candidate
  values=$(make_case github-rebase-nonempty)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"
  add_github_mocks "$case_dir"
  FM_TEST_GH_PROTECTION=null \
    run_github_merge "$case_dir" "$candidate" "$candidate" "$base" rebase >"$case_dir/out" 2>"$case_dir/err" \
    || fail "unprotected GitHub rebase refused a nonempty exact candidate"
  grep -qxF "api PUT /repos/example/repo/pulls/9/merge --field sha=$candidate --field merge_method=rebase --jq {merged: .merged, sha: .sha} | @base64" "$case_dir/gh-axi.log" \
    || fail "unprotected GitHub rebase did not condition mutation on the exact candidate"
  grep -q '^api GET /repos/example/repo/compare/' "$case_dir/gh-axi.log" \
    || fail "unprotected GitHub rebase did not validate the rewritten sequence"
  pass "unprotected GitHub rebase accepts a nonempty attributable candidate"
}

test_unprotected_github_rebase_refuses_empty_commit_masked_drift() {
  local values case_dir base candidate advanced_base tree rc
  values=$(make_case github-rebase-empty-masked-drift)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  git -C "$case_dir/wt" commit --allow-empty -qm empty-candidate
  candidate=$(git -C "$case_dir/wt" rev-parse HEAD)
  tree=$(git -C "$case_dir/wt" rev-parse "$base^{tree}")
  advanced_base=$(printf 'unrelated rebase writer\n' | git -C "$case_dir/wt" commit-tree "$tree" -p "$base")
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"
  add_github_mocks "$case_dir"
  set +e
  FM_TEST_GH_PROTECTION=null FM_TEST_GH_BASE_AT_MUTATION="$advanced_base" \
    FM_TEST_GH_REBASE_AHEAD=2 FM_TEST_GH_REBASE_FIRST="$advanced_base" \
    run_github_merge "$case_dir" "$candidate" "$candidate" "$base" rebase >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "originally empty rebase commits must fail before mutation"
  git -C "$case_dir/wt" diff-tree --quiet "$candidate^" "$candidate" -- \
    || fail "empty-rebase fixture did not contain an originally empty commit"
  ! git -C "$case_dir/wt" merge-base --is-ancestor "$advanced_base" "$candidate" \
    || fail "empty-rebase fixture did not create unrelated base drift"
  grep -q 'does not support originally empty candidate commits' "$case_dir/err" \
    || fail "empty-rebase refusal did not identify the unsupported candidate"
  ! grep -q '^api PUT ' "$case_dir/gh-axi.log" \
    || fail "empty rebase candidate reached the mutation API"
  pass "unprotected GitHub rebase rejects empty commits before masked base drift"
}

test_unprotected_github_merge_rejects_graphql_errors() {
  local values case_dir base candidate rc
  values=$(make_case github-graphql-error-null)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"
  add_github_mocks "$case_dir"
  set +e
  FM_TEST_GH_PROTECTION=graphql-error-null FM_TEST_GH_PROTECTION_AFTER=null \
    run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "GraphQL errors must not sanction a null protection rule"
  grep -q 'malformed or ambiguous pull request data' "$case_dir/err" \
    || fail "GraphQL error refusal was not explicit"
  ! grep -q '^api PUT ' "$case_dir/gh-axi.log" || fail "GraphQL error null reached the merge API"
  [ "$(grep -c '^api POST ' "$case_dir/gh-axi.log")" -eq 1 ] \
    || fail "GraphQL error null was normalized before initial classification"
  pass "unprotected GitHub merge rejects null protection data accompanied by GraphQL errors"
}

test_github_merge_refuses_partial_protection_payload() {
  local values case_dir base candidate rc
  values=$(make_case github-partial-protection)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"
  add_github_mocks "$case_dir"
  set +e
  FM_TEST_GH_PROTECTION=partial \
    run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "partial protection data must refuse merging"
  grep -q 'malformed or ambiguous pull request data' "$case_dir/err" \
    || fail "partial protection refusal was not explicit"
  ! grep -q '^api PUT ' "$case_dir/gh-axi.log" || fail "partial protection data reached the merge API"
  pass "GitHub merge rejects a partial protection object instead of treating it as absent"
}

test_github_merge_refuses_ambiguous_protection_payloads() {
  local values case_dir base candidate mode rc
  for mode in duplicate-null duplicate-strict duplicate-admin malformed-occurrence absent scalar misplaced null-child; do
    values=$(make_case "github-ambiguous-$mode")
    case_dir=$(printf '%s\n' "$values" | sed -n '1p')
    base=$(printf '%s\n' "$values" | sed -n '2p')
    candidate=$(printf '%s\n' "$values" | sed -n '3p')
    fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"
    add_github_mocks "$case_dir"
    set +e
    FM_TEST_GH_PROTECTION=$mode FM_TEST_GH_PROTECTION_AFTER=null \
      run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >"$case_dir/out" 2>"$case_dir/err"
    rc=$?
    set -e
    expect_code 1 "$rc" "$mode protection data must refuse merging"
    grep -q 'malformed or ambiguous pull request data' "$case_dir/err" \
      || fail "$mode protection refusal was not explicit"
    ! grep -q '^api PUT ' "$case_dir/gh-axi.log" || fail "$mode protection data reached the merge API"
    [ "$(grep -c '^api POST ' "$case_dir/gh-axi.log")" -eq 1 ] \
      || fail "$mode protection data survived the raw response boundary"
  done
  pass "GitHub merge rejects malformed, misplaced, scalar, partial, and duplicate protection data"
}

test_protected_github_merge_still_requires_strict_checks() {
  local values case_dir base candidate rc
  values=$(make_case github-non-strict-protection)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"
  add_github_mocks "$case_dir"
  set +e
  FM_TEST_GH_PROTECTION=non-strict \
    run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "protected repositories must retain strict-check enforcement"
  grep -q 'requires strict, admin-enforced base branch protection' "$case_dir/err" \
    || fail "non-strict protected-repository refusal was unclear"
  ! grep -q '^api PUT ' "$case_dir/gh-axi.log" || fail "non-strict protection reached the merge API"
  pass "protected GitHub merge retains strict and administrator enforcement"
}

test_unprotected_github_merge_requires_post_mutation_confirmation() {
  local values case_dir base candidate rc
  values=$(make_case github-unconfirmed-merge)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"
  add_github_mocks "$case_dir"
  set +e
  FM_TEST_GH_PROTECTION=null FM_TEST_GH_MERGED=false \
    run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "unconfirmed exact-candidate mutation must fail"
  grep -q 'did not merge the verified candidate' "$case_dir/err" \
    || fail "unconfirmed exact-candidate mutation refusal was unclear"
  pass "unprotected GitHub merge requires post-mutation candidate confirmation"
}

test_github_merge_accepts_live_head_without_recorded_head() {
  local values case_dir base candidate
  values=$(make_case github-live-head)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  base=$(printf '%s\n' "$values" | sed -n '2p')
  candidate=$(printf '%s\n' "$values" | sed -n '3p')
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"
  add_github_mocks "$case_dir"
  run_github_merge "$case_dir" "$candidate" "$candidate" "$base" >/dev/null \
    || fail "GitHub boundary refused a live exact head without recorded head metadata"
  ! grep -q '^pr_head=' "$case_dir/state/task-x1.meta" || fail "merge unexpectedly recorded absent PR head metadata"
  grep -qxF "api PUT /repos/example/repo/pulls/9/merge --field sha=$candidate --field merge_method=merge" "$case_dir/gh-axi.log" \
    || fail "live GraphQL head was not used for a wrapper-authenticated merge"
  pass "GitHub merge binds an absent recorded head to live and local heads"
}

test_invalid_merge_args_are_side_effect_free() {
  local values case_dir before rc
  values=$(make_case invalid-args)
  case_dir=$(printf '%s\n' "$values" | sed -n '1p')
  fm_write_meta "$case_dir/state/task-x1.meta" "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" "kind=ship" "mode=no-mistakes"
  add_github_mocks "$case_dir"
  before=$(cat "$case_dir/state/task-x1.meta")
  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" task-x1 https://github.com/example/repo/pull/9 -- --admin >"$case_dir/out" 2>"$case_dir/err"
  rc=$?
  set -e
  expect_code 2 "$rc" "unsupported merge arguments must fail as invalid input"
  [ "$(cat "$case_dir/state/task-x1.meta")" = "$before" ] || fail "invalid merge arguments rewrote task metadata"
  [ ! -e "$case_dir/state/task-x1.check.sh" ] || fail "invalid merge arguments published a watcher"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "invalid merge arguments reached the credential wrapper"
  pass "invalid merge arguments fail before metadata and watcher side effects"
}

test_exact_literal_receipt_lands_candidate
test_uncommitted_receipt_source_refuses_before_merge
test_raced_local_edit_is_preserved
test_intervening_base_movement_is_refused
test_unchanged_path_drift_is_preserved
test_prepared_transaction_drift_is_preserved
test_wrong_branch_transaction_is_refused
test_github_merge_uses_verified_exact_sha
test_secondmate_cross_clone_github_merge_accepts_same_repository
test_provisioned_secondmate_cross_clone_github_merge_accepts_same_repository
test_cross_clone_merge_refuses_different_repositories
test_cross_clone_merge_refuses_missing_or_ambiguous_identity
test_cross_clone_merge_refuses_stale_home_metadata
test_cross_clone_merge_refuses_unowned_home_paths
test_cross_clone_merge_refuses_midflight_identity_change
test_local_merge_still_refuses_cross_clone_identity
test_github_merge_capture_without_shim_preserves_request_sequence
test_github_merge_capture_bypasses_installed_shim
test_github_merge_capture_bypasses_foreign_current_shim
test_github_merge_capture_bounds_reentrant_gh
test_merge_execute_bounds_inherited_lock_reentry
test_merge_execute_reentry_without_lock_fails_typed
test_unprotected_github_merge_uses_verified_exact_sha
test_github_merge_refuses_changed_remote_head
test_unprotected_github_merge_refuses_changed_remote_base
test_unprotected_github_merge_refuses_unattributed_mutation_base_drift
test_unprotected_github_rebase_accepts_nonempty_candidate
test_unprotected_github_rebase_refuses_empty_commit_masked_drift
test_unprotected_github_merge_rejects_graphql_errors
test_github_merge_refuses_partial_protection_payload
test_github_merge_refuses_ambiguous_protection_payloads
test_protected_github_merge_still_requires_strict_checks
test_unprotected_github_merge_requires_post_mutation_confirmation
test_github_merge_accepts_live_head_without_recorded_head
test_invalid_merge_args_are_side_effect_free
