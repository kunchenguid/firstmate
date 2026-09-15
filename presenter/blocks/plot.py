"""Waveform and technical plot builders for presenter.

Generates technical waveform and data plots from numeric arrays or CSV data,
renders them via matplotlib using the Agg backend to PNG images, and returns
standard plot block dicts for document/presentation render engines.
"""

from __future__ import annotations

import csv
from dataclasses import dataclass
import errno
import io
from pathlib import Path
import tempfile
from typing import Any, Mapping, Sequence, TextIO

import matplotlib
# Enforce headless rendering
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np


@dataclass
class PlotTrace:
    """Specification of a single trace/series in a plot."""

    x: Sequence[float] | np.ndarray
    y: Sequence[float] | np.ndarray
    label: str | None = None
    color: str | None = None
    line_style: str | None = None  # e.g., '-', '--', ':', '-.'
    line_width: float | None = None
    marker: str | None = None
    alpha: float | None = None


def format_axis_label(
    label: str | None,
    unit: str | None = None,
    bracket_style: str = "brackets",
) -> str | None:
    """Format an axis label with its measurement unit.

    Args:
        label: Axis name or description (e.g., 'Time', 'Output Voltage').
        unit: Unit of measurement (e.g., 's', 'V', 'mA', 'Hz').
        bracket_style: 'brackets' -> '[unit]', 'parentheses' -> '(unit)'.

    Returns:
        Formatted label string or None if both inputs are None.
    """
    if not label and not unit:
        return None
    if label and not unit:
        return label
    if not label and unit:
        return f"[{unit}]" if bracket_style == "brackets" else f"({unit})"

    if bracket_style == "parentheses":
        return f"{label} ({unit})"
    return f"{label} [{unit}]"


def _ensure_output_path(output_path: str | Path | None = None) -> Path:
    """Resolve an output path or create a safe temporary file."""
    if output_path is not None:
        p = Path(output_path).resolve()
        p.parent.mkdir(parents=True, exist_ok=True)
        return p

    fd, tmp = tempfile.mkstemp(prefix="presenter_plot_", suffix=".png")
    # Close the low-level file descriptor so matplotlib can safely write to it
    import os
    os.close(fd)
    return Path(tmp).resolve()


def build_waveform_plot(
    traces: Sequence[PlotTrace | Mapping[str, Any]] | None = None,
    x: Sequence[float] | np.ndarray | None = None,
    y: Sequence[float] | np.ndarray | Sequence[Sequence[float]] | Mapping[str, Sequence[float]] | None = None,
    *,
    title: str | None = None,
    x_label: str | None = None,
    y_label: str | None = None,
    x_unit: str | None = None,
    y_unit: str | None = None,
    x_log: bool = False,
    y_log: bool = False,
    grid: bool = True,
    grid_style: str = "--",
    grid_alpha: float = 0.5,
    line_style: str = "-",
    line_width: float = 1.5,
    line_styles: Sequence[str] | Mapping[str, str] | None = None,
    colors: Sequence[str] | Mapping[str, str] | None = None,
    legend: bool = True,
    legend_loc: Any = "best",
    x_lim: tuple[float | None, float | None] | None = None,
    y_lim: tuple[float | None, float | None] | None = None,
    figsize: tuple[float, float] = (6.0, 4.0),
    dpi: int = 300,
    caption: str | None = None,
    width_in: float | None = None,
    output_path: str | Path | None = None,
) -> dict[str, Any]:
    """Build a waveform or technical plot and return a standard block dict.

    Args:
        traces: Sequence of PlotTrace or dicts defining series to plot.
        x: Common x coordinates (if traces is None).
        y: y coordinates or series dict (if traces is None).
        title: Optional plot title.
        x_label: Label for the x-axis.
        y_label: Label for the y-axis.
        x_unit: Measurement unit for the x-axis.
        y_unit: Measurement unit for the y-axis.
        x_log: If True, set x-axis scale to logarithmic.
        y_log: If True, set y-axis scale to logarithmic.
        grid: If True, enable background grid.
        grid_style: Linestyle for the grid.
        grid_alpha: Alpha transparency for the grid.
        line_style: Default line style for traces.
        line_width: Default line width for traces.
        line_styles: Optional sequence or mapping of line styles for traces.
        colors: Optional sequence or mapping of line colors.
        legend: If True and labels are present, render legend.
        legend_loc: Matplotlib legend location.
        x_lim: Optional (min, max) limits for x-axis.
        y_lim: Optional (min, max) limits for y-axis.
        figsize: Figure dimensions in inches (width, height).
        dpi: Output image resolution.
        caption: Optional caption for the plot block.
        width_in: Target width in inches for the rendered block.
        output_path: Optional explicit filesystem path for the output PNG.

    Returns:
        A plot block dict:
            {"type": "plot", "source": <png_path>, "caption": ..., "width_in": ...}
    """
    plot_traces: list[PlotTrace] = []

    if traces is not None:
        for i, t in enumerate(traces):
            if isinstance(t, PlotTrace):
                plot_traces.append(t)
            elif isinstance(t, Mapping):
                plot_traces.append(
                    PlotTrace(
                        x=t["x"],
                        y=t["y"],
                        label=t.get("label"),
                        color=t.get("color"),
                        line_style=t.get("line_style"),
                        line_width=t.get("line_width"),
                        marker=t.get("marker"),
                        alpha=t.get("alpha"),
                    )
                )
    elif x is not None and y is not None:
        if isinstance(y, Mapping):
            for key, val in y.items():
                plot_traces.append(PlotTrace(x=x, y=val, label=str(key)))
        elif isinstance(y, (list, tuple, np.ndarray)) and len(y) > 0 and isinstance(y[0], (list, tuple, np.ndarray)):
            for i, series in enumerate(y):
                plot_traces.append(PlotTrace(x=x, y=series, label=f"Trace {i + 1}"))
        else:
            plot_traces.append(PlotTrace(x=x, y=y))  # type: ignore[arg-type]

    if not plot_traces:
        raise ValueError("No plot data provided: pass traces or x and y data")

    fig, ax = plt.subplots(figsize=figsize, dpi=dpi)

    try:
        has_labels = False
        for idx, trace in enumerate(plot_traces):
            # Resolve color
            trace_color = trace.color
            if trace_color is None and colors is not None:
                if isinstance(colors, Mapping) and trace.label is not None and trace.label in colors:
                    trace_color = colors[trace.label]
                elif isinstance(colors, Sequence) and idx < len(colors):
                    trace_color = colors[idx]

            # Resolve line style
            trace_ls = trace.line_style
            if trace_ls is None:
                if line_styles is not None:
                    if isinstance(line_styles, Mapping) and trace.label is not None and trace.label in line_styles:
                        trace_ls = line_styles[trace.label]
                    elif isinstance(line_styles, Sequence) and idx < len(line_styles):
                        trace_ls = line_styles[idx]
                if trace_ls is None:
                    trace_ls = line_style

            # Resolve line width
            trace_lw = trace.line_width if trace.line_width is not None else line_width

            kwargs: dict[str, Any] = {
                "linestyle": trace_ls,
                "linewidth": trace_lw,
            }
            if trace_color is not None:
                kwargs["color"] = trace_color
            if trace.marker is not None:
                kwargs["marker"] = trace.marker
            if trace.alpha is not None:
                kwargs["alpha"] = trace.alpha
            if trace.label is not None:
                kwargs["label"] = trace.label
                has_labels = True

            ax.plot(trace.x, trace.y, **kwargs)

        # Scales
        if x_log:
            ax.set_xscale("log")
        if y_log:
            ax.set_yscale("log")

        # Grid
        if grid:
            ax.grid(True, linestyle=grid_style, alpha=grid_alpha)

        # Labels
        x_full_label = format_axis_label(x_label, x_unit)
        if x_full_label:
            ax.set_xlabel(x_full_label)

        y_full_label = format_axis_label(y_label, y_unit)
        if y_full_label:
            ax.set_ylabel(y_full_label)

        if title:
            ax.set_title(title)

        # Limits
        if x_lim is not None:
            ax.set_xlim(left=x_lim[0], right=x_lim[1])
        if y_lim is not None:
            ax.set_ylim(bottom=y_lim[0], top=y_lim[1])

        # Legend
        if legend and has_labels:
            ax.legend(loc=legend_loc)

        fig.tight_layout()

        # Render to PNG
        resolved_out = _ensure_output_path(output_path)
        fig.savefig(resolved_out, format="png", dpi=dpi, bbox_inches="tight")

    finally:
        plt.close(fig)

    return {
        "type": "plot",
        "source": str(resolved_out),
        "caption": caption,
        "width_in": width_in,
    }


def build_plot(
    traces: Sequence[PlotTrace | Mapping[str, Any]] | None = None,
    x: Sequence[float] | np.ndarray | None = None,
    y: Sequence[float] | np.ndarray | Sequence[Sequence[float]] | Mapping[str, Sequence[float]] | None = None,
    **kwargs: Any,
) -> dict[str, Any]:
    """Alias for build_waveform_plot."""
    return build_waveform_plot(traces=traces, x=x, y=y, **kwargs)


def build_plot_from_arrays(
    x: Sequence[float] | np.ndarray,
    y: Sequence[float] | np.ndarray | Sequence[Sequence[float]] | Mapping[str, Sequence[float]],
    **kwargs: Any,
) -> dict[str, Any]:
    """Build a plot from numeric arrays."""
    return build_waveform_plot(x=x, y=y, **kwargs)


def _looks_like_csv_content(text: str) -> bool:
    """Return True when a string reads as CSV data rather than a file path."""
    if not text.strip():
        return False
    return "\n" in text or "\r" in text


def build_plot_from_csv(
    csv_source: str | Path | TextIO,
    *,
    x_col: str | int = 0,
    y_cols: Sequence[str | int] | None = None,
    delimiter: str = ",",
    has_header: bool = True,
    **kwargs: Any,
) -> dict[str, Any]:
    """Build a waveform plot from CSV data.

    Args:
        csv_source: File path (str or Path), raw CSV string, or readable text
            stream. A str is interpreted as raw CSV content only when it
            contains a line break; otherwise it is treated as a file path and
            must exist (FileNotFoundError is raised otherwise).
        x_col: Column name (str) or index (int) for the x-axis. Defaults to 0.
        y_cols: Column names or indices for the y-axis traces. Defaults to all other columns.
        delimiter: CSV field delimiter. Defaults to ','.
        has_header: Whether the first row represents column header names. Defaults to True.
        **kwargs: Styling and output arguments passed to build_waveform_plot.

    Returns:
        A plot block dict:
            {"type": "plot", "source": <png_path>, "caption": ..., "width_in": ...}
    """
    if isinstance(csv_source, (str, Path)):
        p = Path(csv_source)
        if p.is_file():
            content = p.read_text(encoding="utf-8")
        elif isinstance(csv_source, str) and _looks_like_csv_content(csv_source):
            content = csv_source
        else:
            raise FileNotFoundError(errno.ENOENT, "No such CSV file", str(csv_source))
        f_in: TextIO = io.StringIO(content)
    else:
        f_in = csv_source

    reader = csv.reader(f_in, delimiter=delimiter)
    rows = [r for r in reader if r and any(cell.strip() for cell in r)]

    if not rows:
        raise ValueError("CSV source contains no data rows")

    header_names: list[str] = []
    data_rows: list[list[str]]

    if has_header:
        header_names = [h.strip() for h in rows[0]]
        data_rows = rows[1:]
    else:
        header_names = [f"Col{i}" for i in range(len(rows[0]))]
        data_rows = rows

    # Resolve x column index
    if isinstance(x_col, str):
        if x_col not in header_names:
            raise ValueError(f"x_col '{x_col}' not found in CSV headers {header_names}")
        x_idx = header_names.index(x_col)
    else:
        x_idx = int(x_col)
        if x_idx < 0:
            x_idx += len(header_names)
        if not 0 <= x_idx < len(header_names):
            raise ValueError(f"x_col index {x_col} out of range for {len(header_names)} CSV columns")

    # Resolve y column indices
    y_indices: list[int] = []
    y_labels: list[str] = []

    if y_cols is not None:
        for col in y_cols:
            if isinstance(col, str):
                if col not in header_names:
                    raise ValueError(f"y_col '{col}' not found in CSV headers {header_names}")
                y_indices.append(header_names.index(col))
                y_labels.append(col)
            else:
                idx = int(col)
                if idx < 0:
                    idx += len(header_names)
                if not 0 <= idx < len(header_names):
                    raise ValueError(f"y_col index {col} out of range for {len(header_names)} CSV columns")
                y_indices.append(idx)
                y_labels.append(header_names[idx])
    else:
        # All columns except x_idx
        for i in range(len(rows[0])):
            if i != x_idx:
                y_indices.append(i)
                y_labels.append(header_names[i] if i < len(header_names) else f"Col{i}")

    # Parse numeric data
    x_vals: list[float] = []
    y_vals: list[list[float]] = [[] for _ in y_indices]

    for row in data_rows:
        if len(row) <= x_idx:
            continue
        try:
            x_v = float(row[x_idx].strip())
        except ValueError:
            continue
        x_vals.append(x_v)

        for series_idx, col_idx in enumerate(y_indices):
            if col_idx < len(row):
                try:
                    val = float(row[col_idx].strip())
                except ValueError:
                    val = float("nan")
            else:
                val = float("nan")
            y_vals[series_idx].append(val)

    if not x_vals:
        raise ValueError("CSV source contains no numeric data rows")
    if not y_vals:
        raise ValueError("CSV source contains no y columns to plot")
    if not any(np.isfinite(v) for series in y_vals for v in series):
        raise ValueError("CSV source contains no finite y values to plot")

    traces = [
        PlotTrace(x=x_vals, y=y_vals[s_idx], label=y_labels[s_idx])
        for s_idx in range(len(y_indices))
    ]

    # Auto-extract x_label from header if not provided
    if "x_label" not in kwargs and has_header:
        kwargs["x_label"] = header_names[x_idx]

    return build_waveform_plot(traces=traces, **kwargs)


__all__ = [
    "PlotTrace",
    "format_axis_label",
    "build_waveform_plot",
    "build_plot",
    "build_plot_from_arrays",
    "build_plot_from_csv",
]
