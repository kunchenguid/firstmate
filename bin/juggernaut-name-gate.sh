#!/usr/bin/env bash
# juggernaut-name-gate.sh - the Juggernaut rename's done gate.
#
# Fails while the pre-rename product name survives in tracked files. It checks
# both tracked content and tracked file names, because a rename can leave the
# old name in prose, a comment, a script name, an environment variable, a path,
# or an executable name. Content is read text-only, so binaries are skipped.
#
# Usage:
#   bin/juggernaut-name-gate.sh                 # report leftovers, exit 1 if any
#   bin/juggernaut-name-gate.sh --root <dir>    # measure another checkout
#   bin/juggernaut-name-gate.sh --self-test     # prove the gate still bites
#
# Exit status: 0 when nothing outside the allow list remains, 1 while leftovers
# remain, 2 on a usage or environment error. The leftover count is printed by
# this one command, so a before/after comparison is two runs of it.
#
# Allow list, and nothing else (map: "The done gate"):
#   1. The upstream credit line in README.md and the MIT licence notice in
#      LICENSE, which name the original project. ALLOWED_LINES below holds the
#      exact credit line; LICENSE keeps its notice intact and mentions no name.
#   2. Git history. This gate reads tracked content and names only, never
#      commits or messages, so history is untouched by construction.
#   3. A compatibility alias while a running home still calls the old name.
#      Each ALLOWED_FILES entry is one exact path whose comment names the caller
#      that still calls it and the condition that removes the entry. There is
#      no blanket old-prefix exemption, so an alias covers nothing but itself.
#
# This gate's own path is allow-listed because it defines the strings it
# searches for; it is the one file that must keep them.
set -eu

BASE_PATTERN='firstmate|fm-'

# Exact tracked paths that may still carry the old name.
# Phase 1 renames user-facing text only, so no alias is needed yet; Phase 2 adds
# one line per alias as it ships, for example:
#   "bin/fm-update.sh"   # alias; called by live home state/juggernaut-rename; drop when no home calls it
ALLOWED_FILES=(
  "bin/juggernaut-name-gate.sh" # this gate: it must name what it forbids
)

# Lines inside a tracked file that may keep the old name, as "path|extended-regex".
ALLOWED_LINES=(
  "README.md|^Juggernaut is a fork of \[Firstmate\]" # upstream credit, never removed
)

die() {
  printf 'juggernaut-name-gate.sh: %s\n' "$*" >&2
  exit 2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

report() {
  local root="$1" entry
  [ -d "$root/.git" ] || [ -f "$root/.git" ] || die "$root is not a git checkout"
  cd "$root" || die "cannot enter $root"

  local allow_files exempt tracked
  gate_work=$(mktemp -d) || die "cannot create a temporary directory"
  # shellcheck disable=SC2064 # the path is already resolved and must not change
  trap "rm -rf -- '$gate_work'" EXIT
  allow_files="$gate_work/allowed-files"
  exempt="$gate_work/exempt-lines"
  tracked="$gate_work/tracked"
  : >"$allow_files"
  : >"$exempt"
  for entry in ${ALLOWED_FILES[@]+"${ALLOWED_FILES[@]}"}; do printf '%s\n' "$entry" >>"$allow_files"; done
  for entry in ${ALLOWED_LINES[@]+"${ALLOWED_LINES[@]}"}; do
    allow_path=${entry%%|*}
    allow_re=${entry#*|}
    [ -f "$allow_path" ] || continue
    grep -nE -- "$allow_re" "$allow_path" | while IFS=: read -r allow_lineno _; do
      printf '%s:%s\n' "$allow_path" "$allow_lineno" >>"$exempt"
    done
  done

  git ls-files >"$tracked" || die "git ls-files failed"

  awk -v allow_files="$allow_files" -v exempt="$exempt" -v tracked="$tracked" '
    function classify(path) {
      if (path ~ /^docs\//) return "docs"
      if (path ~ /^bin\//) return "bin"
      if (path ~ /^\.agents\//) return "agents"
      if (path ~ /^tests\//) return "tests"
      return "other"
    }
    BEGIN {
      while ((getline entry < allow_files) > 0) if (entry != "") allowed_file[entry] = 1
      while ((getline entry < exempt) > 0) if (entry != "") exempt_line[entry] = 1
      while ((getline name < tracked) > 0) {
        if (name in allowed_file) continue
        if (tolower(name) !~ /firstmate|fm-/) continue
        name_hits++
      }
    }
    {
      i = index($0, ":")
      path = substr($0, 1, i - 1)
      rest = substr($0, i + 1)
      j = index(rest, ":")
      lineno = substr(rest, 1, j - 1)
      text = substr(rest, j + 1)
      if (path in allowed_file) next
      if ((path ":" lineno) in exempt_line) next
      kind = (tolower(text) == "firstmate") ? "word" : "prefix"
      if (kind == "word") { word_occ++; word_file[path] = 1 }
      else { prefix_occ++; prefix_file[path] = 1 }
      surface[path] = classify(path)
      file_occ[path]++
      content_files[path] = 1
    }
    END {
      for (p in word_file) word_files++
      for (p in prefix_file) prefix_files++
      for (p in content_files) {
        content_file_count++
        surface_files[surface[p]]++
      }
      for (p in file_occ) {
        surface_occ[surface[p]] += file_occ[p]
        if (file_occ[p] > worst_occ) { worst_occ = file_occ[p]; worst = p }
      }
      total = word_occ + prefix_occ
      leftovers = total + name_hits
      printf "leftovers: %d (%d text occurrences in %d files, %d file names)\n", \
        leftovers, total, content_file_count + 0, name_hits
      printf "  text  old product word (any case): %d occurrences in %d files\n", word_occ + 0, word_files + 0
      printf "  text  old script prefix (%s): %d occurrences in %d files\n", "fm-", prefix_occ + 0, prefix_files + 0
      printf "  names tracked paths carrying the old name: %d files\n", name_hits
      n = split("docs bin agents tests other", order, " ")
      for (k = 1; k <= n; k++) {
        s = order[k]
        if (!(s in surface_files)) continue
        printf "    %-6s %6d occurrences in %5d files\n", s, surface_occ[s] + 0, surface_files[s] + 0
      }
      if (worst != "") printf "  heaviest file: %s (%d occurrences)\n", worst, worst_occ
      exit (leftovers > 0)
    }
  ' < <(git grep -I -o -n -i -E "$BASE_PATTERN" -- . || true)
}

self_test() {
  local out
  fail() { printf 'not ok - %s\n' "$*"; exit 1; }
  st_dir=$(mktemp -d) || die "cannot create a self-test directory"
  trap 'rm -rf -- "$st_dir"' EXIT
  git -C "$st_dir" init -q || die "cannot initialise a self-test repository"
  git -C "$st_dir" config user.email gate@example.invalid
  git -C "$st_dir" config user.name gate
  printf '%s\n' "Juggernaut is a fork of [Firstmate](https://example.invalid)." >"$st_dir/README.md"
  printf '%s\n' "clean line" >"$st_dir/clean.md"
  git -C "$st_dir" add -A >/dev/null 2>&1 && git -C "$st_dir" commit -qm base >/dev/null 2>&1

  out=$("${BASH_SOURCE[0]}" --root "$st_dir") || fail "allow-listed credit line should pass: $out"
  printf 'ok - allow-listed upstream credit line passes\n'

  printf '%s\n' "old name: Firstmate home" "run bin/fm-old.sh" >>"$st_dir/clean.md"
  printf '%s\n' "#!/usr/bin/env bash" >"$st_dir/fm-old.sh"
  git -C "$st_dir" add -A >/dev/null 2>&1 && git -C "$st_dir" commit -qm leftover >/dev/null 2>&1
  out=$("${BASH_SOURCE[0]}" --root "$st_dir") && fail "leftovers should fail the gate"
  case "$out" in "leftovers: 3 ("*) ;; *) fail "expected 3 leftovers, got: $out" ;; esac
  printf 'ok - old name in prose, old script path, and file name is counted\n'

  git -C "$st_dir" rm -q fm-old.sh
  printf '%s\n' "clean line" >"$st_dir/clean.md"
  git -C "$st_dir" add -A >/dev/null 2>&1 && git -C "$st_dir" commit -qm clean >/dev/null 2>&1
  out=$("${BASH_SOURCE[0]}" --root "$st_dir") || fail "a clean tree should pass: $out"
  printf 'ok - a clean tree reports zero leftovers\n'
}

case "${1:-}" in
--self-test) self_test ;;
--root)
  [ -n "${2:-}" ] || die "--root needs a directory"
  report "$2"
  ;;
--help | -h)
  usage
  ;;
"") report "$ROOT" ;;
*)
  die "unknown argument: $1 (try --help)"
  ;;
esac
