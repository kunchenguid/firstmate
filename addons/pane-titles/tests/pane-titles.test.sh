#!/usr/bin/env bash
# Hermetic launch-hook journey: fixture task/home records, prior hook chaining, title export, and reversible install.
set -euo pipefail
ADDON=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
HOME=$T/user; FMH=$T/home; LEAD=$T/lead; XDG_DATA_HOME=$HOME/.local/share
mkdir -p "$HOME/bin" "$FMH/bin" "$FMH/config" "$FMH/state" "$FMH/data" "$LEAD/data" "$T/bin"
cat > "$FMH/state/muxr.meta" <<'EOF'
id=muxr
kind=ship
EOF
cat > "$FMH/data/backlog.md" <<'EOF'
- [ ] muxr - Scroll fix
EOF
cat > "$FMH/bin/fm-tasks-axi.sh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = show ] && [ "$2" = muxr ] || exit 2
title=$(awk -F ' - ' '$1 == "- [ ] muxr" { print $2; exit }' "$FM_HOME/data/backlog.md")
printf '  title: %s\n' "$title"
EOF
chmod +x "$FMH/bin/fm-tasks-axi.sh"
cat > "$FMH/config/launch-env-hook" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "export KEEP_VALUE='chain'" > "$1"
EOF
chmod +x "$FMH/config/launch-env-hook"
cp "$FMH/config/launch-env-hook" "$T/original-hook"
printf '%s\n' '- crewhouse (home: '"$LEAD"'; scope: fixture)' > "$LEAD/data/secondmates.md"
cat > "$T/bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERDR_LOG"
if [ "$1 $2 $3" = '--session fixture pane' ] && [ "$4" = current ]; then printf '{"result":{"pane":{"tab_id":"w1:t1"}}}\n'; fi
EOF
chmod +x "$T/bin/herdr"
export HOME XDG_DATA_HOME HERDR_SESSION=fixture HERDR_LOG=$T/herdr.log
export PATH="$T/bin:$PATH"
"$ADDON/install.sh" --dry-run "$FMH" >/dev/null
"$ADDON/install.sh" "$FMH" >/dev/null
"$ADDON/install.sh" "$FMH" >/dev/null
[ -f "$FMH/state/muxr.meta" ] || { echo 'worker metadata fixture missing' >&2; exit 1; }
FM_HOME="$FMH" FM_TASK_ID=muxr "$FMH/config/launch-env-hook" "$T/worker.exports" > "$T/worker.osc"
[ "$(bash -c '. "$1"; printf "%s|%s" "$KEEP_VALUE" "$CLAUDE_CODE_DISABLE_TERMINAL_TITLE"' _ "$T/worker.exports")" = 'chain|1' ]
grep -Fq $'\033]0;muxr: Scroll fix\007' "$T/worker.osc"
grep -Fq -- '--session fixture tab rename w1:t1 muxr: Scroll fix' "$HERDR_LOG"
env -u FM_TASK_ID FM_HOME="$LEAD" "$FMH/config/launch-env-hook" "$T/lead.exports" > "$T/lead.osc"
[ "$(bash -c '. "$1"; printf "%s" "$CLAUDE_CODE_DISABLE_TERMINAL_TITLE"' _ "$T/lead.exports")" = '1' ]
grep -Fq $'\033]0;Crewhouse lead\007' "$T/lead.osc"
grep -Fq -- '--session fixture tab rename w1:t1 Crewhouse lead' "$HERDR_LOG"
"$ADDON/uninstall.sh" --dry-run "$FMH" >/dev/null
"$ADDON/uninstall.sh" "$FMH" >/dev/null
"$ADDON/uninstall.sh" "$FMH" >/dev/null
cmp "$T/original-hook" "$FMH/config/launch-env-hook"
echo 'PASS: worker and lead titles, Claude switch, Herdr tab rename, chained hook, idempotence, uninstall'
