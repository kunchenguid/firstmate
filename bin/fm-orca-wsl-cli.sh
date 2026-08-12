#!/usr/bin/env bash
# fm-orca-wsl-cli.sh - status and apply for Firstmate's Orca WSL CLI bridge patch.
#
# Orca on Windows+WSL installs ~/.local/bin/orca-ide and
# ~/.local/share/orca/orca-wsl-bridge.ps1. Stock bridges (at least through
# Orca 1.4.179) forward args with PowerShell 5.1's broken native splat, which
# destroys ASCII double quotes in `orca terminal send --text` and related
# commands (stablyai/orca#12231). Firstmate ships a patched bridge under
# bin/patches/orca-wsl/ and this helper installs or reports its state.
#
# States printed by `status` (and as the apply result):
#   missing   - no bridge and/or launcher under the usual paths
#   stock     - Orca-managed files present without the Firstmate patch marker
#   patched   - Firstmate patch marker present at the expected version
#   foreign   - files exist but do not look like stock Orca or this patch
#
# Usage:
#   fm-orca-wsl-cli.sh status
#   fm-orca-wsl-cli.sh apply [--force]
#   fm-orca-wsl-cli.sh --help
set -euo pipefail

PATCH_ID=firstmate-orca-wsl-bridge-patch-v1
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
PATCH_DIR=$REPO_ROOT/bin/patches/orca-wsl
PATCH_BRIDGE=$PATCH_DIR/orca-wsl-bridge.ps1

XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
SHARE=${FM_ORCA_WSL_SHARE:-$XDG_DATA_HOME/orca}
BIN=${FM_ORCA_WSL_BIN:-$HOME/.local/bin}
BRIDGE=$SHARE/orca-wsl-bridge.ps1
LAUNCHER=$BIN/orca-ide
ORCA_SHIM=$BIN/orca

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

die() { echo "error: $*" >&2; exit 1; }

require_patch_files() {
  [ -f "$PATCH_BRIDGE" ] || die "missing patch bridge template: $PATCH_BRIDGE"
}

file_has_patch_marker() {
  local path=$1
  [ -f "$path" ] || return 1
  grep -Fq "$PATCH_ID" "$path"
}

file_looks_stock_bridge() {
  local path=$1
  [ -f "$path" ] || return 1
  # Stock Orca bridge: managed marker, raw splat, no Firstmate patch id.
  grep -Fq 'Orca managed WSL CLI PowerShell bridge' "$path" \
    && grep -Fq '& $OrcaLauncher @ForwardArgs' "$path" \
    && ! grep -Fq "$PATCH_ID" "$path"
}

file_looks_stock_launcher() {
  local path=$1
  [ -f "$path" ] || return 1
  grep -Fq 'Orca managed WSL CLI launcher' "$path" \
    && grep -Eq 'ORCA_WIN_LAUNCHER=' "$path" \
    && ! grep -Fq "$PATCH_ID" "$path"
}

classify_pair() {
  if [ ! -f "$BRIDGE" ] && [ ! -f "$LAUNCHER" ]; then
    printf 'missing'
    return 0
  fi
  if [ -f "$BRIDGE" ] && file_has_patch_marker "$BRIDGE" \
    && [ -f "$LAUNCHER" ] && file_has_patch_marker "$LAUNCHER"; then
    printf 'patched'
    return 0
  fi
  if [ -f "$BRIDGE" ] && [ -f "$LAUNCHER" ] \
    && file_looks_stock_bridge "$BRIDGE" \
    && file_looks_stock_launcher "$LAUNCHER"; then
    printf 'stock'
    return 0
  fi
  # Partial installs (only one file, mixed stock/patch, hand edits).
  printf 'foreign'
}

extract_win_launcher() {
  local path=$1 line
  [ -f "$path" ] || return 1
  line=$(grep -E '^ORCA_WIN_LAUNCHER=' "$path" | head -1 || true)
  [ -n "$line" ] || return 1
  line=${line#ORCA_WIN_LAUNCHER=}
  line=${line#\'}
  line=${line%\'}
  line=${line#\"}
  line=${line%\"}
  [ -n "$line" ] || return 1
  printf '%s' "$line"
}

discover_win_launcher() {
  local candidate
  if [ -n "${ORCA_WIN_LAUNCHER:-}" ]; then
    printf '%s' "$ORCA_WIN_LAUNCHER"
    return 0
  fi
  if candidate=$(extract_win_launcher "$LAUNCHER" 2>/dev/null); then
    printf '%s' "$candidate"
    return 0
  fi
  # Common Windows install location mounted in WSL.
  for candidate in \
    /mnt/c/Users/*/AppData/Local/Programs/orca/resources/bin/orca.exe
  do
    if [ -f "$candidate" ]; then
      wslpath -w "$candidate"
      return 0
    fi
  done
  return 1
}

print_status() {
  local state
  require_patch_files
  state=$(classify_pair)
  printf 'state=%s\n' "$state"
  printf 'patch_id=%s\n' "$PATCH_ID"
  printf 'bridge=%s\n' "$BRIDGE"
  printf 'launcher=%s\n' "$LAUNCHER"
  if [ -f "$BRIDGE" ]; then
    if file_has_patch_marker "$BRIDGE"; then
      printf 'bridge_kind=patched\n'
    elif file_looks_stock_bridge "$BRIDGE"; then
      printf 'bridge_kind=stock\n'
    else
      printf 'bridge_kind=foreign\n'
    fi
  else
    printf 'bridge_kind=missing\n'
  fi
  if [ -f "$LAUNCHER" ]; then
    if file_has_patch_marker "$LAUNCHER"; then
      printf 'launcher_kind=patched\n'
    elif file_looks_stock_launcher "$LAUNCHER"; then
      printf 'launcher_kind=stock\n'
    else
      printf 'launcher_kind=foreign\n'
    fi
  else
    printf 'launcher_kind=missing\n'
  fi
  if [ -L "$ORCA_SHIM" ] || [ -e "$ORCA_SHIM" ]; then
    printf 'orca_shim=%s\n' "$ORCA_SHIM"
    if [ -L "$ORCA_SHIM" ]; then
      printf 'orca_shim_target=%s\n' "$(readlink "$ORCA_SHIM" || true)"
    fi
  else
    printf 'orca_shim=missing\n'
  fi
  case "$state" in
    missing)
      printf 'note=No Orca WSL CLI files found. Run apply after Orca has created the managed WSL launcher, or pass ORCA_WIN_LAUNCHER for a new install.\n'
      ;;
    stock)
      printf 'note=Stock Orca WSL bridge detected (quotes in terminal send are unsafe on PS 5.1). Run: bin/fm-orca-wsl-cli.sh apply\n'
      ;;
    patched)
      printf 'note=Firstmate Orca WSL bridge patch is installed. Re-run apply after Orca overwrites the bridge on update.\n'
      ;;
    foreign)
      printf 'note=WSL CLI files exist but are neither stock Orca nor this patch. Inspect before apply; use --force to overwrite.\n'
      ;;
  esac
}

backup_file() {
  local path=$1 backup_root=$2 base
  [ -e "$path" ] || return 0
  mkdir -p "$backup_root"
  base=$(basename -- "$path")
  cp -a -- "$path" "$backup_root/$base"
}

write_launcher() {
  local win_launcher=$1 dest=$2
  cat > "$dest" <<EOF
#!/usr/bin/env bash
# $PATCH_ID
# Orca managed WSL CLI launcher (installed by bin/fm-orca-wsl-cli.sh).
set -euo pipefail
ORCA_WIN_LAUNCHER='$win_launcher'
ORCA_BRIDGE_PS1='$BRIDGE'
if command -v pwsh.exe >/dev/null 2>&1; then
  ORCA_POWERSHELL=pwsh.exe
elif [ -x '/mnt/c/Program Files/PowerShell/7/pwsh.exe' ]; then
  ORCA_POWERSHELL='/mnt/c/Program Files/PowerShell/7/pwsh.exe'
elif command -v powershell.exe >/dev/null 2>&1; then
  ORCA_POWERSHELL=powershell.exe
elif [ -x /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe ]; then
  ORCA_POWERSHELL=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
else
  echo "Orca WSL CLI requires Windows interop and could not find powershell.exe." >&2
  exit 1
fi
# Why: a shell can outlive a deleted worktree; keep explicit CLI selectors and
# help usable, and repair cwd before any WSL interop tool tries to resolve it.
ORCA_WSL_CWD=\$(pwd -P 2>/dev/null) || {
  ORCA_WSL_CWD=/
  cd /
}
ORCA_BRIDGE_PS1_WIN=\$(wslpath -w "\$ORCA_BRIDGE_PS1")
ORCA_WSL_CWD_WIN=\$(wslpath -w "\$ORCA_WSL_CWD")
exec "\$ORCA_POWERSHELL" -NoProfile -ExecutionPolicy Bypass -File "\$ORCA_BRIDGE_PS1_WIN" "\$ORCA_WIN_LAUNCHER" -WslCwd "\$ORCA_WSL_CWD_WIN" "\$@"
EOF
  chmod 0755 "$dest"
}

apply_patch() {
  local force=${1:-0} state win_launcher backup_root
  require_patch_files
  state=$(classify_pair)
  case "$state" in
    patched)
      if [ "$force" -ne 1 ]; then
        echo "already patched ($PATCH_ID); pass --force to reinstall"
        print_status
        return 0
      fi
      ;;
    foreign)
      if [ "$force" -ne 1 ]; then
        die "foreign WSL CLI files present (state=foreign); inspect $BRIDGE and $LAUNCHER, or re-run with --force"
      fi
      ;;
    missing|stock) ;;
    *) die "internal: unknown state '$state'" ;;
  esac

  win_launcher=$(discover_win_launcher) || die "cannot discover Windows orca.exe path; set ORCA_WIN_LAUNCHER='C:\\...\\orca.exe'"

  mkdir -p "$SHARE" "$BIN"
  backup_root=$SHARE/firstmate-bridge-backup-$(date +%Y%m%d-%H%M%S)
  backup_file "$BRIDGE" "$backup_root"
  backup_file "$LAUNCHER" "$backup_root"
  if [ -e "$ORCA_SHIM" ]; then
    backup_file "$ORCA_SHIM" "$backup_root"
  fi
  if [ -d "$backup_root" ]; then
    echo "backup: $backup_root"
  fi

  cp -- "$PATCH_BRIDGE" "$BRIDGE"
  write_launcher "$win_launcher" "$LAUNCHER"

  # Ensure bare `orca` resolves to the managed launcher (not GNOME orca).
  if [ -e "$ORCA_SHIM" ] && [ ! -L "$ORCA_SHIM" ]; then
    if [ "$force" -ne 1 ]; then
      echo "warning: $ORCA_SHIM exists and is not a symlink; not replacing (use --force)" >&2
    else
      ln -sfn "$LAUNCHER" "$ORCA_SHIM"
    fi
  else
    ln -sfn "$LAUNCHER" "$ORCA_SHIM"
  fi

  date -Is > "$SHARE/.firstmate-orca-wsl-cli-applied" 2>/dev/null || true
  echo "applied $PATCH_ID"
  echo "win_launcher=$win_launcher"
  print_status
}

cmd=${1:-}
case "$cmd" in
  ""|-h|--help) usage; exit 0 ;;
  status) shift; [ "$#" -eq 0 ] || die "status takes no arguments"; print_status ;;
  apply)
    shift
    force=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --force) force=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown apply flag: $1" ;;
      esac
    done
    apply_patch "$force"
    ;;
  *) die "unknown command: $cmd (try status or apply)" ;;
esac
