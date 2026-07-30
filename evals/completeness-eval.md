# EVAL: Completeness — "Did the deliverable meet the spec?"

**Applies to:** any deliverable claiming to be done. The eval that runs before an agent moves a task to Done.

## Checks

1. **Every stated requirement met.** Walk the original task line by line; each constraint gets a ✓ or ✗ with evidence (quote/path/screenshot). One unaddressed requirement = FAIL.
2. **Claimed artifacts exist.** Every file path, URL, and ID in the summary actually resolves. A summary that says "saved to X" where X doesn't exist = instant FAIL.
3. **Tested, not just built.** If it's code/automation: was it actually run once end-to-end? Output of the run included?
4. **QA-able in under 2 minutes.** The handback includes absolute paths, direct links, and a preview/summary so Nick can verify without reconstructing context.
5. **Failure honesty.** Anything skipped, partial, or flaky is stated plainly at the top, not buried or omitted.

## Output contract

```
VERDICT: DONE | NOT DONE
REQUIREMENTS TABLE: [requirement -> ✓/✗ -> evidence]
UNVERIFIED CLAIMS: [anything asserted but not demonstrated]
```
