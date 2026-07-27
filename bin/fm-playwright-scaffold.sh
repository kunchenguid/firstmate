#!/usr/bin/env bash
# Drop a ready headless Playwright QA harness into a project worktree.
# Writes a playwright.config.ts pinned to named viewports (headless, isolated -
# Playwright's own bundled Chromium in an ephemeral context, never the captain's
# real Chrome), an example spec under qa/specs/, a qa/screenshots/ evidence dir,
# and a qa/.gitignore that keeps run artifacts out of git. It never installs
# dependencies: Playwright installs into the target project, not into firstmate,
# and the printed next steps carry the exact install/run commands.
# Existing files are kept by default and only overwritten with --force, so a
# re-run is a safe idempotent no-op that never clobbers a crewmate's edits.
# This is a worktree utility for crewmates paired with the playwright-qa skill,
# not a supervision script, so it does not call fm-guard.sh.
# Usage: fm-playwright-scaffold.sh [--dir <project-dir>] [--viewports "name:WxH,..."] [--force]
set -eu

DEFAULT_VIEWPORTS="desktop-1857x933:1857x933,laptop-1440x900:1440x900"

usage() {
  cat >&2 <<'EOF'
usage: fm-playwright-scaffold.sh [--dir <project-dir>] [--viewports "name:WxH,..."] [--force]

Drops a headless Playwright QA harness into a project worktree.

flags:
  --dir <path>          target project dir (default: current directory)
  --viewports "<list>"  comma-separated name:WIDTHxHEIGHT entries
                        (default: desktop-1857x933:1857x933,laptop-1440x900:1440x900)
  --force               overwrite existing scaffold files instead of keeping them
  -h, --help            show this help

examples:
  fm-playwright-scaffold.sh --dir projects/my-app
  fm-playwright-scaffold.sh --viewports "wide:1920x1080,phone:390x844"
EOF
}

DIR="."
VIEWPORTS="$DEFAULT_VIEWPORTS"
FORCE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --dir)
      [ "$#" -ge 2 ] || { echo "error: --dir requires a value" >&2; echo "help: fm-playwright-scaffold.sh --dir <project-dir>" >&2; exit 2; }
      DIR="$2"
      shift 2
      ;;
    --viewports)
      [ "$#" -ge 2 ] || { echo "error: --viewports requires a value" >&2; echo "help: fm-playwright-scaffold.sh --viewports \"name:WxH,...\"" >&2; exit 2; }
      VIEWPORTS="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      echo "help: valid flags are --dir, --viewports, --force (--help always allowed)" >&2
      exit 2
      ;;
  esac
done

[ -d "$DIR" ] || { echo "error: not a directory: $DIR" >&2; echo "help: pass an existing project worktree with --dir <path>" >&2; exit 1; }
DIR=$(cd "$DIR" && pwd -P)

# Validate and normalize the viewport list before writing anything.
PROJECT_LINES=""
VIEWPORT_ROWS=""
SEEN_NAMES=""
OLD_IFS="$IFS"
IFS=','
for entry in $VIEWPORTS; do
  IFS="$OLD_IFS"
  [ -n "$entry" ] || continue
  case "$entry" in
    *:*x*) : ;;
    *)
      echo "error: bad viewport entry: $entry" >&2
      echo "help: each entry is name:WIDTHxHEIGHT, e.g. desktop-1857x933:1857x933" >&2
      exit 2
      ;;
  esac
  name=${entry%%:*}
  size=${entry#*:}
  width=${size%x*}
  height=${size#*x}
  case "$name" in
    ''|*[!A-Za-z0-9._-]*)
      echo "error: bad viewport name: '$name' in '$entry'" >&2
      echo "help: names use letters, digits, dot, underscore, or dash" >&2
      exit 2
      ;;
  esac
  case "$width" in
    ''|*[!0-9]*)
      echo "error: bad viewport size: '$size' in '$entry'" >&2
      echo "help: size is WIDTHxHEIGHT in pixels, e.g. 1440x900" >&2
      exit 2
      ;;
  esac
  case "$height" in
    ''|*[!0-9]*)
      echo "error: bad viewport size: '$size' in '$entry'" >&2
      echo "help: size is WIDTHxHEIGHT in pixels, e.g. 1440x900" >&2
      exit 2
      ;;
  esac
  case " $SEEN_NAMES " in
    *" $name "*)
      echo "error: duplicate viewport name: '$name' in '$entry'" >&2
      echo "help: each viewport name must be unique" >&2
      exit 2
      ;;
  esac
  SEEN_NAMES="${SEEN_NAMES} ${name}"
  PROJECT_LINES="${PROJECT_LINES}    { name: '${name}', use: { ...devices['Desktop Chrome'], viewport: { width: ${width}, height: ${height} } } },"$'\n'
  VIEWPORT_ROWS="${VIEWPORT_ROWS}  ${name},${width}x${height}"$'\n'
  IFS=','
done
IFS="$OLD_IFS"

[ -n "$PROJECT_LINES" ] || { echo "error: no valid viewports parsed from: $VIEWPORTS" >&2; exit 2; }

viewport_count=$(printf '%s' "$VIEWPORT_ROWS" | grep -c '^')

# write_file <relpath> <content>: create the file, or keep an existing one
# unless --force. Records the disposition into FILE_ROWS for the summary.
FILE_ROWS=""
write_file() {
  local rel="$1" content="$2" abs status
  abs="$DIR/$rel"
  if [ -e "$abs" ] && [ "$FORCE" -ne 1 ]; then
    status="kept"
  else
    mkdir -p "$(dirname "$abs")"
    printf '%s' "$content" > "$abs"
    if [ "$FORCE" -eq 1 ]; then
      status="written"
    else
      status="created"
    fi
  fi
  FILE_ROWS="${FILE_ROWS}  ${rel},${status}"$'\n'
}

CONFIG_TS="import { defineConfig, devices } from '@playwright/test';

// Firstmate Playwright QA harness - generated by fm-playwright-scaffold.sh.
// Headless and isolated by default: Playwright launches its own bundled
// Chromium in a fresh, throwaway browser context and never attaches to the
// captain's real Chrome profile. Each named project pins an exact viewport so
// screenshots are deterministic, comparable visual evidence.
export default defineConfig({
  testDir: './qa/specs',
  outputDir: './qa/results',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? [['github'], ['list']] : [['list']],
  use: {
    headless: true,
    screenshot: 'only-on-failure',
    trace: 'on-first-retry',
  },
  projects: [
${PROJECT_LINES}  ],
});
"

SPEC_TS="import { test, expect } from '@playwright/test';

// Example QA spec generated by fm-playwright-scaffold.sh.
// Replace the URL and assertions with the flow from your QA brief, then commit
// this file so the project's CI re-runs it every release. The screenshot is
// exact-viewport visual evidence and MUST exist before a visual deliverable is
// called verified - see the playwright-qa skill.
//
// Set QA_BASE_URL to point the run at your app (a dev server, a preview URL, or
// a file:// URL for a static page). Runs once per named viewport project.
test('landing page renders its main heading', async ({ page }, testInfo) => {
  await page.goto(process.env.QA_BASE_URL ?? 'http://localhost:3000/');
  await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
  await page.screenshot({
    path: \`qa/screenshots/example-\${testInfo.project.name}.png\`,
  });
});
"

GITIGNORE="# Playwright QA run artifacts - traces, videos, and the HTML report.
# Screenshots live in qa/screenshots/ and are committed as evidence.
results/
"

GITKEEP="# Committed screenshots from Playwright QA runs land here as visual evidence.
# Keep this file so the directory exists before the first run.
"

write_file "playwright.config.ts" "$CONFIG_TS"
write_file "qa/specs/example.spec.ts" "$SPEC_TS"
write_file "qa/.gitignore" "$GITIGNORE"
write_file "qa/screenshots/.gitkeep" "$GITKEEP"

REL_DIR=$DIR
case "$DIR" in
  "$HOME"/*) REL_DIR="~${DIR#"$HOME"}" ;;
esac

printf 'scaffold: playwright QA harness in %s\n' "$REL_DIR"
printf 'files[%s]{path,status}:\n' "$(printf '%s' "$FILE_ROWS" | grep -c '^')"
printf '%s' "$FILE_ROWS"
printf 'viewports[%s]{name,size}:\n' "$viewport_count"
printf '%s' "$VIEWPORT_ROWS"
printf 'help[3]:\n'
printf '  Install: (cd %s && npm install -D @playwright/test && npx playwright install chromium)\n' "$REL_DIR"
printf '  Run headless at every viewport: (cd %s && npx playwright test)\n' "$REL_DIR"
printf '  Commit qa/specs/*.spec.ts and qa/screenshots/*.png as CI tests and visual evidence\n'
