#!/usr/bin/env bash
# fm-skill-bench.sh - harness-neutral skill candidate oracle for gnhf mining nights.
#
# Subcommands: lint, run, score, loads, budget
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH_ROOT="${FM_SKILL_BENCH_ROOT:-$ROOT/.bench}"
SPEND_FILE="$BENCH_ROOT/spend.tsv"
NIGHT_RUNS_FILE="$BENCH_ROOT/night-runs.count"
ITER_RUNS_FILE="$BENCH_ROOT/iter-runs.count"
RESULTS_FILE="$BENCH_ROOT/results.tsv"
NIGHT_RUN_CAP=240
ITER_RUN_CAP=40
HARNESS_TIMEOUT=300

usage() {
  cat <<'EOF'
usage: fm-skill-bench.sh lint <skill-dir>
       fm-skill-bench.sh run --candidate <dir> --cases <visible|heldout> --harness <codex|claude> --arm <A|B|C>
       fm-skill-bench.sh score
       fm-skill-bench.sh loads --harness <codex|claude> --dir <cwd> --since <iso>
       fm-skill-bench.sh budget
EOF
}

die() {
  printf 'error: fm-skill-bench: %s\n' "$1" >&2
  exit 1
}

bench_ensure_dirs() {
  mkdir -p "$BENCH_ROOT/runs" "$BENCH_ROOT/candidates"
  touch "$SPEND_FILE"
  [ -f "$NIGHT_RUNS_FILE" ] || printf '0\n' >"$NIGHT_RUNS_FILE"
  [ -f "$ITER_RUNS_FILE" ] || printf '0\n' >"$ITER_RUNS_FILE"
  [ -f "$RESULTS_FILE" ] || printf 'candidate\tcase\tharness\tarm\tpass\tloaded\n' >"$RESULTS_FILE"
}

bench_skill_name() {
  local skill_dir=$1 skill_md=$1/SKILL.md name
  [ -f "$skill_md" ] || die "missing SKILL.md in $skill_dir"
  name=$(awk -F': ' '/^name:/{print $2; exit}' "$skill_md" | tr -d '\r')
  [ -n "$name" ] || die "SKILL.md missing name frontmatter"
  printf '%s\n' "$name"
}

bench_lint() {
  local skill_dir=$1 skill_md body_file line n
  [ -d "$skill_dir" ] || die "skill dir not found: $skill_dir"
  skill_md=$skill_dir/SKILL.md
  [ -f "$skill_md" ] || die "missing SKILL.md"

  local lint_err
  lint_err=$(awk '
    BEGIN { in_fm=0; fm_done=0 }
    /^---$/ { if (!fm_done) { in_fm=!in_fm; if (!in_fm) fm_done=1; next } }
    in_fm && /^[a-zA-Z0-9_-]+:/ {
      key=$1
      sub(/:$/, "", key)
      if (key != "name" && key != "description" && key != "user-invocable") {
        print "bad-frontmatter-key"
        exit 1
      }
    }
  ' "$skill_md" 2>&1) || die "${lint_err:-bad-frontmatter-key}"

  local desc
  desc=$(awk -F': ' '/^description:/{sub(/^description: /,""); print; exit}' "$skill_md")
  case "$desc" in
    *[Ww]hen\ about\ to*|*[Bb]efore\ *|*[Ww]henever\ the\ task*) ;;
    *) die "description-not-situation" ;;
  esac

  body_file=$(mktemp)
  awk 'BEGIN{fm=0;done=0} /^---$/{if(!done){fm=!fm; if(!fm) done=1; next}} !fm{print}' "$skill_md" >"$body_file"

  if grep -Eiq '(claude|codex|cursor|\bpi\b|kimi|opencode|grok)' "$skill_md"; then
    rm -f "$body_file"
    die "harness-name"
  fi
  if grep -Eq '/Users/|/home/' "$skill_md"; then
    rm -f "$body_file"
    die "absolute-home-path"
  fi
  if grep -Eq '/[A-Za-z][A-Za-z0-9_-]*' "$skill_md"; then
    rm -f "$body_file"
    die "slash-command"
  fi
  if grep -Eq '\$[A-Za-z][A-Za-z0-9_-]*' "$skill_md"; then
    rm -f "$body_file"
    die "dollar-invocation"
  fi
  if grep -Eiq '\b(captain|first mate|crewmate|scout|second mate)\b' "$skill_md"; then
    rm -f "$body_file"
    die "role-word"
  fi

  n=$(wc -l <"$body_file" | tr -d ' ')
  [ "$n" -le 80 ] || { rm -f "$body_file"; die "body-too-long"; }

  while IFS= read -r line; do
    local ref
    while IFS= read -r ref; do
      [ -z "$ref" ] && continue
      case "$ref" in
        SKILL.md|*/SKILL.md) continue ;;
      esac
      if [ -e "$skill_dir/$ref" ] || [ -e "$skill_dir/$(basename "$ref")" ]; then
        continue
      fi
      die "external-reference"
    done < <(printf '%s\n' "$line" | grep -Eo '[A-Za-z0-9_./-]+\.(md|sh|json|txt|yaml|yml)' || true)
  done <"$body_file"
  rm -f "$body_file"
}

bench_budget_check() {
  local night iter
  night=$(cat "$NIGHT_RUNS_FILE")
  iter=$(cat "$ITER_RUNS_FILE")
  [ "$night" -lt "$NIGHT_RUN_CAP" ] || die "budget: night run cap $NIGHT_RUN_CAP reached"
  [ "$iter" -lt "$ITER_RUN_CAP" ] || die "budget: iteration run cap $ITER_RUN_CAP reached"
}

bench_budget_record() {
  local night iter
  night=$(($(cat "$NIGHT_RUNS_FILE") + 1))
  iter=$(($(cat "$ITER_RUNS_FILE") + 1))
  printf '%s\n' "$night" >"$NIGHT_RUNS_FILE"
  printf '%s\n' "$iter" >"$ITER_RUNS_FILE"
}

bench_record_spend() {
  local harness=$1 in_tok=$2 out_tok=$3
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$harness" "${in_tok:-0}" "${out_tok:-0}" >>"$SPEND_FILE"
}

bench_install_skill() {
  local run_dir=$1 candidate_dir=$2
  local name
  name=$(bench_skill_name "$candidate_dir")
  mkdir -p "$run_dir/.agents/skills/$name"
  cp "$candidate_dir/SKILL.md" "$run_dir/.agents/skills/$name/SKILL.md"
  mkdir -p "$run_dir/.claude"
  rm -rf "$run_dir/.claude/skills"
  ln -sfn ../.agents/skills "$run_dir/.claude/skills"
}

# Claude encodes a session cwd as ~/.claude/projects/<cwd with / and . replaced by ->.
bench_claude_project_dir() {
  local cwd=$1
  printf '%s/.claude/projects/%s' "${HOME}" "$(printf '%s' "$cwd" | tr '/.' '-')"
}

# Portable find -newer for ISO timestamps (BSD find has no -newermt).
bench_find_jsonl_since() {
  local dir=$1 since=$2
  local ref compact
  [ -d "$dir" ] || return 0
  ref=$(mktemp)
  compact=$(printf '%s' "$since" | tr -d 'T:-Z' | cut -c1-12)
  if ! touch -t "$compact" "$ref" 2>/dev/null; then
    touch -d "$since" "$ref" 2>/dev/null || : >"$ref"
  fi
  find "$dir" -name '*.jsonl' -newer "$ref" 2>/dev/null
  rm -f "$ref"
}

# A skill listing is not a load. Require a Skill tool_use or a SKILL.md body read.
bench_claude_file_has_skill_invoke() {
  local file=$1 skill_name=$2
  [ -f "$file" ] || return 1
  if grep -E '"name"[[:space:]]*:[[:space:]]*"Skill"' "$file" 2>/dev/null \
    | grep -Fq "\"skill\":\"$skill_name\""; then
    return 0
  fi
  grep -Fq "${skill_name}/SKILL.md" "$file" 2>/dev/null
}

bench_isolate_repo() {
  local repo=$1
  git -C "$repo" init -q
  git -C "$repo" config user.email bench@example.invalid
  git -C "$repo" config user.name bench
  git -C "$repo" add -A
  git -C "$repo" commit -q -m bench 2>/dev/null || true
}

bench_setup_fakebin() {
  local run_dir=$1 tools=$2
  local fakebin=$run_dir/fakebin tool
  mkdir -p "$fakebin"
  for tool in $tools; do
    cat >"$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$0 $*" >>"__CALLS_LOG__"
exit 0
SH
    sed -i '' "s|__CALLS_LOG__|$run_dir/repo/calls.log|g" "$fakebin/$tool" 2>/dev/null \
      || sed -i "s|__CALLS_LOG__|$run_dir/repo/calls.log|g" "$fakebin/$tool"
    chmod +x "$fakebin/$tool"
  done
  printf '%s\n' "$fakebin"
}

bench_load_case() {
  local case_file=$1
  export ROOT
  # shellcheck disable=SC1090
  . "$case_file"
  : "${TASK:?case missing TASK}"
  : "${ALWAYS_ON_FILE:?case missing ALWAYS_ON_FILE}"
  : "${TOOLS:?case missing TOOLS}"
  : "${EXPECT_SKILL:?case missing EXPECT_SKILL}"
  : "${CHECK:?case missing CHECK}"
  : "${FIXTURE:?case missing FIXTURE}"
  ALWAYS_ON_RULE=${ALWAYS_ON_RULE:-}
}

bench_run_with_timeout() {
  local timeout_sec=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_sec" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$timeout_sec" "$@"
  else
    "$@"
  fi
}

bench_run_harness() {
  local harness=$1 run_dir=$2 task=$3 out_file=$4 skill_name=${5:-}
  local path_prefix="$run_dir/fakebin"
  [ -n "${FM_SKILL_BENCH_STUB_BIN:-}" ] && path_prefix="$FM_SKILL_BENCH_STUB_BIN:$path_prefix"
  case "$harness" in
    codex)
      (
        cd "$run_dir/repo" || exit 1
        PATH="$path_prefix:$PATH" \
          FM_SKILL_BENCH_RUN_DIR="$run_dir" \
          FM_SKILL_BENCH_SKILL_NAME="$skill_name" \
          bench_run_with_timeout "$HARNESS_TIMEOUT" \
          codex exec -C "$run_dir/repo" --skip-git-repo-check --sandbox workspace-write \
          -m gpt-5.6-luna -o "$out_file" "$task" </dev/null
      )
      ;;
    claude)
      (
        cd "$run_dir/repo" || exit 1
        PATH="$path_prefix:$PATH" \
          FM_SKILL_BENCH_RUN_DIR="$run_dir" \
          FM_SKILL_BENCH_SKILL_NAME="$skill_name" \
          bench_run_with_timeout "$HARNESS_TIMEOUT" \
          claude -p --model haiku --output-format json \
            --setting-sources project \
            --dangerously-skip-permissions \
            "$task" </dev/null >"$run_dir/result.json"
        # --setting-sources project drops user/plugin skills that drown auto-invoke.
        # --dangerously-skip-permissions replaces the skipped user allowlist.
        if command -v jq >/dev/null 2>&1; then
          jq -r '.result // empty' "$run_dir/result.json" >"$out_file" 2>/dev/null \
            || cp "$run_dir/result.json" "$out_file"
        else
          cp "$run_dir/result.json" "$out_file"
        fi
      )
      ;;
    *) die "unknown harness: $harness" ;;
  esac
}

bench_detect_loaded() {
  local harness=$1 run_dir=$2 skill_name=$3 since=$4
  case "$harness" in
    codex)
      if [ -f "$run_dir/codex-rollout.jsonl" ]; then
        grep -Fq "${skill_name}/SKILL.md" "$run_dir/codex-rollout.jsonl" && return 0
      fi
      if [ -n "${CODEX_HOME:-}" ] || [ -d "${HOME}/.codex/sessions" ]; then
        local codex_home=${CODEX_HOME:-$HOME/.codex}
        local found=0 f
        while IFS= read -r f; do
          grep -Fq "\"cwd\":\"$run_dir/repo\"" "$f" 2>/dev/null || continue
          if grep -E '"type":"(custom_tool_call|function_call|local_shell_call|CommandExecution|custom_tool_call_output)"' "$f" 2>/dev/null \
            | grep -Fq "$skill_name"; then
            found=1
            break
          fi
        done < <(find "$codex_home/sessions" -name '*.jsonl' -newer "$run_dir/.run-start" 2>/dev/null)
        [ "$found" -eq 1 ] && return 0
      fi
      ;;
    claude)
      if bench_claude_file_has_skill_invoke "$run_dir/result.json" "$skill_name"; then
        return 0
      fi
      if bench_claude_file_has_skill_invoke "$run_dir/claude-transcript.jsonl" "$skill_name"; then
        return 0
      fi
      local proj_dir found=0 f
      proj_dir=$(bench_claude_project_dir "$run_dir/repo")
      if [ -d "$proj_dir" ]; then
        while IFS= read -r f; do
          if bench_claude_file_has_skill_invoke "$f" "$skill_name"; then
            found=1
            break
          fi
        done < <(find "$proj_dir" -name '*.jsonl' -newer "$run_dir/.run-start" 2>/dev/null)
        [ "$found" -eq 1 ] && return 0
      fi
      ;;
  esac
  return 1
}

bench_run_case() {
  local candidate_dir=$1 cases_mode=$2 harness=$3 arm=$4
  local cases_dir=${FM_SKILL_BENCH_CASES_DIR:-$ROOT/tests/fixtures/fm-skill-bench/cases}
  local case_file skill_name
  bench_ensure_dirs
  bench_budget_check

  if [ "$arm" = B ] || [ "$arm" = C ]; then
    skill_name=$(bench_skill_name "$candidate_dir")
  else
    skill_name=
  fi

  shopt -s nullglob
  local -a case_files=()
  local case_file
  for case_file in "$cases_dir"/*.case; do
    [[ "$case_file" == *.heldout.case ]] && continue
    case_files+=("$case_file")
  done
  for case_file in "$cases_dir"/*.heldout.case; do
    case_files+=("$case_file")
  done
  shopt -u nullglob

  for case_file in "${case_files[@]}"; do
    [ -f "$case_file" ] || continue
    case "$case_file" in
      *.heldout.case)
        [ "$cases_mode" = heldout ] || continue
        ;;
      *)
        [ "$cases_mode" = visible ] || continue
        ;;
    esac

    bench_load_case "$case_file"
    local case_id run_dir fakebin pass_this=1 n=1 verdict
    case_id=$(basename "$case_file")
    if [[ "$case_file" == *.heldout.case ]]; then
      case_id=${case_id%.heldout.case}.heldout
    else
      case_id=${case_id%.case}
    fi
    run_dir="$BENCH_ROOT/runs/${case_id}-${harness}-${arm}"
    rm -rf "$run_dir"
    mkdir -p "$run_dir/repo"
    date -u +%Y-%m-%dT%H:%M:%SZ >"$run_dir/.run-start"

    if [ -d "$FIXTURE" ]; then
      cp -a "$FIXTURE/." "$run_dir/repo/"
    fi

    if [ ! -f "$run_dir/repo/$ALWAYS_ON_FILE" ]; then
      : >"$run_dir/repo/$ALWAYS_ON_FILE"
    fi
    if [ -n "$ALWAYS_ON_RULE" ] && [ "$arm" != C ]; then
      printf '%s\n' "$ALWAYS_ON_RULE" >>"$run_dir/repo/$ALWAYS_ON_FILE"
    elif [ "$arm" = C ] && [ -n "$ALWAYS_ON_RULE" ]; then
      grep -Fv "$ALWAYS_ON_RULE" "$run_dir/repo/$ALWAYS_ON_FILE" >"$run_dir/repo/${ALWAYS_ON_FILE}.tmp" \
        && mv "$run_dir/repo/${ALWAYS_ON_FILE}.tmp" "$run_dir/repo/$ALWAYS_ON_FILE"
    fi

    fakebin=$(bench_setup_fakebin "$run_dir" "$TOOLS")

    if [ "$arm" = B ] || [ "$arm" = C ]; then
      bench_install_skill "$run_dir/repo" "$candidate_dir"
    fi

    bench_isolate_repo "$run_dir/repo"
    : >"$run_dir/repo/calls.log"

    export FM_SKILL_BENCH_ARM="$arm"
    while [ "$n" -le 2 ]; do
      local out_file=$run_dir/last-$n.txt
      if ! bench_run_harness "$harness" "$run_dir" "$TASK" "$out_file" "$skill_name"; then
        pass_this=0
        break
      fi
      if ! CHECK="$CHECK" TASK="$TASK" EXPECT_SKILL="$EXPECT_SKILL" bash -c '
        export CALLS_LOG="'"$run_dir/repo/calls.log"'"
        export LAST_MSG="'"$out_file"'"
        export RUN_DIR="'"$run_dir/repo"'"
        "$CHECK"
      '; then
        pass_this=0
        break
      fi
      n=$((n + 1))
    done

    bench_budget_record
    local loaded=no
    if [ -n "$skill_name" ] && bench_detect_loaded "$harness" "$run_dir" "$skill_name" "$(cat "$run_dir/.run-start")"; then
      loaded=yes
    fi

    if [ "$pass_this" -eq 1 ]; then
      verdict=pass
    else
      verdict=fail
    fi

    local cand_name
    cand_name=$(basename "$candidate_dir")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$cand_name" "$case_id" "$harness" "$arm" "$verdict" "$loaded" >>"$RESULTS_FILE"
    printf 'RUN %s %s %s %s %s loaded=%s\n' "$case_id" "$harness" "$arm" "$verdict" "$cand_name" "$loaded"
  done
}

bench_verify_heldout_hash() {
  local hash_file=$BENCH_ROOT/heldout.sha256
  local cases_dir=${FM_SKILL_BENCH_CASES_DIR:-$ROOT/tests/fixtures/fm-skill-bench/cases}
  [ -f "$hash_file" ] || die "heldout hash missing: $hash_file"
  local tmp
  tmp=$(mktemp)
  # shellcheck disable=SC2012
  if ls "$cases_dir"/*.heldout.case >/dev/null 2>&1; then
    local rel_cases_dir=${cases_dir#"$ROOT"/}
    (cd "$ROOT" && sha256sum "$rel_cases_dir"/*.heldout.case | LC_ALL=C sort) >"$tmp"
  else
    : >"$tmp"
  fi
  if ! diff -q "$hash_file" "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    die "heldout hash mismatch"
  fi
  rm -f "$tmp"
}

bench_score() {
  bench_verify_heldout_hash
  local candidates heldout_gain=0
  mapfile -t candidates < <(awk -F'\t' 'NR>1{print $1}' "$RESULTS_FILE" | sort -u)
  local cand case_id harness a_pass b_pass c_pass
  for cand in "${candidates[@]}"; do
    [ -n "$cand" ] || continue
    local keep=1 heldout_ok=0 loaded_ok=1
    mapfile -t case_ids < <(awk -F'\t' -v c="$cand" '$1==c{print $2}' "$RESULTS_FILE" | sort -u)
    for case_id in "${case_ids[@]}"; do
      for harness in codex claude; do
        a_pass=$(awk -F'\t' -v c="$cand" -v k="$case_id" -v h="$harness" '$1==c && $2==k && $3==h && $4=="A" && $5=="pass"{print; exit}' "$RESULTS_FILE")
        b_pass=$(awk -F'\t' -v c="$cand" -v k="$case_id" -v h="$harness" '$1==c && $2==k && $3==h && $4=="B" && $5=="pass"{print; exit}' "$RESULTS_FILE")
        c_pass=$(awk -F'\t' -v c="$cand" -v k="$case_id" -v h="$harness" '$1==c && $2==k && $3==h && $4=="C" && $5=="pass"{print; exit}' "$RESULTS_FILE")
        printf 'CASE %s %s A=%s B=%s C=%s\n' "$case_id" "$harness" \
          "$([ -n "$a_pass" ] && echo pass || echo fail)" \
          "$([ -n "$b_pass" ] && echo pass || echo fail)" \
          "$([ -n "$c_pass" ] && echo pass || echo fail)"
      done
    done

    for harness in codex claude; do
      local vis_a=0 vis_b=0 ho_a=0 ho_b=0 regress=0 flip=0
      while IFS=$'\t' read -r _ case_id _ arm result loaded; do
        if [[ "$case_id" == *heldout* ]]; then local ho=1; else local ho=0; fi
        if [ "$arm" = A ] && [ "$result" = pass ]; then
          [ "$ho" -eq 1 ] && ho_a=$((ho_a + 1)) || vis_a=$((vis_a + 1))
        fi
        if [ "$arm" = B ] && [ "$result" = pass ]; then
          [ "$ho" -eq 1 ] && ho_b=$((ho_b + 1)) || vis_b=$((vis_b + 1))
          [ "$loaded" != yes ] && loaded_ok=0
        fi
        if [ "$ho" -eq 0 ] && [ "$arm" = A ] && [ "$result" = pass ]; then
          b_res=$(awk -F'\t' -v c="$cand" -v k="$case_id" -v h="$harness" '$1==c && $2==k && $3==h && $4=="B"{print $5; exit}' "$RESULTS_FILE")
          [ "$b_res" = pass ] || regress=1
        fi
        if [ "$ho" -eq 1 ]; then
          a_res=$(awk -F'\t' -v c="$cand" -v k="$case_id" -v h="$harness" '$1==c && $2==k && $3==h && $4=="A"{print $5; exit}' "$RESULTS_FILE")
          b_res=$(awk -F'\t' -v c="$cand" -v k="$case_id" -v h="$harness" '$1==c && $2==k && $3==h && $4=="B"{print $5; exit}' "$RESULTS_FILE")
          if [ "$a_res" != pass ] && [ "$b_res" = pass ]; then flip=1; fi
        fi
      done < <(awk -F'\t' -v c="$cand" -v h="$harness" '$1==c && $3==h' "$RESULTS_FILE")

      [ "$vis_b" -ge $((vis_a + 2)) ] || keep=0
      [ "$regress" -eq 0 ] || keep=0
      [ "$ho_b" -ge "$ho_a" ] || keep=0
      [ "$flip" -eq 1 ] && heldout_ok=1
    done

    [ "$heldout_ok" -eq 1 ] || keep=0
    [ "$loaded_ok" -eq 1 ] || keep=0

    if [ "$keep" -eq 1 ]; then
      printf 'CANDIDATE %s VERDICT KEEP\n' "$cand"
      for harness in codex claude; do
        while IFS= read -r case_id; do
          [ -n "$case_id" ] || continue
          a_r=$(awk -F'\t' -v c="$cand" -v k="$case_id" -v hs="$harness" '$1==c && $2==k && $3==hs && $4=="A"{print $5; exit}' "$RESULTS_FILE")
          b_r=$(awk -F'\t' -v c="$cand" -v k="$case_id" -v hs="$harness" '$1==c && $2==k && $3==hs && $4=="B"{print $5; exit}' "$RESULTS_FILE")
          [ "$a_r" != pass ] && [ "$b_r" = pass ] && heldout_gain=$((heldout_gain + 1))
          [ "$a_r" = pass ] && [ "$b_r" != pass ] && heldout_gain=$((heldout_gain - 1))
        done < <(awk -F'\t' -v c="$cand" -v h="$harness" '$1==c && $2 ~ /heldout/{print $2}' "$RESULTS_FILE" | sort -u)
      done
    else
      printf 'CANDIDATE %s VERDICT DISCARD\n' "$cand"
    fi
  done
  printf 'HELDOUT_GAIN %s\n' "$heldout_gain"
}

bench_loads() {
  local harness="" dir="" since=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --harness) harness=$2; shift 2 ;;
      --dir) dir=$2; shift 2 ;;
      --since) since=$2; shift 2 ;;
      *) die "unknown loads arg: $1" ;;
    esac
  done
  [ -n "$harness" ] && [ -n "$dir" ] && [ -n "$since" ] || die "loads requires --harness --dir --since"
  case "$harness" in
    codex)
      local codex_home=${CODEX_HOME:-$HOME/.codex}
      find "$codex_home/sessions" -name '*.jsonl' 2>/dev/null | while IFS= read -r f; do
        grep -Fq "\"cwd\":\"$dir\"" "$f" 2>/dev/null || continue
        grep -oE '[A-Za-z0-9_-]+/SKILL\.md' "$f" 2>/dev/null \
          | sed 's|/SKILL.md||' | sort -u
      done | sort -u
      ;;
    claude)
      local f proj_dir
      proj_dir=$(bench_claude_project_dir "$dir")
      {
        if [ -f "$dir/result.json" ]; then
          grep -E '"name"[[:space:]]*:[[:space:]]*"Skill"' "$dir/result.json" 2>/dev/null \
            | grep -oE '"skill":"[^"]+"' | sed 's/"skill":"//;s/"$//'
        fi
        if [ -d "$proj_dir" ]; then
          while IFS= read -r f; do
            grep -E '"name"[[:space:]]*:[[:space:]]*"Skill"' "$f" 2>/dev/null \
              | grep -oE '"skill":"[^"]+"' | sed 's/"skill":"//;s/"$//'
          done < <(bench_find_jsonl_since "$proj_dir" "$since")
        fi
      } | sort -u
      ;;
    *) die "unknown harness: $harness" ;;
  esac
}

bench_budget() {
  bench_ensure_dirs
  local night iter in_tok=0 out_tok=0
  night=$(cat "$NIGHT_RUNS_FILE")
  iter=$(cat "$ITER_RUNS_FILE")
  if [ -f "$SPEND_FILE" ]; then
    while IFS=$'\t' read -r ts _h i o; do
      [ "${ts:-}" = "$(printf '%s' "$ts" | grep -E '^[0-9]{4}-')" ] || continue
      in_tok=$((in_tok + ${i:-0}))
      out_tok=$((out_tok + ${o:-0}))
    done <"$SPEND_FILE"
  fi
  printf 'runs_used: %s/%s (iteration %s/%s)\n' "$night" "$NIGHT_RUN_CAP" "$iter" "$ITER_RUN_CAP"
  printf 'bench_tokens: %s/%s\n' "$in_tok" "$out_tok"
}

main() {
  [ $# -ge 1 ] || { usage >&2; exit 2; }
  case "$1" in
    lint)
      shift
      [ $# -eq 1 ] || die "lint requires <skill-dir>"
      bench_lint "$1"
      ;;
    run)
      shift
      local candidate="" cases_mode="" harness="" arm=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --candidate) candidate=$2; shift 2 ;;
          --cases) cases_mode=$2; shift 2 ;;
          --harness) harness=$2; shift 2 ;;
          --arm) arm=$2; shift 2 ;;
          *) die "unknown run arg: $1" ;;
        esac
      done
      [ -n "$candidate" ] && [ -n "$cases_mode" ] && [ -n "$harness" ] && [ -n "$arm" ] \
        || die "run requires --candidate --cases --harness --arm"
      bench_run_case "$candidate" "$cases_mode" "$harness" "$arm"
      ;;
    score)
      bench_score
      ;;
    loads)
      shift
      bench_loads "$@"
      ;;
    budget)
      bench_budget
      ;;
    -h|--help)
      usage
      ;;
    *)
      die "unknown subcommand: $1"
      ;;
  esac
}

main "$@"
