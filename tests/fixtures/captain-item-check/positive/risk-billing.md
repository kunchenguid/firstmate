# Advertising-results billing

## System and purpose

Relvino imports each merchant's daily advertising results from Meta so the dashboard can show campaign performance and billing can use only verified advertising spend.

## Business impact

If one run loses ownership while saving results, a partial report can be labeled complete, causing an activated merchant to see wrong performance totals and potentially be charged from unverified spend.
The schedule is currently disabled, so no merchant is exposed today.

## Fix cost

The fix must make the database reject results from a run that no longer owns the work, adding coordination and potentially delaying reports when two runs overlap.

## Leave cost

Leaving it unchanged means activation could create incorrect merchant bills and unreliable advertising reports, so the disabled schedule must remain the safety boundary.

## Decision requested

Should the schedule stay disabled until ownership is enforced at the final save, or should Relvino accept the billing risk and activate it sooner?
