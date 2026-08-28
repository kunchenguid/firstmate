# Example fast-mode config for bin/fm-fast-mode.sh.
#
# Copy to config/fast-mode/<repo-name>.sh, where <repo-name> is the basename of
# the project's `origin` remote, then replace everything below with the real
# paths and commands. Configs stay local and untracked on purpose.
#
# bin/fm-fast-mode.sh's header owns the full contract; this file is only a
# starting shape for a two-process project (an API and a frontend dev server).

FAST_PRIMARY=/absolute/path/to/the/primary/checkout
FAST_REQUIRE_DIRS="server web"

FAST_PREF_API=8100
FAST_PREF_WEB=3100
FAST_PREF_PROXY=3300

FAST_API_PREFIX=/api/
FAST_READY_PATH=/
FAST_WEB_CACHE="web/.next web/node_modules/.vite"

fast_prepare() {
  # Credentials and other gitignored inputs the fresh worktree does not have.
  # Copy them from the primary checkout, and give the backend $FAST_ORIGIN - the
  # proxy origin the browser actually uses - as its allowed origin.
  grep -vE '^(PORT|CORS_ORIGIN)=' "$FAST_PRIMARY/server/.env" >"$FAST_WT/server/.env"
  {
    echo "PORT=$FAST_API_PORT"
    echo "CORS_ORIGIN=$FAST_ORIGIN"
  } >>"$FAST_WT/server/.env"
  git -C "$FAST_WT" check-ignore -q server/.env ||
    { echo "server/.env is not gitignored, refusing to write credentials there" >&2; return 1; }

  [ -d "$FAST_WT/web/node_modules" ] || (cd "$FAST_WT/web" && pnpm install >"$FAST_RUN/install.log" 2>&1)
}

fast_start_api() {
  # Build to one binary first where that applies: a run-from-source wrapper
  # spawns a child, and then the port cannot be stopped by killing the wrapper.
  (cd "$FAST_WT/server" && go build -o "$FAST_RUN/api-bin" .)
  (cd "$FAST_WT/server" && fast_bg api "$FAST_RUN/api-bin")
}

fast_start_web() {
  (cd "$FAST_WT/web" && fast_bg web pnpm dev -p "$FAST_WEB_PORT")
}
