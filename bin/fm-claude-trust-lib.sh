# shellcheck shell=bash
# Pre-accepts Claude Code's per-folder workspace-trust dialog for a worktree
# before launch, so a claude crewmate/secondmate never hangs on the "Is this
# a project you created or one you trust?" prompt on a brand-new worktree.
# --dangerously-skip-permissions bypasses TOOL permissions only, not this
# dialog (verified live: a fresh untrusted directory still shows it under
# that flag).
#
# Claude Code persists per-folder trust in <config-dir>/.claude.json under
# projects["<abs-worktree-path>"].hasTrustDialogAccepted (verified against
# real trusted entries in ~/.claude.json, 2026-08-13, Claude Code 2.1.231).
# <config-dir> is $CLAUDE_CONFIG_DIR when set, else $HOME - the same variable
# bin/fm-spawn.sh already forwards onto the claude launch command, so the file
# this writes is the exact file the launched process reads.
#
# Concurrency: multiple crews spawn claude workers in parallel, and every
# running claude process itself reads and rewrites this same file. This
# library only serializes firstmate's OWN writers against each other, at a
# lock path the caller acquires with fm_claude_trust_lock_acquire
# (sourced separately; not sourced here to avoid a second copy of that lock
# owner). Every write is read-modify-write to a temp file in the same
# directory followed by an atomic rename, so a firstmate write can never
# leave a half-written file, and every key besides the one project entry's
# hasTrustDialogAccepted passes through untouched.
#
# Usage: . bin/fm-claude-trust-lib.sh   (no FM_* setup required)

# fm_claude_trust_json_path: absolute path to the .claude.json this worktree's
# claude launch will read.
fm_claude_trust_json_path() {
  printf '%s/.claude.json\n' "${CLAUDE_CONFIG_DIR:-$HOME}"
}

# fm_claude_trust_lock_path: the lock path callers pass to
# fm_claude_trust_lock_acquire/fm_lock_release around fm_claude_pretrust_worktree.
fm_claude_trust_lock_path() {
  printf '%s.fm-spawn-lock\n' "$(fm_claude_trust_json_path)"
}

# fm_claude_trust_ensure_dir: creates the config directory holding .claude.json
# if missing. The caller MUST run this before fm_claude_trust_lock_acquire on the
# trust lock: the lock's own owner-dir machinery resolves its path by `cd`ing
# into the lock's parent directory, so acquiring the lock against a directory
# that does not exist yet loops forever instead of failing - this call is what
# turns a not-yet-onboarded CLAUDE_CONFIG_DIR into a normal first use instead
# of a silent hang.
fm_claude_trust_ensure_dir() {
  local dir probe
  dir=$(dirname "$(fm_claude_trust_json_path)") || return 1
  (umask 077; mkdir -p "$dir") || return 1
  probe=$(umask 077; mktemp "$dir/.fm-claude-trust-write-test.XXXXXX") || return 1
  rm -f "$probe"
}

fm_claude_trust_lock_acquire() {
  local lock=$1 attempts=0
  while [ "$attempts" -lt 100 ]; do
    if [ -e "$lock" ] && [ ! -d "$lock" ] && [ ! -L "$lock" ]; then
      return 1
    fi
    fm_lock_try_acquire "$lock" && return 0
    attempts=$((attempts + 1))
    sleep 0.1
  done
  return 1
}

fm_claude_trust_file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

# fm_claude_pretrust_worktree <abs-worktree-path>: idempotently ensures
# <config-dir>/.claude.json marks <abs-worktree-path> as trusted, creating the
# file or the project entry only when missing. The caller must have already
# run fm_claude_trust_ensure_dir and must hold the lock from
# fm_claude_trust_lock_path for the duration of this call.
#
# Fails loudly (non-zero, message on stderr) instead of silently skipping,
# including when jq is missing or the existing file fails to parse as JSON: a
# silent skip would reintroduce the exact dialog this function exists to
# prevent, and rewriting a file this cannot parse risks losing content a
# structural merge can't see.
fm_claude_pretrust_worktree() {
  local wt=$1 json_path tmp status mode=
  [ -n "$wt" ] || { echo "fm-claude-trust: no worktree path given" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || {
    echo "fm-claude-trust: jq is required to pre-trust '$wt' for claude; install jq" >&2
    return 1
  }
  json_path=$(fm_claude_trust_json_path)
  if [ -L "$json_path" ]; then
    echo "fm-claude-trust: $json_path is a symlink; refusing to replace it" >&2
    return 1
  fi
  tmp=$(umask 077; mktemp "$json_path.fm-spawn-tmp.XXXXXX") || {
    echo "fm-claude-trust: failed to create a private temporary file beside $json_path" >&2
    return 1
  }
  if [ -e "$json_path" ]; then
    if ! jq -e . "$json_path" >/dev/null 2>&1; then
      rm -f "$tmp"
      echo "fm-claude-trust: $json_path is not valid JSON; refusing to touch it" >&2
      return 1
    fi
    mode=$(fm_claude_trust_file_mode "$json_path") || {
      rm -f "$tmp"
      echo "fm-claude-trust: could not read permissions from $json_path; refusing to replace it" >&2
      return 1
    }
    jq --arg path "$wt" '
      .projects //= {} |
      .projects[$path] //= {
        "allowedTools": [],
        "mcpContextUris": [],
        "mcpServers": {},
        "enabledMcpjsonServers": [],
        "disabledMcpjsonServers": [],
        "hasTrustDialogAccepted": false,
        "projectOnboardingSeenCount": 0,
        "hasClaudeMdExternalIncludesApproved": false,
        "hasClaudeMdExternalIncludesWarningShown": false
      } |
      .projects[$path].hasTrustDialogAccepted = true
    ' "$json_path" > "$tmp"
  else
    jq -n --arg path "$wt" '
      {"projects": {($path): {
        "allowedTools": [],
        "mcpContextUris": [],
        "mcpServers": {},
        "enabledMcpjsonServers": [],
        "disabledMcpjsonServers": [],
        "hasTrustDialogAccepted": true,
        "projectOnboardingSeenCount": 0,
        "hasClaudeMdExternalIncludesApproved": false,
        "hasClaudeMdExternalIncludesWarningShown": false
      }}}
    ' > "$tmp"
  fi
  status=$?
  if [ "$status" -ne 0 ] || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    echo "fm-claude-trust: failed to compose updated $json_path" >&2
    return 1
  fi
  if [ -n "$mode" ] && { ! chmod "$mode" "$tmp" || ! chmod go-rwx "$tmp"; }; then
    rm -f "$tmp"
    echo "fm-claude-trust: could not preserve private permissions for $json_path" >&2
    return 1
  fi
  if ! mv -f "$tmp" "$json_path"; then
    rm -f "$tmp"
    echo "fm-claude-trust: failed to install updated $json_path" >&2
    return 1
  fi
}
