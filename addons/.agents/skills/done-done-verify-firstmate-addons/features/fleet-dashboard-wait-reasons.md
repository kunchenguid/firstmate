# Fleet dashboard wait reasons

## User outcome

Insights names each waiting task's recorded reason, leaves only missing reasons under Unclassified, and excludes parked in-flight tasks from Open.

## Drive

Run `DASH_HOME=<home> FLOW_JSON=<saved fm-flow --json --capacity run of it> FM_BIN=<Firstmate bin/> done-done run fleet-dashboard-wait-reasons`. The committed `fleet-dashboard/run-proof.sh` builds and serves the dashboard from this checkout against that home's real fleet data, opens Insights at 390px with `chrome-devtools-axi`, and captures the page. A live fm-flow run takes minutes, so save it first with `FM_HOME=<home> bash fleet-flow/bin/fm-flow.sh --json --capacity` from a bin/ dir that holds its helper libraries.

## Evidence

`after.png` shows the Open tile ("active only", parked count beside it), the "Why work waits now" groups and the expanded "Parked by captain" group; `card.txt` holds the same text. Check that no group is called Unclassified, each wait group names a real reason, and any "No reason recorded" row names its home and task. Do not use synthetic fixtures as the real-fleet proof.
