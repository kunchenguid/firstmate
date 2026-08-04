Mode: Cursor CLI local primary (thin adapter).

Cursor CLI (`cursor-agent`) has a local Firstmate launch template for crewmates and secondmates.
It does not yet have verified primary SessionStart or Stop hook parity with Claude, Codex, OpenCode, Pi, or Grok.
Prefer Herdr as `config/backend` so idle, working, and blocked come from the pane lifecycle rather than a Cursor semantic busy source.
At session start, run `bin/fm-session-start.sh` exactly once when this session owns the home.
Follow the generic supervision contract in `AGENTS.md` for watcher waits until a Cursor-specific wake adapter is verified.
Use a bounded foreground wait over `bin/fm-watch.sh` when no tracked background wake mechanism is available.
Never use shell `&` for watcher supervision.
Crew and secondmate launches use `bin/fm-spawn.sh` with harness `cursor`, which starts `cursor-agent --yolo --trust` so tools auto-approve and workspace trust does not block an unattended worker.
Remote secondmate routes still reject `cursor` until remote launch is proven separately.
