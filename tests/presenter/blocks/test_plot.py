"""Tests for presenter.blocks.plot module."""

from __future__ import annotations

import io
import sys
from pathlib import Path
from PIL import Image
import pytest

# Ensure repository root is on sys.path
_REPO_ROOT = Path(__file__).resolve().parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

import matplotlib
matplotlib.use("Agg")

from presenter.blocks.plot import (
    PlotTrace,
    build_plot,
    build_plot_from_arrays,
    build_plot_from_csv,
    build_waveform_plot,
    format_axis_label,
)


def test_format_axis_label() -> None:
    """Verify axis label formatting with units."""
    assert format_axis_label("Time", "s") == "Time [s]"
    assert format_axis_label("Voltage", "V", bracket_style="parentheses") == "Voltage (V)"
    assert format_axis_label("Frequency", None) == "Frequency"
    assert format_axis_label(None, "mA") == "[mA]"
    assert format_axis_label(None, None) is None


def test_build_waveform_plot_from_arrays(tmp_path: Path) -> None:
    """Verify building a waveform plot from x and y arrays produces a valid block and PNG."""
    x = [0.0, 1.0, 2.0, 3.0, 4.0]
    y = [0.0, 1.5, 3.0, 2.5, 4.0]
    out_png = tmp_path / "waveform.png"

    block = build_waveform_plot(
        x=x,
        y=y,
        x_label="Time",
        x_unit="µs",
        y_label="Vout",
        y_unit="V",
        caption="Transient Response",
        width_in=5.5,
        output_path=out_png,
    )

    # Check shared block contract keys
    assert block["type"] == "plot"
    assert "source" in block
    assert block["caption"] == "Transient Response"
    assert block["width_in"] == 5.5
    assert Path(block["source"]).resolve() == out_png.resolve()

    # Check PNG artifact on disk
    assert out_png.exists()
    assert out_png.stat().st_size > 0
    with Image.open(out_png) as img:
        assert img.format == "PNG"
        assert img.width > 0
        assert img.height > 0


def test_build_waveform_plot_with_multiple_traces(tmp_path: Path) -> None:
    """Verify multi-trace plotting with custom line styles, colors, and markers."""
    out_png = tmp_path / "multi_trace.png"
    x = [0.0, 1.0, 2.0, 3.0]

    traces = [
        PlotTrace(
            x=x,
            y=[0.0, 1.0, 2.0, 3.0],
            label="Linear",
            color="blue",
            line_style="-",
            line_width=2.0,
            marker="o",
        ),
        PlotTrace(
            x=x,
            y=[0.0, 1.0, 4.0, 9.0],
            label="Quadratic",
            color="red",
            line_style="--",
            line_width=1.5,
            marker="s",
        ),
    ]

    block = build_waveform_plot(
        traces=traces,
        title="Comparison Plot",
        grid=True,
        grid_style=":",
        grid_alpha=0.4,
        legend=True,
        output_path=out_png,
    )

    assert block["type"] == "plot"
    assert Path(block["source"]).exists()
    assert Path(block["source"]).stat().st_size > 0


def test_build_waveform_plot_dict_traces(tmp_path: Path) -> None:
    """Verify passing traces as plain dictionaries."""
    out_png = tmp_path / "dict_traces.png"
    traces = [
        {"x": [1, 2, 3], "y": [2, 4, 6], "label": "Series A", "line_style": "-."},
        {"x": [1, 2, 3], "y": [3, 2, 1], "label": "Series B", "color": "green"},
    ]

    block = build_plot(traces=traces, output_path=out_png)
    assert block["type"] == "plot"
    assert out_png.exists()
    assert out_png.stat().st_size > 0


def test_build_plot_from_arrays_mapping(tmp_path: Path) -> None:
    """Verify build_plot_from_arrays with a mapping of series names to arrays."""
    out_png = tmp_path / "mapping_plot.png"
    x = [10, 20, 30]
    y_map = {
        "Trace 1": [1.1, 2.2, 3.3],
        "Trace 2": [4.4, 5.5, 6.6],
    }

    block = build_plot_from_arrays(
        x=x,
        y=y_map,
        title="Bus Signals",
        output_path=out_png,
        caption="Bus Waveforms",
    )
    assert block["type"] == "plot"
    assert block["caption"] == "Bus Waveforms"
    assert out_png.exists()


def test_build_waveform_plot_log_axes_and_limits(tmp_path: Path) -> None:
    """Verify log axes configuration and axis limits."""
    out_png = tmp_path / "log_plot.png"
    x = [1, 10, 100, 1000]
    y = [10, 100, 1000, 10000]

    block = build_waveform_plot(
        x=x,
        y=y,
        x_log=True,
        y_log=True,
        x_lim=(1, 1000),
        y_lim=(10, 10000),
        output_path=out_png,
    )
    assert block["type"] == "plot"
    assert out_png.exists()


def test_build_plot_auto_temp_file() -> None:
    """Verify that omitting output_path generates a valid temporary PNG."""
    block = build_waveform_plot(x=[1, 2], y=[3, 4])
    try:
        assert block["type"] == "plot"
        source_path = Path(block["source"])
        assert source_path.exists()
        assert source_path.stat().st_size > 0
    finally:
        if Path(block["source"]).exists():
            Path(block["source"]).unlink()


def test_build_plot_from_csv_file(tmp_path: Path) -> None:
    """Verify building a plot from a CSV file with headers."""
    csv_file = tmp_path / "data.csv"
    csv_file.write_text(
        "Time_ns,V_in,V_out\n"
        "0.0,0.0,0.0\n"
        "1.0,1.8,0.5\n"
        "2.0,1.8,1.2\n"
        "3.0,1.8,1.75\n"
        "4.0,1.8,1.8\n",
        encoding="utf-8",
    )
    out_png = tmp_path / "from_csv.png"

    block = build_plot_from_csv(
        csv_file,
        x_col="Time_ns",
        y_cols=["V_in", "V_out"],
        x_unit="ns",
        y_unit="V",
        caption="Step Response from CSV",
        output_path=out_png,
    )

    assert block["type"] == "plot"
    assert block["caption"] == "Step Response from CSV"
    assert out_png.exists()
    assert out_png.stat().st_size > 0


def test_build_plot_from_csv_stream_no_header(tmp_path: Path) -> None:
    """Verify building a plot from an in-memory CSV stream without headers."""
    csv_data = io.StringIO(
        "0.0,10.0\n"
        "1.0,20.0\n"
        "2.0,15.0\n"
        "3.0,30.0\n"
    )
    out_png = tmp_path / "stream_plot.png"

    block = build_plot_from_csv(
        csv_data,
        x_col=0,
        y_cols=[1],
        has_header=False,
        output_path=out_png,
    )

    assert block["type"] == "plot"
    assert out_png.exists()


def test_build_plot_from_csv_invalid_columns(tmp_path: Path) -> None:
    """Verify error handling when column names in CSV do not match."""
    csv_file = tmp_path / "bad.csv"
    csv_file.write_text("A,B\n1,2\n", encoding="utf-8")

    with pytest.raises(ValueError, match="x_col 'Missing' not found"):
        build_plot_from_csv(csv_file, x_col="Missing")

    with pytest.raises(ValueError, match="y_col 'Bad' not found"):
        build_plot_from_csv(csv_file, x_col="A", y_cols=["Bad"])
