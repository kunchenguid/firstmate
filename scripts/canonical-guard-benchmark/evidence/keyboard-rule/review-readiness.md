**Ready for human review.** On the final head the rule catches every shape this study threw at it and stays quiet on
every piece of legitimate code it was given, with no false alarm on the untouched branch.

Twenty-three labelled cases were committed on their own branches and put through the project's own
`pnpm check:canonical`. Twenty must fire and all twenty do; three must not fire and none does. That covers the
receiver forms (`window`, `document`, a canvas, `document.body`, a ref's `current`, a local alias, a `.tsx` ref
callback), the placement forms (a helper under `api/hooks` re-exported from the allowed engine path, a non-hook
utility, a file added inside the allowed zone and then renamed out of it), the event-name forms (`'key' + 'down'`,
a module constant), and the invocation forms (`on<channel>` assignment, element access, `.call`, `.apply`,
`Reflect.apply`, a bound method, a destructured method, `Object.assign`). The acknowledgement trailer is correctly
inert for this rule: an `only-inside` violation is reported before the acknowledgement branch is reached, so a
`Canonical-ack: keyboard-listener` trailer with an empty reason does not suppress the diagnostic.

**Nothing found on this head needs fixing before review.** Two defects this study found on earlier heads are worth
recording, because they show what the fixes were made against and what a reviewer should keep pinned:

- The head at `dfcd3b772f` missed five of the thirteen pre-registered cases, in three classes: non-literal event
  names, `on<channel>` assignment, and `EventTarget.prototype.addEventListener.call`. All three are closed.
- The head at `bc14abd53e` closed those but over-corrected: it fired on *any* non-literal first argument without
  asking what the event was, so `const POINTER_DOWN = 'pointerdown'; window.addEventListener(POINTER_DOWN, h)` and
  a hook parameterised on `'pointerdown' | 'pointerup'` were both rejected as keyboard violations. Ordinary code,
  blocked. That head also still passed all seven of the indirect invocation shapes above. Both are closed on the
  final head, which resolves same-file bindings rather than refusing every non-literal.

Two notes for the reviewer, neither a defect:

- The rule is diff-scoped, so it judges only files the branch changed. That is the same posture as the
  duplicate-implementation rule, and the full-tree Vitest boundary is the backstop. The corpus confirms a file
  renamed out of the allowed zone is judged at its new path, and a helper hidden under `api/hooks` and re-exported
  from the allowed engine path is judged where the listener actually registers, not where it is exported.
- The published fixture corpus grew with each fix and now carries labelled cases for the closed classes. The three
  no-fire cases in this study's extension probe - a non-keyboard event held in a constant, one passed as a
  parameter, and the deliberately ignored `input` receiver - are the ones most worth adding there, because they
  are what a future widening of the non-literal branch would break first.
