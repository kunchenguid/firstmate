# Incremental fleet-pulse chat export

## User outcome

The retro entry can refresh private chat TSV without duplicating prior rows or exporting injected wake lines or secrets.

## Drive

Run `bash fleet-pulse/tests/chat-tsv.test.sh` from the repository root. The test creates fake transcripts and a disposable Git home, executes the refresh entry point across three runs, and verifies the appended rows, filtering, and redaction.

## Evidence

Capture the test command's output and exit status in done-done's run evidence directory. Do not use real transcripts.
