# Runtime probe pattern

Use this pattern as a starting point for a focused one-off probe or a project test.
Adapt only `render_call` and the artist assertions to the public plotting surface under review.

Set the backend before the Python process imports `matplotlib.pyplot`, preferably at process launch:

```sh
MPLBACKEND=Agg python path/to/probe.py
```

The snapshot must not create a figure merely to ask what is current.
Call `gcf()` and `gca()` only when `get_fignums()` proves that a managed figure already exists.

```python
from copy import deepcopy
from contextlib import ExitStack
from unittest.mock import patch

import matplotlib as mpl
import matplotlib.pyplot as plt
from matplotlib._pylab_helpers import Gcf
from matplotlib.figure import Figure


def snapshot():
    figure_numbers = tuple(plt.get_fignums())
    current_figure = plt.gcf() if figure_numbers else None
    current_axes = plt.gca() if current_figure is not None and current_figure.axes else None
    return {
        "figure_numbers": figure_numbers,
        "current_figure": current_figure,
        "current_axes": current_axes,
        "rc_params": deepcopy(dict(mpl.rcParams)),
        "axes_by_figure": {
            number: tuple(Gcf.figs[number].canvas.figure.axes)
            for number in figure_numbers
        },
    }


def probe(render_call):
    before = snapshot()
    calls = {
        name: []
        for name in ("show", "figure_show", "savefig", "figure_savefig", "close")
    }

    def record(name):
        def recorder(*args, **kwargs):
            calls[name].append((args, kwargs))
        return recorder

    with ExitStack() as stack:
        stack.enter_context(patch.object(plt, "show", record("show")))
        stack.enter_context(patch.object(Figure, "show", record("figure_show")))
        stack.enter_context(patch.object(plt, "savefig", record("savefig")))
        stack.enter_context(patch.object(Figure, "savefig", record("figure_savefig")))
        stack.enter_context(patch.object(plt, "close", record("close")))
        returned = render_call()

    after = snapshot()
    changed_rc = {
        key: (before["rc_params"][key], after["rc_params"][key])
        for key in before["rc_params"]
        if repr(before["rc_params"][key]) != repr(after["rc_params"][key])
    }
    return {
        "before": before,
        "after": after,
        "returned": returned,
        "calls": calls,
        "changed_rc": changed_rc,
    }


def probe_lifecycle(render_call):
    before = snapshot()
    returned = render_call()
    after = snapshot()
    return {"before": before, "after": after, "returned": returned}
```

Patch both pyplot and figure methods for show and save because libraries may use either ownership model.
The probe uses Matplotlib's internal figure-manager registry only to inspect already-managed figures without changing which figure is current.
If the code imported plotting functions into its own module namespace, patch the name looked up by that module as well as, or instead of, the original provider.
Record arguments rather than delegating to show, save, or close during the observation pass so the probe does not destroy the state it needs to inspect.
Treat the observation pass's `after` snapshot as counterfactual whenever intercepted lifecycle calls occurred.
Run `probe_lifecycle` separately with lifecycle methods unpatched and controlled destinations to verify which figures actually remain managed.
Run a separate real save smoke test to `io.BytesIO` when saving is part of the contract, and assert that the buffer is nonempty.

Compare identities with `is` for a caller-provided axes, its figure, and a returned axes or figure.
Compare `before["rc_params"]` and `after["rc_params"]` across the complete key set, and report every changed key.
Use `figure.axes` to account for colorbar and other auxiliary axes rather than assuming one axes per plot.

After `figure.canvas.draw()`, obtain the renderer with `figure.canvas.get_renderer()` and inspect each relevant artist's `get_window_extent(renderer)` against the intended axes or figure bounds.
For annotation contrast, resolve the actual text color and the background color beneath representative annotations, convert both to RGBA, and compare relative luminance or the project's stated accessibility threshold.
Include representative extreme values, missing values, long labels, dense layouts, and small figure sizes only when the public inputs support them.

Wrap each case in cleanup that closes figures created by the case after all assertions complete.
Preserve caller-owned figures long enough to prove that the renderer did not close or relayout them.
