# cleanup.record: addyosmani/agent-skills

Extends what firstmate records on the work item before `bin/fm-teardown.sh`.

## Decision record

When the project keeps no decision record of its own, such as an ADR directory or a decision log, add a decision record to the work item in the shape `documentation-and-adrs` gives it: the context, the decision, the alternatives considered with why each was rejected, and the consequences.
When the project keeps its own record, leave the work item as firstmate already records it; the project's record is written by the ship, not by firstmate.
