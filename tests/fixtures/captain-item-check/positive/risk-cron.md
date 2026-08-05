# Monthly send-time recommendation refresh

## System and purpose

On the first day of each month, Relvino rebuilds shared send-time recommendations from accumulated shopping journeys so newer merchants get useful timing before they have enough data of their own.

## Business impact

After publishing the replacement, the unattended job removes expired recommendation data using machine settings that can select the wrong production data.
If that happens, every merchant using shared timing could lose those recommendations until a rebuild finishes.

## Fix cost

The fix must bind deletion to the verified destination and current version, adding a shared safety step to the monthly refresh.
Disabling the job meanwhile lets recommendations age or expire and makes newer merchants fall back to less informed timing.

## Leave cost

Allowing the job to run keeps recommendations fresh and storage bounded, but a bad machine setting or overlapping update could delete active data with no person present to intervene.

## Decision requested

Should the September 1 run be disabled until deletion proves it targets the intended data and current version, or should it run to preserve recommendation freshness despite that data-loss risk?
