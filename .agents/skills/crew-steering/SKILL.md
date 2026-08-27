---
name: crew-steering
description: >-
  Agent-only practice for concise crewmate briefs and live corrections.
  Load before writing or materially revising a crewmate or secondmate brief and before live-steering a crewmate, especially when ownership, recursive unblocking, validation custody, evidence, or goal fidelity is drifting.
user-invocable: false
metadata:
  internal: true
---

# Crewmate steering

Use the smallest instruction that restores ownership of the captain's actual outcome.
A brief or steer names the result, authority boundary, evidence, and next action, then stops.
Point to the existing owner for procedure instead of copying its contract.

## Brief the outcome

State the concrete result and acceptance criteria before background.
Name only constraints that change the worker's choices, plus the owning docs and scripts it must consult.
Keep the definition of done observable and proportional to the task.
Preserve mandatory safety stops, especially an unsafe or non-isolated worktree and any budget, credential-custody, irreversible-data-loss, or unlanded-work boundary.

## Keep ownership live

The crewmate owns solution and execution through proof, not merely an attempt or recommendation.
Do not accept `almost there`, a passing neighboring test, or an unexplained stop as completion.
Correct the smallest load-bearing mistake early and require the worker to carry that correction through implementation and direct evidence.
Reject any quiet reframing of the captain's goal into a smaller win.

## Unblock before escalating

When work reports blocked, ask which safe alternate method, resource, sequence, task split, or eligible lane was tried.
Apply the same question recursively to a failed alternate while unaffected work continues.
Do not route around safety or expand scope merely to stay busy.
Escalate only a genuinely captain-owned action or an evidence-backed exhaustion of materially independent safe routes.

## Hold validation custody

The worker that starts validation owns every synchronous gate return through CI green, failure with evidence, or a new decision.
A parked approval or fix-review step is not `paused:`; steer the worker to the current gate help and response.
Do not let the worker hand-edit around, duplicate, abort, or restart a pipeline-owned fix.
Keep additional ready work in the bounded validation queue rather than overloading shared capacity.

## Finish cleanly

Require the promised artifact, verification, standalone report, and applicable landing evidence before accepting a terminal claim.
End a steer with the concrete next action and proof expected from it.
Do not add motivational padding, duplicate background, or another copy of existing procedure.
