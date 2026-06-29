#!/usr/bin/env bash
# fm-cs-setup.sh - Cold-machine setup for a codespace crewmate, run INSIDE the
# codespace over SSH (firstmate pipes it in: `gh codespace ssh -c <cs> -- bash -s
# -- <harness> < bin/fm-cs-setup.sh`). Idempotent: on an already-provisioned pool
# machine every step is a fast verify, so re-running is cheap.
#
# Per the captain's policy, provisioning happens at COLD-MACHINE setup, not
# just-in-time per task: when a tool is added here, FREE pool machines are torn
# down and recreated so they bake in the new tool (fm-cs-pool.sh recreate-free).
#
# Installs/verifies, for the crewmate that will run here:
#   - the agent harness CLI (default copilot: `npm install -g @github/copilot`)
#   - no-mistakes (the crewmate drives the validation pipeline itself)
#   - git identity + a working gh auth (codespaces ship a GITHUB_TOKEN)
# Prints one "fm-cs-setup: <result>" summary line per tool and a final
# "fm-cs-setup: READY" (exit 0) or "fm-cs-setup: INCOMPLETE <missing...>"
# (exit 1) so the spawn flow can gate on it.
#
# Auth notes (verified against a live codespace before first dispatch):
#   - copilot authenticates through GitHub; a codespace's native credentials
#     usually satisfy it, so no secret is propagated from firstmate's home.
#   - the no-mistakes SKILL is user-level; if the harness cannot see it in the
#     codespace, installing it is a follow-up live-verification step.
set -u

HARNESS="${1:-copilot}"
MISSING=""
note() { printf 'fm-cs-setup: %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

# A bare `gh codespace ssh -- cmd` runs a non-login shell that lacks the
# codespace's injected GITHUB_TOKEN and ~/.local/bin. Recover both from a login
# shell so the auth check below is meaningful and a freshly user-installed gh is
# visible. (The crewmate itself is always launched via `bash -lc`, so it gets
# this environment natively; this only makes the cold-setup self-contained.)
case ":$PATH:" in *":$HOME/.local/bin:"*) : ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
export PATH
if [ -z "${GITHUB_TOKEN:-}" ]; then
  _login_tok=$(bash -lc 'printf %s "${GITHUB_TOKEN:-}"' 2>/dev/null)
  [ -n "$_login_tok" ] && export GITHUB_TOKEN="$_login_tok"
fi

# --- baseline toolchain (preinstalled in standard codespaces; verify only) ---
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

for t in git node npm curl; do
  if have "$t"; then
    note "$t present ($("$t" --version 2>/dev/null | head -1))"
  else
    note "$t MISSING (expected preinstalled in codespace)"
    MISSING="$MISSING $t"
  fi
done

# --- gh CLI: not every codespace image ships it (e.g. rfeltis/vscode lacks it),
# and the crewmate's no-mistakes pipeline needs it for PR creation. Install a
# sudo-free user-local binary when absent (latest release resolved from the
# GitHub redirect; pinned fallback if the redirect is unreadable). ---
if have gh; then
  note "gh present ($(gh --version 2>/dev/null | head -1))"
else
  note "installing gh (user-local binary)"
  mkdir -p "$HOME/.local/bin"
  gh_ver=$(curl -fsSI https://github.com/cli/cli/releases/latest 2>/dev/null \
    | grep -i '^location:' | sed -E 's#.*/tag/v##' | tr -d '\r\n ')
  [ -n "$gh_ver" ] || gh_ver=2.62.0
  gh_arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
  gh_tgz="gh_${gh_ver}_linux_${gh_arch}"
  if curl -fsSL "https://github.com/cli/cli/releases/download/v${gh_ver}/${gh_tgz}.tar.gz" 2>/dev/null \
       | tar xz -C /tmp 2>/dev/null \
     && cp "/tmp/${gh_tgz}/bin/gh" "$HOME/.local/bin/gh" 2>/dev/null; then
    export PATH="$HOME/.local/bin:$PATH"
    note "gh installed ($("$HOME/.local/bin/gh" --version 2>/dev/null | head -1))"
  else
    note "gh install FAILED (no-mistakes PR step will be unavailable)"
    MISSING="$MISSING gh"
  fi
fi

if have node; then
  node_v=$(node --version 2>/dev/null | sed 's/^v//')
  ver_ge "$node_v" 22.0.0 || note "WARNING node $node_v < 22 (copilot needs >=22)"
fi

# --- gh auth (codespaces expose GITHUB_TOKEN; confirm an identity resolves) ---
if have gh; then
  if gh api user -q .login >/dev/null 2>&1; then
    note "gh auth ok ($(gh api user -q .login 2>/dev/null))"
  else
    note "gh auth UNVERIFIED (no user identity); git push may still work via GITHUB_TOKEN"
  fi
fi

# --- git identity (needed for the crewmate's own commits) ---
if have git; then
  if ! git config --global user.email >/dev/null 2>&1; then
    git config --global user.email "crewmate@firstmate.local"
    git config --global user.name "firstmate crewmate"
    note "git identity set (default)"
  else
    note "git identity present ($(git config --global user.name 2>/dev/null))"
  fi
fi

# --- the agent harness ---
case "$HARNESS" in
  copilot)
    if have copilot; then
      note "copilot present ($(copilot --version 2>/dev/null | head -1))"
    elif have npm; then
      note "installing copilot (npm i -g @github/copilot)"
      if npm install -g @github/copilot >/tmp/fm-copilot-install.log 2>&1; then
        note "copilot installed ($(copilot --version 2>/dev/null | head -1))"
      else
        note "copilot install FAILED (see /tmp/fm-copilot-install.log)"
        MISSING="$MISSING copilot"
      fi
    else
      MISSING="$MISSING copilot"
    fi
    ;;
  claude)  have claude  && note "claude present"  || { note "claude MISSING (install + propagate creds)";  MISSING="$MISSING claude"; } ;;
  codex)   have codex   && note "codex present"   || { note "codex MISSING (install + propagate creds)";   MISSING="$MISSING codex"; } ;;
  pi)      have pi       && note "pi present"      || { note "pi MISSING (install + propagate creds)";       MISSING="$MISSING pi"; } ;;
  opencode) have opencode && note "opencode present" || { note "opencode MISSING"; MISSING="$MISSING opencode"; } ;;
  *) note "unknown harness '$HARNESS'"; MISSING="$MISSING harness:$HARNESS" ;;
esac

# --- no-mistakes (the crewmate's validation pipeline) ---
if have no-mistakes; then
  note "no-mistakes present ($(no-mistakes --version 2>/dev/null | head -1))"
else
  note "installing no-mistakes (canonical installer)"
  if curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh >/tmp/fm-nm-install.log 2>&1 && have no-mistakes; then
    note "no-mistakes installed ($(no-mistakes --version 2>/dev/null | head -1))"
  else
    note "no-mistakes install FAILED (see /tmp/fm-nm-install.log)"
    MISSING="$MISSING no-mistakes"
  fi
fi

MISSING="${MISSING# }"
if [ -n "$MISSING" ]; then
  note "INCOMPLETE $MISSING"
  exit 1
fi
note "READY"
