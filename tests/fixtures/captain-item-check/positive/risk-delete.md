# Retired personalization-data cleanup

## System and purpose

Relvino periodically removes obsolete shared personalization data so storage does not grow forever and current send-time recommendations are not mixed with retired versions.

## Business impact

Maintenance can overlap with a version change and remove data after it becomes active, leaving merchants that rely on shared send-time personalization with missing or fallback recommendations until the data is rebuilt.

## Decision requested

Should destructive maintenance remain disabled until the shared one-at-a-time rule is enforced, or may operators run it knowing a pre-run inspection cannot reveal the race?
