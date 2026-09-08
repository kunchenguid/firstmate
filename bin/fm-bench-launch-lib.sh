#!/usr/bin/env bash
# fm-bench-launch-lib.sh - fail-closed refusal that keeps a model-routing
# benchmark entrant from launching before its gates have passed.
#
# The adversarial review's launch answer is "no entrant may launch now", and it
# stays that way until the whole correction set is implemented and evidenced.
# A prose rule cannot enforce that: a supervisor reaching for fm-spawn.sh has
# real capability and no reason to remember the gate. This library is the
# capability half, mirroring bin/fm-gate-refuse-lib.sh's chokepoint pattern.
#
# Scope is exactly the reserved benchmark task-id prefix `bench-`. A task id
# that does not start with it is not a benchmark entrant, so ordinary fleet
# spawns take one prefix comparison and are otherwise completely unaffected.
#
# A benchmark entrant may launch only when all of these hold:
#   1. FM_BENCH_ROOT names a benchmark directory,
#   2. that directory holds a preflight.receipt with verdict "pass",
#   3. the receipt's plan_sha256 still matches benchmark.json's current bytes,
#      and
#   4. `fm-bench-gate.sh launch-check` recomputes the receipt's evidence
#      binding over every artifact the preflight validated and still agrees.
#
# Conditions 3 and 4 are what make the receipt a binding rather than a note.
# Editing the plan after a passing preflight invalidates every receipt written
# against it, so a relaxed threshold or a swapped packet cannot ride an old
# pass; and because the evidence binding covers the freeze, manifest,
# allowance, provenance, and evaluator material too, deleting a capture record
# or lowering the measured allowance after a pass revokes the clearance rather
# than leaving it standing. The gate owns that digest, so this library never
# recomputes it independently.
#
# TEST-HARNESS ESCAPE HATCH (FM_BENCH_LAUNCH_BYPASS=1): firstmate's own suite
# spawns fixture tasks whose ids may collide with the reserved prefix. The
# hatch is honoured only when it is set, is never set by any tracked runtime
# path, and mirrors the bypass precedent in bin/fm-gate-refuse-lib.sh.

# Print the sha256 of a file, or nothing when it cannot be hashed.
fm_bench_sha256_file() {  # <path>
  [ -f "$1" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    return 1
  fi
}

# Refuse a benchmark entrant spawn that no passing preflight covers.
# Returns 0 for every non-benchmark task id.
fm_refuse_ungated_benchmark_entrant() {  # <task-id>
  local id=${1-} root receipt plan_hash receipt_hash verdict gate evidence
  case "$id" in
    bench-*) ;;
    *) return 0 ;;
  esac
  [ "${FM_BENCH_LAUNCH_BYPASS:-}" = 1 ] && return 0

  root=${FM_BENCH_ROOT:-}
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    echo "error: benchmark entrant $id has no benchmark directory; launch refused" >&2
    return 1
  fi
  receipt="$root/preflight.receipt"
  if [ ! -f "$receipt" ]; then
    echo "error: benchmark entrant $id has no passing preflight; launch refused" >&2
    return 1
  fi
  verdict=$(sed -n 's/.*"verdict"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$receipt" | head -n 1)
  if [ "$verdict" != pass ]; then
    echo "error: benchmark entrant $id preflight verdict is '${verdict:-unreadable}'; launch refused" >&2
    return 1
  fi
  receipt_hash=$(sed -n 's/.*"plan_sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$receipt" | head -n 1)
  plan_hash=$(fm_bench_sha256_file "$root/benchmark.json") || plan_hash=
  if [ -z "$plan_hash" ] || [ -z "$receipt_hash" ] || [ "$plan_hash" != "$receipt_hash" ]; then
    echo "error: benchmark entrant $id preflight covers a different plan; launch refused" >&2
    return 1
  fi
  gate="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/fm-bench-gate.sh"
  if [ ! -x "$gate" ]; then
    echo "error: benchmark entrant $id cannot recheck its preflight evidence; launch refused" >&2
    return 1
  fi
  if ! evidence=$("$gate" --bench "$root" launch-check 2>&1); then
    echo "error: benchmark entrant $id preflight evidence no longer holds; launch refused" >&2
    printf '%s\n' "$evidence" >&2
    return 1
  fi
  return 0
}

fm_refuse_unconfined_remote_benchmark_entrant() {  # <task-id>
  local id=${1-}
  case "$id" in
    bench-*) ;;
    *) return 0 ;;
  esac
  [ "${FM_BENCH_LAUNCH_BYPASS:-}" = 1 ] && return 0
  echo "error: benchmark entrant $id cannot use its preflight-proven confinement on a remote secondmate route; launch refused" >&2
  return 1
}

fm_bench_wrap_entrant_launch() {  # <task-id> <worktree> <shell-command>
  local id=${1-} worktree=${2-} command=${3-} root wrapped isolation_hash receipt_hash
  local harness=${4-} model=${5-} effort=${6-} raw=${7:-0} kind=${8:-ship}
  local library_dir=${BASH_SOURCE[0]%/*}
  case "$id" in
    bench-*) ;;
    *) printf '%s' "$command"; return 0 ;;
  esac
  [ "${FM_BENCH_LAUNCH_BYPASS:-}" = 1 ] && { printf '%s' "$command"; return 0; }
  fm_refuse_ungated_benchmark_entrant "$id" || return 1
  root=${FM_BENCH_ROOT:-}
  receipt_hash=$(sed -n 's/.*"isolation_sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$root/preflight.receipt" | head -n 1)
  isolation_hash=$(fm_bench_sha256_file "$root/isolation.json") || isolation_hash=
  if [ -z "$receipt_hash" ] || [ -z "$isolation_hash" ] || [ "$receipt_hash" != "$isolation_hash" ]; then
    echo "error: benchmark entrant $id preflight does not cover the current isolation layout; launch refused" >&2
    return 1
  fi
  library_dir=$(cd -- "$library_dir" && pwd) || return 1
  wrapped=$(python3 - "$root/isolation.json" "$id" "$worktree" "$command" \
    "$harness" "$model" "$effort" "$raw" "$kind" "${9-}" "${10-}" "${11-}" "${12-}" "${13-}" "$library_dir" <<'PY'
import json
import os
import re
import shlex
import shutil
import sys
from pathlib import Path

path, entrant_id, worktree, command, harness, model, effort, raw, kind, brief, code_root, state, turnend, binary, library = sys.argv[1:]
try:
    record = json.loads(Path(path).read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"cannot read isolation.json: {exc}")
wrapper = record.get("launch_wrapper")
entrants = record.get("entrants")
if not isinstance(wrapper, list) or not wrapper or not all(isinstance(item, str) and item for item in wrapper):
    raise SystemExit("isolation.json has no launch-capable confinement wrapper")
if not isinstance(entrants, list):
    raise SystemExit("isolation.json has no provisioned entrants")
matched_entrants = [item for item in entrants if isinstance(item, dict) and item.get("id") == entrant_id]
entrant = matched_entrants[0] if len(matched_entrants) == 1 else None
if entrant is None:
    raise SystemExit(f"isolation.json has no entrant {entrant_id}")
plan = json.loads(Path(path).with_name("benchmark.json").read_text(encoding="utf-8"))
track = plan.get("tracks", {}).get(entrant.get("track"), {})
role = entrant.get("role", "entrant")
candidates = track.get("entrants", []) if role == "entrant" else [track.get("baseline")] if role == "baseline" else []
matches = [item for item in candidates if isinstance(item, dict) and item.get("name") == entrant.get("candidate")]
if len(matches) != 1:
    raise SystemExit("entrant task id is not bound to exactly one planned candidate")
candidate = matches[0]
if (harness, model, effort or None) != (candidate.get("harness"), candidate.get("model"), candidate.get("effort")):
    raise SystemExit("resolved launch harness/model/effort differs from the planned candidate")
if raw != "0" or kind == "secondmate":
    raise SystemExit("benchmark entrants require a standard worker launch template")
if harness not in ("claude", "codex", "opencode", "pi", "pi-signed", "cursor", "gemini"):
    raise SystemExit("benchmark confinement does not support this harness's launch dependencies")
declared_root = Path(str(entrant.get("root", ""))).resolve()
if not declared_root.is_dir() or Path(worktree).resolve() != declared_root:
    raise SystemExit("spawn worktree is not the preflight-proven entrant root")
private = {}
for key in ("private_object_store", "private_tmp", "private_home", "private_session"):
    value = entrant.get(key)
    if not isinstance(value, str) or not value:
        raise SystemExit(f"entrant {entrant_id} has no {key}")
    target = Path(value).resolve()
    if not target.is_dir():
        raise SystemExit(f"entrant {entrant_id} private path is unavailable: {key}")
    try:
        target.relative_to(declared_root)
    except ValueError:
        raise SystemExit(f"entrant {entrant_id} private path escapes its proven root: {key}")
    private[key] = str(target)
dynamic = {
    "{root}": str(declared_root),
    "{provider_network}": str(entrant.get("provider_network", "")),
    "{provider_proxy}": str(entrant.get("provider_proxy", "")),
    "{provider_proxy_container}": str(entrant.get("provider_proxy_container", "")),
}
if any(not value for value in dynamic.values()):
    raise SystemExit(f"entrant {entrant_id} has no dedicated provider boundary")
argv = [dynamic.get(item, item.replace("{root}", str(declared_root))) for item in wrapper]
launcher = argv[0]
if "/" in launcher:
    if not Path(launcher).is_file() or not os.access(launcher, os.X_OK):
        raise SystemExit(f"verified confinement wrapper is unavailable: {launcher}")
elif shutil.which(launcher) is None:
    raise SystemExit(f"verified confinement wrapper is unavailable: {launcher}")
if brief:
    import tempfile

    stage = Path(tempfile.mkdtemp(prefix="launch-", dir=private["private_session"]))
    stage.chmod(0o700)
    staged_state = stage / "state"
    staged_state.mkdir()
    staged_bin = stage / "bin"
    staged_bin.mkdir()
    staged_code = stage / "firstmate"
    staged_code.mkdir()
    staged_data = stage / "data"
    staged_data.mkdir()
    def quote(value):
        return "'" + str(value).replace("'", "'\\''") + "'"
    rewrites = {
        brief: str(stage / "brief.md"),
        str(Path(brief).parent / "report.md"): str(staged_state / f"{entrant_id}.report.md"),
        str(Path(brief).parent): str(staged_data),
        code_root: str(staged_code),
        str(Path(code_root) / "bin" / "fm-operational-input.sh"): str(staged_bin / "fm-operational-input.sh"),
        str(Path(code_root) / "bin" / "fm-busy-event.sh"): str(staged_bin / "fm-busy-event.sh"),
        state: str(staged_state),
        str(Path(state).resolve()): str(staged_state),
        turnend: str(staged_state / Path(turnend).name),
    }
    substitutions = {key: value for old, new in rewrites.items() if old
                     for key, value in ((quote(old), quote(new)), (old, new))}
    pattern = re.compile("|".join(re.escape(key) for key in sorted(substitutions, key=len, reverse=True)))
    def rewrite(text):
        return pattern.sub(lambda match: substitutions[match[0]], text)
    try:
        for relative in ("bin", ".agents/skills", "docs", "AGENTS.md", "CLAUDE.md"):
            source = Path(code_root) / relative
            if not source.exists():
                continue
            sources = [source, *source.rglob("*")] if source.is_dir() else [source]
            if any(item.is_symlink() for item in sources):
                raise SystemExit("brief dependencies must be regular source files")
            destination = staged_code / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            if source.is_dir():
                shutil.copytree(source, destination)
            else:
                shutil.copyfile(source, destination)
        (stage / "brief.md").write_text(rewrite(Path(brief).read_text(encoding="utf-8")), encoding="utf-8")
        for name in ("fm-operational-input.sh", "fm-busy-event.sh", "fm-busy-lib.sh"):
            shutil.copyfile(Path(code_root) / "bin" / name, staged_bin / name)
            (staged_bin / name).chmod(0o700)
        for suffix in ("pi-ext.ts", "omp-ext.ts", "gemini-settings.json", "busy-gen", "busy-state"):
            source = Path(state) / f"{entrant_id}.{suffix}"
            if source.is_file():
                (staged_state / source.name).write_text(rewrite(source.read_text(encoding="utf-8")), encoding="utf-8")
        for relative in (".claude/settings.local.json", ".opencode/plugins/fm-busy-state.js"):
            source = declared_root / relative
            if source.is_file():
                source.write_text(rewrite(source.read_text(encoding="utf-8")), encoding="utf-8")
        command = rewrite(command)
        if harness in ("pi", "pi-signed"):
            extension = staged_state / f"{entrant_id}.pi-ext.ts"
            if not extension.is_file():
                raise SystemExit("the Pi launch extension is unavailable")
            runtime_extension = f"/tmp/fm-bench-{stage.name}.ts"
            command = command.replace(quote(extension), quote(runtime_extension))
            command = f"cp {quote(extension)} {quote(runtime_extension)} && " + command
        if harness.startswith("cursor"):
            projects = Path(private["private_home"]) / ".cursor/projects"
            prior = sorted({entry.name for transcripts in projects.glob("*/agent-transcripts")
                            for entry in transcripts.iterdir() if entry.is_dir()})
            (Path(state) / f"{entrant_id}.cursor-session").write_text(
                f"projects_root={projects}\nworkspace_root={declared_root}\n"
                + "".join(f"prior_conversation={name}\n" for name in prior), encoding="utf-8")
        if binary:
            command = command.replace(quote(binary), shlex.quote(Path(binary).name))
    except (OSError, UnicodeError):
        shutil.rmtree(stage)
        raise
env = [f"BENCH_PRIVATE_ROOT={declared_root}", f"BENCH_PRIVATE_OBJECT_STORE={private['private_object_store']}", f"BENCH_PRIVATE_TMP={private['private_tmp']}", f"BENCH_PRIVATE_HOME={private['private_home']}", f"BENCH_PRIVATE_SESSION={private['private_session']}"]
launch = ["env", *env, *argv, "/bin/sh", "-lc", command]
if brief:
    launch = ["python3", str(Path(library) / "fm-bench-lifecycle.py"), str(staged_state),
              str(Path(state).resolve()), entrant_id, str(Path(library) / "fm-busy-event.sh"), "--report",
              str(Path(brief).parent / "report.md"), "--", *launch]
print(" ".join(shlex.quote(item) for item in launch))
PY
) || {
    echo "error: benchmark entrant $id cannot use its preflight-proven confinement; launch refused" >&2
    return 1
  }
  printf '%s' "$wrapped"
}
