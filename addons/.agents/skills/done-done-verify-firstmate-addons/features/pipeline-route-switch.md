# Pipeline route switch

## Drive

Run `bash pipeline-quota-failover/tests/switch-route.test.sh` from the repository root. The test drives the real script against a fixture no-mistakes config and stubs pi and Codex on PATH. It verifies that a switch edits only `agent` and `agent_config.<agent>.model`, writes a backup first, leaves the config alone when the model does not answer PONG, restores that backup, and passes `--skip-git-repo-check` to a Codex probe launched from a fresh non-git directory.

## Evidence

Capture the test command's output and exit status in done-done's run evidence directory. Never use a real home, a real model or a real config.
