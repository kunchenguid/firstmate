---
name: updatethecaptain-stop
description: >-
  End the repeating ten-minute worker report loop started by /updatethecaptain.
  Use when the captain invokes /updatethecaptain-stop or asks to stop the updates, stop the reports, or stop being kept posted on the workers.
  Harmless when no report loop is running.
user-invocable: true
metadata:
  internal: true
---

# updatethecaptain-stop

End the repeating report loop that `updatethecaptain` starts.

1. Run `bin/fm-captain-report-timer.sh disarm`.
   It removes the timer whether or not one was armed, so it is safe to run at any time.

2. Tell the captain in one line what happened, in the plain language `AGENTS.md` section 9 requires.
   When the command reports that a timer was removed, say the updates have stopped.
   When it reports that nothing was armed, say plainly that no updates were running, and do not treat that as an error or apologise for it.

Stopping the reports stops only the reports.
The workers keep running, supervision continues exactly as `AGENTS.md` section 8 requires, and anything genuinely captain-relevant still reaches the captain under section 9.
Say so in the same line when workers are still under way, so the captain is not left thinking the fleet went quiet with them.
