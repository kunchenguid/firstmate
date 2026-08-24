#!/usr/bin/env bash
# fm-backpass-analyse.sh - the standing daily backpass analysis pass, write-free,
# run inside the morning-check/restart window BEFORE the homes are woken
# (captain's words 23.08.: "vor dem wecken der secondmates ausfuehren", 24.08.:
# "es muss laufen, bevor die flotte da ist").
#
# Usage:
#   fm-backpass-analyse.sh probe [--datum YYYY-MM-DD]      attribution probe:
#                                                          numbered checks, each with
#                                                          expected/actual; exit != 0 on fail
#   fm-backpass-analyse.sh run [--datum YYYY-MM-DD]        the daily pass: attribute,
#                                                          analyze write-free, place the
#                                                          template in the day folder
#           [--since <dur>]                                window for fresh transcripts [30h]
#           [--max-transcripts N]                          cap per repo analysis run [24]
#           [--repos name,name,...]                        restrict analysis to these products
#           [--no-analyze]                                 attribution only, no model calls
#   fm-backpass-analyse.sh --help
#
# Why this exists (measured 24.08., firstmate): backpass v0.1.1 reads ONLY the
# legacy default store ~/.claude/projects, so it saw 10 lensclash transcripts
# and nothing else although all four accounts ran all day. Its association also
# misses worker sessions because their worktrees belong to the no-mistakes
# bare mirrors, not to the mother checkout. This tool owns attribution for the
# fleet instead of patching the vendor package.
#
# Attribution rules (this header is the single owner):
#   Stores: the colon-separated roots in FM_BACKPASS_STORES. Default: the four
#   account stores ~/.claude1..4/projects plus the legacy ~/.claude/projects
#   that plain `claude` still writes to.
#   Each fresh transcript's head lines are read for its recorded cwd (that
#   field is the authority, the munged directory name is not). The cwd is then
#   classified by git metadata only:
#     - `<cwd>/.git` FILE -> gitdir pointer -> strip the trailing
#       /worktrees/<id> admin segment -> common git dir.
#     - `<cwd>/.git` DIR -> that directory is the common git dir.
#     - Identity: remote.origin.url basename; fallback for remote-less clones:
#       the <name> segment of a */projects/<name> clone path; final fallback
#       basename. A bare mirror keeps its <hash>.git name and is identified by
#       its remote URL.
#   Classes: product <name> for every identity in data/projects.md except
#   "firstmate"; heim for identity "firstmate" (the leadership repo itself,
#   including its treehouse worktrees) and for cwds with no git context;
#   unresolved-dead for cwds whose whole path is gone and carry no readable
#   git metadata. Heim sessions are NEVER attributed to a product repo.
#
# Write freedom (hard): the run never edits, creates, or deletes anything
# inside a project clone and never invokes `backpass apply`. All scratch lives
# under $FM_HOME/data/backpass-lauf/<product>/ ("runner"): a throwaway git repo
# whose memory files are refreshed COPIES from the main-home clone, plus a
# shadow HOME whose .claude/projects holds COPIES of attributed transcripts
# prefixed with one synthetic line pinning cwd to the runner root, so
# backpass's tier-1 association matches. Every other entry of the real HOME is
# symlinked into the shadow HOME so the model CLIs keep their auth.
# Model choice (measured 24.08.): analysis is pinned to opencode +
# gpt-5.6-luna (accepted end to end); synthesis is pinned to opencode with the
# adapter's default model, because an explicit gpt-5.6-sol id is rejected at
# session setup (ACP -32602) and a claude-opus-5 pin fails on acpx-claude
# (ACP -32603). Override via FM_BACKPASS_ANALYSIS_AGENT/_MODEL/_EFFORT and
# FM_BACKPASS_SYNTHESIS_AGENT/_MODEL/_EFFORT (empty agent = auto ladder,
# empty model = adapter default).
# Extraction proposals target .claude/skills (the Claude harness loads only
# that path; lensclash extraction fix a219ba5f, 24.08.) - proposal text only,
# nothing is ever written.
#
# Output (this header is the single owner):
#   $FM_HOME/data/tagesschluss/<datum>/backpass-attribut.tsv   store, class,
#                                              project, evidence, file, cwd
#   $FM_HOME/data/tagesschluss/<datum>/backpass-vorlage.md     the captain-facing
#                                              template; text proposals only,
#                                              application stays behind the
#                                              individual gate
#   $FM_HOME/data/tagesschluss/<datum>/backpass-<product>.log  raw backpass run log
#   stdout: one summary line ("backpass: ...") meant for morgenpruefung.md
#
# Environment: FM_BACKPASS_STORES, FM_BACKPASS_MAX_REPOS (default 6; repos past
# the cap are named in the template, never silently dropped),
# FM_BACKPASS_TIMEOUT seconds per repo run (default 1800), FM_BACKPASS_JOBS
# (default 1), FM_BACKPASS_RETRY_SLEEP seconds between attempts (default 60;
# one retry per repo - provider hiccups are transient, evidence caches),
# FM_BACKPASS_CMD (default backpass), FM_BACKPASS_REGISTRIES
# (default $FM_HOME/data/projects.md), FM_BACKPASS_CLONE_ROOTS (colon list,
# default $FM_HOME/projects; searched for the memory-file source copies).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
REGISTRY_CACHE=""
REGISTRIES="${FM_BACKPASS_REGISTRIES:-$FM_HOME/data/projects.md}"
STORES="${FM_BACKPASS_STORES:-$HOME/.claude1/projects:$HOME/.claude2/projects:$HOME/.claude3/projects:$HOME/.claude4/projects:$HOME/.claude/projects}"
RUNNER_ROOT="${FM_BACKPASS_RUNNERS:-$FM_HOME/data/backpass-lauf}"
CLONE_ROOTS="${FM_BACKPASS_CLONE_ROOTS:-$FM_HOME/projects}"
BACKPASS_CMD="${FM_BACKPASS_CMD:-backpass}"
MAX_REPOS="${FM_BACKPASS_MAX_REPOS:-6}"
TIMEOUT_SECS="${FM_BACKPASS_TIMEOUT:-1800}"
JOBS="${FM_BACKPASS_JOBS:-1}"
RETRY_SLEEP="${FM_BACKPASS_RETRY_SLEEP:-60}"
ANALYSIS_AGENT="${FM_BACKPASS_ANALYSIS_AGENT-opencode}"
# Fully qualified id: the bare form is only resolvable when opencode's catalog
# query answers inside the probe window; otherwise the adapter gets the bare id
# and rejects it (measured 24.08., ACP -32602).
ANALYSIS_MODEL="${FM_BACKPASS_ANALYSIS_MODEL-openrouter/openai/gpt-5.6-luna}"
ANALYSIS_EFFORT="${FM_BACKPASS_ANALYSIS_EFFORT-medium}"
SYNTHESIS_AGENT="${FM_BACKPASS_SYNTHESIS_AGENT-opencode}"
# Measured 24.08.: opencode rejects an explicit gpt-5.6-sol model id at session
# setup (ACP -32602) even though its catalog lists it - pin the AGENT only and
# let the adapter serve its default model. Set a value here only after probing.
SYNTHESIS_MODEL="${FM_BACKPASS_SYNTHESIS_MODEL-}"
SYNTHESIS_EFFORT="${FM_BACKPASS_SYNTHESIS_EFFORT-high}"

usage() { sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

log() { echo "backpass-analyse: $*"; }
die() { echo "error: $*" >&2; exit 2; }

# ---------------------------------------------------------------- registry --
registry_names() { # product names from the fleet registry, one per line
  local reg
  for reg in $(printf '%s' "$REGISTRIES" | tr ':' ' '); do
    [ -f "$reg" ] || continue
    sed -n 's/^- \([^ []*\) \[.*/\1/p' "$reg"
  done | sort -u
}

in_registry() { # name in registry?
  printf '%s\n' "$REGISTRY_CACHE" | grep -Fxq "$1"
}

# ------------------------------------------------------------- attribution --
read_transcript_cwd() { # first "cwd" in the head of a jsonl transcript
  head -n 40 "$1" 2>/dev/null | grep -m1 -o '"cwd":"[^"]*"' | sed 's/^"cwd":"//; s/"$//' | head -n 1 || true
}

strip_worktrees_admin() { # <common>/worktrees/<id> -> <common>
  local p="$1"
  case "$p" in
    */worktrees/*) printf '%s' "${p%%/worktrees/*}" ;;
    *) printf '%s' "$p" ;;
  esac
}

config_remote_url() { # common git dir -> remote url from its config file ; origin preferred
  local cfg="$1/config"
  [ -f "$cfg" ] || return 0
  local u
  u="$(awk '
    /^\[/ { sec = ($0 ~ /^\[remote "origin"\]/) }
    sec && /^[[:space:]]*url[[:space:]]*=/ { sub(/^[[:space:]]*url[[:space:]]*=[[:space:]]*/, ""); print; exit }
  ' "$cfg")"
  if [ -z "$u" ]; then
    u="$(awk '
      /^\[remote[[:space:]]+"/ { any = 1 }
      !sec && any && /^[[:space:]]*url[[:space:]]*=/ && !found { sub(/^[[:space:]]*url[[:space:]]*=[[:space:]]*/, ""); print; found=1 }
    ' "$cfg")"
  fi
  [ -n "$u" ] && printf '%s' "$u"
}

identity_name_for_common() { # common git dir -> identity name via remote/path shape
  local common="$1" url="" name=""
  url="$(config_remote_url "$common")"
  if [ -n "$url" ]; then
    name="${url##*/}"
    name="${name%.git}"
    [ -n "$name" ] && { printf '%s' "$name"; return 0; }
  fi
  # Remote-less working clone: */projects/<name>/.git[/.git]
  case "$common" in
    */projects/*/.git|*/projects/*/.git/)
      name="$(printf '%s' "$common" | sed 's#/\.git/\?$##; s#/$##; s#.*/projects/##; s#/.*##')"
      [ -n "$name" ] && { printf '%s' "$name"; return 0; }
      ;;
  esac
  case "$common" in
    /*.git) name="$(basename "${common%.git}")" ;;
    *) name="" ;;
  esac
  printf '%s' "$name"
}

classify_cwd() { # prints: class TAB project TAB evidence ; cwd need not exist
  local cwd="$1" probe="$1" common="" name="" depth=0
  while [ -n "$probe" ] && [ "$probe" != "/" ]; do
    if [ -e "$probe/.git" ]; then
      if [ -f "$probe/.git" ]; then
        local ptr
        ptr="$(sed -n 's/^gitdir:[[:space:]]*//p' "$probe/.git" 2>/dev/null | head -1)"
        [ -n "$ptr" ] || break
        common="$(strip_worktrees_admin "$ptr")"
        name="$(identity_name_for_common "$common")"
        if [ ! -e "$cwd" ]; then
          printf 'unresolved-dead\t%s\tgitdir-pointer:%s\n' "$name" "$common"
        else
          printf 'product-or-heim\t%s\tgitdir-pointer:%s\n' "$name" "$common"
        fi
        return 0
      else
        common="$probe/.git"
        name="$(identity_name_for_common "$common")"
        printf 'product-or-heim\t%s\tgit-dir\n' "$name"
        return 0
      fi
    fi
    probe="$(dirname "$probe")"
    depth=$((depth + 1))
    [ "$depth" -gt 12 ] && break
  done
  if [ ! -e "$cwd" ]; then
    local rec
    rec="$(recover_dead_identity "$cwd")"
    if [ -n "$rec" ]; then
      printf 'unresolved-dead\t%s\t%s\n' "$(printf '%s' "$rec" | cut -f1)" "$(printf '%s' "$rec" | cut -f2)"
    else
      printf 'unresolved-dead\t\tdead-path-no-git\n'
    fi
  else
    printf 'heim\t\tno-git\n'
  fi
  return 0
}

recover_dead_identity() { # dead cwd -> "name TAB method" or "" ; uses surviving metadata
  local cwd="$1" hash seg name
  case "$cwd" in
    *.no-mistakes/worktrees/*)
      hash="$(printf '%s' "$cwd" | sed -n 's#.*\.no-mistakes/worktrees/\([^/]*\)/.*#\1#p')"
      [ -n "$hash" ] || return 0
      name="$(config_remote_url "$HOME/.no-mistakes/repos/$hash.git")"
      [ -n "$name" ] || return 0
      name="${name##*/}"; name="${name%.git}"
      [ -n "$name" ] && printf '%s\tmirror-hash:%s\n' "$name" "$hash"
      ;;
    */.treehouse/*)
      seg="$(printf '%s' "$cwd" | sed -n 's#.*\.treehouse/\([^/]*\)/.*#\1#p')"
      [ -n "$seg" ] || return 0
      name="$(printf '%s' "${seg%-*}" | sed 's/-[0-9a-f]\{6\}$//')"
      [ -n "$name" ] && printf '%s\tpool-name:%s\n' "$name" "$seg"
      ;;
  esac
}

final_class() { # collapse raw classification into the four durable classes
  local class="$1" name="$2"
  case "$class" in
    product-or-heim|unresolved-dead)
      if [ "$name" = "firstmate" ]; then
        printf 'heim'
      elif [ -z "$name" ]; then
        printf '%s' "$class"
      elif in_registry "$name"; then
        printf 'product'
      elif [ "$class" = "unresolved-dead" ]; then
        printf 'unresolved-dead'
      else
        printf 'other'
      fi
      ;;
    *) printf '%s' "$class" ;;
  esac
}

sweep_stores() { # cutoff_epoch out_tsv ; emits TSV rows
  local cutoff="$1" tsv="$2" root label ref f cwd cls row
  ref="$(mktemp)"
  touch -d "@$cutoff" "$ref"
  : > "$tsv"
  local ifs_old="$IFS"
  IFS=':'
  for root in $STORES; do
    IFS="$ifs_old"
    [ -d "$root" ] || continue
    label="$(basename "$(dirname "$root")")"
    while IFS= read -r -d '' f; do
      cwd="$(read_transcript_cwd "$f")"
      [ -n "$cwd" ] || cwd="(kein-cwd-im-kopf)"
      row="$(classify_cwd "$cwd")"
      cls="$(final_class "$(printf '%s' "$row" | cut -f1)" "$(printf '%s' "$row" | cut -f2)")"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$label" "$cls" "$(printf '%s' "$row" | cut -f2)" \
        "$(printf '%s' "$row" | cut -f3)" "$f" "$cwd" >> "$tsv"
    done < <(find "$root" -mindepth 2 -maxdepth 2 -name '*.jsonl' -type f -newer "$ref" -print0 2>/dev/null)
    IFS=':'
  done
  IFS="$ifs_old"
  rm -f "$ref"
}

since_epoch() { # "30h"/"2d"/"90m" -> epoch cutoff ; mirrors backpass duration forms
  local s="$1" n u
  case "$s" in
    ''|*[!0-9hdmw]*) die "invalid --since '$s' (use forms like 30h, 2d, 90m)" ;;
  esac
  n="${s%[hdmw]}"; u="${s//[0-9]}"
  case "$u" in
    h) date -d "-$n hours" +%s ;;
    d) date -d "-$n days" +%s ;;
    w) date -d "-$((n * 7)) days" +%s ;;
    m) date -d "-$n minutes" +%s ;;
    *) die "invalid --since '$s'" ;;
  esac
}

# ------------------------------------------------------------------ probe ---
probe_treehouse_expectation() { # munged store dir name -> project name or ""
  local munged="$1" name best=""
  while IFS= read -r name; do
    case "$munged" in
      *"-${name}-"*|*"-${name}")
        if [ "${#name}" -gt "${#best}" ]; then best="$name"; fi
        ;;
    esac
  done <<< "$REGISTRY_CACHE"
  printf '%s' "$best"
}

cmd_probe() {
  local datum tsv
  datum="$(date +%F)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --datum) datum="${2:-}"; shift 2 ;;
      *) die "unknown argument '$1' for probe" ;;
    esac
  done
  REGISTRY_CACHE="$(registry_names | paste -sd '\n' -)"
  tsv="$(mktemp)"
  sweep_stores "$(since_epoch 36h)" "$tsv"

  echo "# Attributions-Probe $datum (Fenster: letzte 36h, echte Sitzungen; Quelle: backpass-attribut-Logik)"
  local fails=0

  # Check 1: treehouse worktree sessions attribute to the pool dir's project.
  # Ground truth is independent of the git pointer chain: the treehouse pool
  # dir name itself carries the project segment.
  local exp bad=0 pos=0 tf cwd cls proj
  while IFS=$'\t' read -r _store cls proj _ev tf cwd; do
    case "$cwd" in
      "$HOME"/.treehouse/*) ;;
      *) continue ;;
    esac
    exp="$(probe_treehouse_expectation "$(basename "$(dirname "$tf")")")"
    [ -n "$exp" ] || continue
    if [ "$cls" = "product" ] && [ "$proj" = "$exp" ]; then
      pos=$((pos + 1))
      [ "$pos" -le 5 ] && echo "ok[$pos] cwd=$cwd expected=product/$exp actual=$cls/$proj"
    else
      bad=$((bad + 1))
      echo "FAIL[$bad] cwd=$cwd expected=product/$exp actual=$cls/${proj:-leer}"
    fi
  done < "$tsv"
  if [ "$pos" -ge 3 ] && [ "$bad" -eq 0 ]; then
    echo "CHECK 1 (Worktree-Sitzungen landen im Mutter-Repo): PASS ($pos positive, 0 falsch)"
  else
    echo "CHECK 1 (Worktree-Sitzungen landen im Mutter-Repo): FAIL ($pos positive, $bad falsch)"
    fails=$((fails + 1))
  fi

  # Check 2 (counter-probe): sessions whose recorded cwd lies in the firstmate
  # home itself (outside its projects/clones subtree) or whose git identity IS
  # firstmate must all be class heim - never product.
  local heim_zone=0 heim_id=0 heim_bad=0
  while IFS=$'\t' read -r _store cls proj _ev _tf cwd; do
    local zone="no"
    case "$cwd" in
      "$FM_HOME" | "$FM_HOME"/*)
        zone="heim-zone"
        case "$cwd" in
          "$FM_HOME"/projects | "$FM_HOME"/projects/*) zone="clone-zone" ;;
        esac
        ;;
    esac
    if [ "$zone" = "heim-zone" ]; then
      heim_zone=$((heim_zone + 1))
      [ "$cls" = "heim" ] || { heim_bad=$((heim_bad + 1)); echo "FAIL-counter cwd=$cwd class=$cls proj=${proj:-leer}"; }
    fi
    if [ "$proj" = "firstmate" ]; then
      heim_id=$((heim_id + 1))
      [ "$cls" = "heim" ] || { heim_bad=$((heim_bad + 1)); echo "FAIL-counter identity-firstmate als $cls: $cwd"; }
    fi
  done < "$tsv"
  if [ "$((heim_zone + heim_id))" -ge 1 ] && [ "$heim_bad" -eq 0 ]; then
    echo "CHECK 2 (Gegenprobe: Firstmate-Heim-Sitzungen landen NICHT in einem Produkt-Repo): PASS ($heim_zone Heim-Zonen-cwds, $heim_id firstmate-Identitaeten, 0 Verstoesse)"
  else
    echo "CHECK 2 (Gegenprobe: Firstmate-Heim-Sitzungen landen NICHT in einem Produkt-Repo): FAIL ($heim_zone Heim-Zonen-cwds, $heim_id firstmate-Identitaeten, $heim_bad Verstoesse)"
    fails=$((fails + 1))
  fi

  # Check 3: no-mistakes worker sessions resolve via the bare mirror remote.
  local nm_pos=0 nm_bad=0
  while IFS=$'\t' read -r _store cls proj ev tf cwd; do
    case "$ev" in
      gitdir-pointer:*"$HOME"/.no-mistakes/repos/*) ;;
      *) continue ;;
    esac
    if [ "$cls" = "product" ] && in_registry "$proj"; then
      nm_pos=$((nm_pos + 1))
      [ "$nm_pos" -le 3 ] && echo "ok-nm[$nm_pos] cwd=$cwd -> product/$proj"
    else
      nm_bad=$((nm_bad + 1))
      echo "FAIL-nm $(basename "$tf") cwd=$cwd class=$cls proj=${proj:-leer}"
    fi
  done < "$tsv"
  if [ "$nm_pos" -ge 1 ] && [ "$nm_bad" -eq 0 ]; then
    echo "CHECK 3 (No-Mistakes-Worker-Sitzungen via Bare-Mirror-Remote): PASS ($nm_pos positive, 0 falsch)"
  else
    echo "CHECK 3 (No-Mistakes-Worker-Sitzungen via Bare-Mirror-Remote): FAIL ($nm_pos positive, $nm_bad falsch)"
    fails=$((fails + 1))
  fi

  # Check 4: the legacy default store reproduces yesterday's measured finding
  # (captain's hand run 24.08.: 10 lensclash transcripts there).
  local legacy_lc=0 store
  while IFS=$'\t' read -r store cls proj _ev _tf _cwd; do
    if [ "$store" = ".claude" ] && [ "$cls" = "product" ] && [ "$proj" = "lensclash" ]; then
      legacy_lc=$((legacy_lc + 1))
    fi
  done < "$tsv"
  if [ "$legacy_lc" -ge 1 ]; then
    echo "CHECK 4 (Legacy-Store reproduziert die lensclash-Fundstelle): PASS ($legacy_lc Transkripte im Fenster)"
  else
    echo "CHECK 4 (Legacy-Store reproduziert die lensclash-Fundstelle): FAIL ($legacy_lc Transkripte im 36h-Fenster)"
    fails=$((fails + 1))
  fi

  rm -f "$tsv"
  if [ "$fails" -gt 0 ]; then
    echo "PROBE ERGEBNIS: $fails CHECK(S) FAIL"
    exit 1
  fi
  echo "PROBE ERGEBNIS: alle Checks PASS"
}

# --------------------------------------------------------------- analysis ---
memory_file_source() { # product -> path to AGENTS.md source or ""
  local product="$1" root cand
  for root in $(printf '%s' "$CLONE_ROOTS" | tr ':' ' '); do
    cand="$root/$product/AGENTS.md"
    [ -f "$cand" ] && { printf '%s' "$cand"; return 0; }
  done
  local root
  for root in "$HOME"/.no-mistakes/repos/*.git; do
    [ -d "$root" ] || continue
    [ "$(git --git-dir="$root" config --get remote.origin.url 2>/dev/null | xargs -r basename 2>/dev/null | sed 's/\.git$//')" = "$product" ] || continue
    if git --git-dir="$root" cat-file -e HEAD:AGENTS.md 2>/dev/null; then
      git --git-dir="$root" show HEAD:AGENTS.md 2>/dev/null | head -1 >/dev/null || true
      printf '%s' "$root"
      return 0
    fi
  done
  printf ''
}

build_runner() { # product transcript_list_file ; echoes runner dir
  local product="$1" list="$2"
  local sb="$RUNNER_ROOT/$product"
  rm -rf "${sb:?}/home"
  mkdir -p "$sb/root" "$sb/home/.claude/projects/farm"
  if [ ! -d "$sb/root/.git" ]; then
    git init -q "$sb/root" || die "git init failed for runner $sb/root"
    git -C "$sb/root" config user.name firstmate-backpass
    git -C "$sb/root" config user.email firstmate@backpass.invalid
  fi

  # Memory files: refresh copies from the main-home clone (or the bare mirror).
  local src
  src="$(memory_file_source "$product")"
  if [ -n "$src" ] && [ -f "$src" ]; then
    cp "$src" "$sb/root/AGENTS.md"
  elif [ -n "$src" ] && [ -d "$src" ]; then
    git --git-dir="$src" show HEAD:AGENTS.md > "$sb/root/AGENTS.md" 2>/dev/null || rm -f "$sb/root/AGENTS.md"
  fi
  local clone_ag
  clone_ag="$FM_HOME/projects/$product/CLAUDE.md"
  [ -f "$clone_ag" ] && cp "$clone_ag" "$sb/root/CLAUDE.md"
  if [ ! -f "$sb/root/AGENTS.md" ] && [ ! -f "$sb/root/CLAUDE.md" ]; then
    printf '# %s\n\n(no memory file found in the source clone; placeholder so backpass does not bootstrap)\n' "$product" > "$sb/root/AGENTS.md"
    printf '%s' "$src" > "$sb/.mem-src-missing"
  else
    rm -f "$sb/.mem-src-missing"
  fi

  # Shadow HOME: symlink every real-HOME entry except the account store dirs
  # (.claude*) so the model CLIs keep their auth; .claude itself is a real dir
  # whose only non-symlinked child is our projects farm.
  local entry
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in .claude*) continue ;; esac
    ln -sfn "$HOME/$entry" "$sb/home/$entry"
  done < <(find "$HOME" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort)
  local ce
  while IFS= read -r ce; do
    [ -n "$ce" ] || continue
    [ "$ce" = "projects" ] && continue
    ln -sfn "$HOME/.claude/$ce" "$sb/home/.claude/$ce"
  done < <(find "$HOME/.claude" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort)

  # Transcript copies: one synthetic first line pins cwd to the runner root.
  local tf base
  while IFS= read -r tf; do
    [ -n "$tf" ] || continue
    base="$(basename "$tf")"
    printf '{"cwd":"%s"}\n' "$sb/root" > "$sb/home/.claude/projects/farm/$base.part"
    cat "$tf" >> "$sb/home/.claude/projects/farm/$base.part"
    mv "$sb/home/.claude/projects/farm/$base.part" "$sb/home/.claude/projects/farm/$base"
  done < "$list"
  printf '%s' "$sb"
}

pinned_flags() { # role agent model effort ; empty agent = omit (auto ladder)
  local role="$1" agent="$2" model="$3" effort="$4"
  [ -n "$agent" ] || return 0
  printf -- '--%s-agent %q ' "$role" "$agent"
  if [ -n "$model" ]; then printf -- '--%s-model %q ' "$role" "$model"; fi
  if [ -n "$effort" ]; then printf -- '--%s-effort %q ' "$role" "$effort"; fi
}

analyse_repo() { # runner since max_transcripts out_log ; exit code carries
  local sb="$1" since="$2" maxt="$3" log="$4" flags="" cmd_rc=0
  flags="$(pinned_flags analysis "$ANALYSIS_AGENT" "$ANALYSIS_MODEL" "$ANALYSIS_EFFORT")$(pinned_flags synthesis "$SYNTHESIS_AGENT" "$SYNTHESIS_MODEL" "$SYNTHESIS_EFFORT")"
  (
    cd "$sb/root"
    # shellcheck disable=SC2086 # flags are intentionally word-split
    timeout "$TIMEOUT_SECS" env HOME="$sb/home" "$BACKPASS_CMD" \
      --since "$since" --harness claude --strict --skills-dir ".claude/skills" \
      --jobs "$JOBS" --max-transcripts "$maxt" $flags > "$log" 2>&1
  ) || cmd_rc=$?
  return "$cmd_rc"
}

render_repo_section() { # product runner log ; markdown on stdout
  local product="$1" sb="$2" log="$3"
  local prop="$sb/root/.backpass/proposal.json" summ="$sb/root/.backpass/evidence-summary.json"
  echo "## $product"
  if [ -f "$sb/.mem-src-missing" ]; then
    echo "- HINWEIS: kein AGENTS.md unter den Klon-Quellen ($CLONE_ROOTS); diese Analyse lief gegen einen Platzhalter."
  fi
  if [ -f "$summ" ]; then
    jq -r '"- Evidenz: \(.analyzedSessions // "?") Sitzungen analysiert, Skill-Extraktions-Vorschlaege: \(.skillExtractions // 0)"' "$summ" 2>/dev/null || true
  fi
  if [ ! -f "$prop" ]; then
    echo "- KEINE Proposal-Ausgabe erzeugt; Log-Auszug:"
    tail -n 15 "$log" 2>/dev/null | sed 's/^/    /' || true
    echo ""
    return 0
  fi
  local n
  n="$(jq '.edits | length' "$prop" 2>/dev/null || echo 0)"
  echo "- Vorschlaege: $n (Textentwurf; Anwendung nur manuell ueber das Einzel-Tor und den Lieferweg des Projekts)"
  jq -r '"- Budget: aktuell \(.budget.current // "?") -> geplant \(.budget.projected // "?") Token \(if .budget.withinBudget then "(im Budget)" else "(UEBER BUDGET)" endif)"' "$prop" 2>/dev/null || true
  jq -r '
    .edits[] |
    "---",
    ("VORSCHLAG \(.id) [\(.kind)] \(.title)"),
    ("Ziel: \(.file)" + (if .skill then " · Skill: \(.skill.name) (\(.skill.description // ""))" else "" end)),
    ("Budget-Delta: \(.deltaTokens // "?" ) Token · Beleg-Sitzungen: \(.transcripts // "?")"),
    "",
    (.rationale // ""),
    "",
    ((.evidence // []) | if length == 0 then empty else "Belege:" end),
    ((.evidence // [])[0:3][] | "- (\(.polarity)) \(.text[0:160]) — \(.source)"),
    ""
  ' "$prop" 2>/dev/null | sed 's#\.agents/skills#.claude/skills#g'
  if jq -e '.edits[] | select(.kind == "extract")' "$prop" >/dev/null 2>&1; then
    echo "- PFADREGEL: Skill-Auslagerungen gehoeren nach .claude/skills/<name>/SKILL.md - die Claude-Harness laedt nur diesen Pfad (Pfad-Fix a219ba5f, 24.08.). In den Vorschlagstexten genannte .agents/skills-Pfade sind hier bereits uebersetzt."
  fi
  echo "- Vollstaendige Rohfassung: $prop"
  echo ""
}

cmd_run() {
  local datum since="30h" maxt="24" analyze="yes" repos_filter=""
  datum="$(date +%F)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --datum) datum="${2:-}"; shift 2 ;;
      --since) since="${2:-}"; shift 2 ;;
      --max-transcripts) maxt="${2:-}"; shift 2 ;;
      --repos) repos_filter="${2:-}"; shift 2 ;;
      --no-analyze) analyze="no"; shift ;;
      *) die "unknown argument '$1' for run" ;;
    esac
  done
  [[ "$datum" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--datum must be YYYY-MM-DD"
  REGISTRY_CACHE="$(registry_names | paste -sd '\n' -)"
  [ -n "$REGISTRY_CACHE" ] || log "WARNUNG: Registry ohne Eintraege ($REGISTRIES) - alles ausser firstmate zaehlt als other"

  local out="$FM_HOME/data/tagesschluss/$datum"
  mkdir -p "$out"
  local tsv="$out/backpass-attribut.tsv"
  sweep_stores "$(since_epoch "$since")" "$tsv"

  local total product_counts heim_n other_n dead_n
  total="$(wc -l < "$tsv")"
  product_counts="$(awk -F'\t' '$2=="product"{c[$3]++} END{for(p in c) printf "%s=%d ", p, c[p]}' "$tsv")"
  heim_n="$(awk -F'\t' '$2=="heim"' "$tsv" | wc -l)"
  other_n="$(awk -F'\t' '$2=="other"' "$tsv" | wc -l)"
  dead_n="$(awk -F'\t' '$2=="unresolved-dead"' "$tsv" | wc -l)"

  local summary="backpass: $total Transkripte im Fenster ($since): Produkte ${product_counts:-keine}; heim=$heim_n, other=$other_n, unaufgeloest=$dead_n"

  local vorlage="$out/backpass-vorlage.md"
  {
    echo "# Backpass-Vorlage $datum (schreibfrei)"
    echo "Erzeugt: $(date -u +%Y-%m-%dT%H:%M:%SZ); Fenster: $since; Max-Analysen je Repo: $maxt"
    echo "Stores: $(printf '%s' "$STORES" | tr ':' ' ')"
    echo "Modelle: analysis=${ANALYSIS_AGENT:-auto}/${ANALYSIS_MODEL:-adapter-default}, synthesis=${SYNTHESIS_AGENT:-auto}/${SYNTHESIS_MODEL:-adapter-default} (Befund 24.08.: Opus-Pin via acpx-claude scheitert ACP -32603; sol-Id via opencode abgelehnt ACP -32602)"
    echo "SCHREIBFREI: dieser Lauf hat keine Projektdateien veraendert und kein apply ausgefuehrt."
    echo "Anwendung: jeder Vorschlag ist Text und wird nur manuell, einzeln und ueber den Lieferweg des Projekts angewendet."
    echo "Extraktions-Pfadregel: Vorschlaege zielen auf .claude/skills (Pfad-Fix a219ba5f, 24.08.)."
    echo ""
    echo "Zuordnung: produkt=${product_counts:-none} heim=$heim_n other=$other_n unaufgeloest=$dead_n (Details: backpass-attribut.tsv)"
    echo ""
  } > "$vorlage"

  if [ "$analyze" = "no" ]; then
    summary="$summary; Analyse uebersprungen (--no-analyze)"
    echo "$summary"
    echo "vorlage: $vorlage"
    return 0
  fi

  # Products with fresh transcripts, busiest first.
  local products
  products="$(awk -F'\t' '$2=="product"{print $3}' "$tsv" | sort | uniq -c | sort -rn | awk '{print $2}')"
  if [ -n "$repos_filter" ]; then
    products="$(printf '%s\n' "$products" | while IFS= read -r q; do
      case ",$repos_filter," in *",$q,"*) printf '%s\n' "$q" ;; esac
    done)"
  fi

  local processed=0 deferred="" failed_repos="" p list count sb logf
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ "$processed" -ge "$MAX_REPOS" ]; then
      deferred="${deferred:+$deferred, }$p"
      continue
    fi
    list="$(mktemp)"
    awk -F'\t' -v prod="$p" '$2=="product" && $3==prod {print $5}' "$tsv" > "$list"
    count="$(wc -l < "$list")"
    sb="$(build_runner "$p" "$list")"
    logf="$out/backpass-$p.log"
    bp_ok="no"
    if analyse_repo "$sb" "$since" "$maxt" "$logf"; then
      bp_ok="yes"
    else
      echo "attempt 1 failed; retrying once after ${RETRY_SLEEP}s (provider hiccups are transient)" >> "$logf"
      sleep "$RETRY_SLEEP"
      analyse_repo "$sb" "$since" "$maxt" "$logf" && bp_ok="yes"
    fi
    if [ "$bp_ok" = "yes" ]; then
      render_repo_section "$p" "$sb" "$logf" >> "$vorlage"
      summary="$summary; $p: analysiert ($count Transkripte im Fenster)"
    else
      failed_repos="${failed_repos:+$failed_repos, }$p"
      {
        echo "## $p"
        echo "- ANALYSE FEHLGESCHLAGEN (Log: $logf); Zuordnung bleibt gueltig ($count Transkripte)."
        echo ""
      } >> "$vorlage"
      summary="$summary; $p: FEHLER (siehe Log)"
    fi
    processed=$((processed + 1))
    rm -f "$list"
    [ "${FM_BACKPASS_KEEP_SANDBOX:-0}" = "1" ] || rm -rf "${sb:?}/home"
  done <<< "$products"

  [ -n "$deferred" ] && {
    {
      echo "## Ueber Kap (verschoben auf Folgetage)"
      echo "- $deferred (FM_BACKPASS_MAX_REPOS=$MAX_REPOS erreicht)"
      echo ""
    } >> "$vorlage"
    summary="$summary; verschoben: $deferred"
  }
  [ -n "$failed_repos" ] && summary="$summary; fehlgeschlagen: $failed_repos"

  echo "$summary"
  echo "vorlage: $vorlage"
}

case "${1:-}" in
  probe) shift; cmd_probe "$@" ;;
  run) shift; cmd_run "$@" ;;
  --help|-h|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
