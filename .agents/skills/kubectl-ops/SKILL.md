---
name: kubectl-ops
description: >-
  Agent-only load stub for safe kubectl and K3s operations.
  Use before any `kubectl` operation: applying or deleting resources, `kubectl cp`, exec into pods, scaling, draining, or any operation that reads or changes cluster state.
  The procedure lives in skills/kubectl-ops/SKILL.md; read and follow that file completely after loading this stub.
user-invocable: false
metadata:
  internal: true
---

# kubectl-ops

This stub exists because firstmate loads skills from `.agents/skills/`, while the authoritative procedure lives in the public installer skill at [`skills/kubectl-ops/SKILL.md`](../../../skills/kubectl-ops/SKILL.md).

After this stub loads, read and follow that file completely.
Never treat this stub as the procedure owner.
