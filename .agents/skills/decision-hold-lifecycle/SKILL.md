---
name: decision-hold-lifecycle
description: >-
  Compatibility shim for legacy decision-hold references; the canonical policy
  lives in captain-hold-lifecycle.
user-invocable: false
metadata:
  internal: true
---

# Legacy decision-hold compatibility

`captain-hold-lifecycle` is the sole policy owner for unresolved captain calls and their completion gate.
Load it for the current lifecycle policy; retain this skill only so legacy briefs and references resolve while the `fm-decision-hold.sh` command remains a compatibility interface.
