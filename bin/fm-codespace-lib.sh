#!/usr/bin/env bash
# Shared codespace remote-SSH helpers.
#
# FM_CS_ENV_PREFIX is the reusable remote env prefix prepended to EVERY
# non-interactive SSH command firstmate runs in a company-managed Codespace
# (bootstrap, lease, launch in fm-spawn.sh; lease-release in fm-teardown.sh).
# A `gh codespace ssh -- <cmd>` shell is non-login and non-interactive: it does
# not source the user's login profiles, so install dirs like $HOME/.local/bin
# (where the Cursor CLI and a source-built treehouse land) are off PATH, and it
# carries no git credentials. The prefix, in order:
#   1. sources the login profiles so profile-managed PATH entries appear,
#   2. force-adds the standard user bin ($HOME/.local/bin) and Go's bin
#      (/usr/local/go/bin, needed by the treehouse source-build fallback),
#   3. injects the Codespace's GitHub token when the company-managed secrets file
#      is present, so treehouse's `git fetch origin` (and any later push) can
#      authenticate over https.
# It is guarded and best-effort: the token block runs ONLY when
# /workspaces/.codespaces/shared/.env-secrets exists, so personal Codespaces with
# working auth are untouched, and the token value is never printed. It ends with
# ';' so it composes cleanly before any following command. The single quotes are
# deliberate: every $VAR here must expand in the remote shell, not locally.
# FM_CS_ENV_PREFIX is consumed by the scripts that source this lib (fm-spawn.sh,
# fm-teardown.sh), so it is not "unused" here.
# shellcheck disable=SC2016,SC2034
FM_CS_ENV_PREFIX='for _rc in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zprofile" "$HOME/.zshrc"; do [ -f "$_rc" ] && . "$_rc" >/dev/null 2>&1 || true; done; export PATH="$HOME/.local/bin:/usr/local/go/bin:$PATH"; if [ -f /workspaces/.codespaces/shared/.env-secrets ]; then _cstok=$(grep -E "^GITHUB_TOKEN=" /workspaces/.codespaces/shared/.env-secrets | head -1 | cut -d= -f2- | base64 -d 2>/dev/null || true); if [ -n "$_cstok" ]; then export GITHUB_TOKEN="$_cstok" GITHUB_SERVER_URL="https://github.com"; fi; unset _cstok; fi;'
