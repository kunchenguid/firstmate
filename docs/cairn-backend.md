# Cairn runtime backend

`cairn` runs local ships, scouts, and second mates in Cairn workspaces.
First Mate still owns task records and uses Treehouse for ship and scout worktrees.
Remote second mates continue to use Herdr.

Set `FM_BACKEND=cairn`, put `cairn` in the local `config/backend`, or start First Mate in a Cairn terminal.
Automatic selection requires both `CAIRN_INSTANCE_STATE_DIR` and `CAIRN_WORKSPACE_ID`, an authenticated ping to that instance, and the launching workspace in its live workspace inventory.
Tmux and Herdr markers take precedence when nested.

The bundled `cairnctl` client talks to the authenticated Developer API.
`CAIRNCTL` can select another client binary, including a fake for tests.
`FM_CAIRN_STATE_DIR` selects a particular instance for an explicit launch from outside Cairn.
Each task record pins the canonical state directory, original instance PID, First Mate home, workspace ID, and pane ID.
The original PID is provenance; reconnects can change it without changing the state directory or bound endpoint.

Each fresh task gets one background workspace and one pane.
Cairn persists the exact home and task binding.
First Mate refuses a fresh launch when that binding already exists without its task record.
Capture and input address the recorded pane, and stop refuses a workspace containing additional panes.
An unavailable app, unreadable pane, or uncertain process state retains the task record.
Polling remains the status fallback.

Run `tests/fm-backend-cairn.test.sh` for the fake-client adapter checks.
The Cairn checkout runs `DeveloperAPIControlTests` and the branded app build and install checks.
The active verification record is [`docs/verification/runtime-backends.md`](verification/runtime-backends.md).
