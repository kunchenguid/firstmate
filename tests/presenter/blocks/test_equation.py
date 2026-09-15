"""Tests for presenter.blocks.equation module."""

from __future__ import annotations

import sys
from pathlib import Path
from PIL import Image
import pytest
import sympy as sp  # type: ignore[import-untyped]

# Ensure repository root is on sys.path
_REPO_ROOT = Path(__file__).resolve().parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

import matplotlib
matplotlib.use("Agg")

from presenter.blocks.equation import (
    build_equation,
    build_equation_from_sympy,
    latex_from_sympy,
    render_latex_to_png,
)


def test_render_latex_to_png(tmp_path: Path) -> None:
    """Verify rendering a standard LaTeX formula produces a valid PNG."""
    out_png = tmp_path / "eq1.png"
    rendered_path = render_latex_to_png(r"E = mc^2", output_path=out_png)

    assert rendered_path == out_png.resolve()
    assert out_png.exists()
    assert out_png.stat().st_size > 0

    with Image.open(out_png) as img:
        assert img.format == "PNG"
        assert img.width > 0
        assert img.height > 0


def test_render_latex_already_wrapped(tmp_path: Path) -> None:
    """Verify handling when caller passes string already wrapped with $."""
    out_png = tmp_path / "eq_wrapped.png"
    render_latex_to_png(r"$\frac{-b \pm \sqrt{b^2 - 4ac}}{2a}$", output_path=out_png)

    assert out_png.exists()
    assert out_png.stat().st_size > 0


def test_render_latex_empty_string_raises() -> None:
    """Verify passing an empty LaTeX string raises ValueError."""
    with pytest.raises(ValueError, match="cannot be empty"):
        render_latex_to_png("   ")


def test_build_equation_block_contract(tmp_path: Path) -> None:
    """Verify build_equation returns a block dict matching the shared contract."""
    out_png = tmp_path / "eq_block.png"
    latex_str = r"V_{out} = A_v \cdot V_{in}"

    block = build_equation(
        latex=latex_str,
        output_path=out_png,
        font_size_pt=16.0,
        dpi=300,
        render_image=True,
    )

    # Check shared block contract keys
    assert block["type"] == "equation"
    assert block["latex"] == latex_str
    assert block["font_size_pt"] == 16.0
    assert block["image"] == str(out_png.resolve())

    # Assert artifact was produced
    assert out_png.exists()
    assert out_png.stat().st_size > 0


def test_build_equation_without_rendered_image() -> None:
    """Verify build_equation with render_image=False sets image to None."""
    latex_str = r"\omega = 2\pi f"
    block = build_equation(latex=latex_str, render_image=False)

    assert block["type"] == "equation"
    assert block["latex"] == latex_str
    assert block["image"] is None


def test_build_equation_auto_temp_file() -> None:
    """Verify omitting output_path generates a valid temporary PNG."""
    block = build_equation(r"P = I^2 R", render_image=True)
    try:
        assert block["image"] is not None
        p = Path(block["image"])
        assert p.exists()
        assert p.stat().st_size > 0
    finally:
        if block["image"] and Path(block["image"]).exists():
            Path(block["image"]).unlink()


def test_latex_from_sympy_string() -> None:
    """Verify converting a math expression string via SymPy."""
    latex_str = latex_from_sympy("x**2 + sqrt(y)")
    assert "x^{2}" in latex_str
    assert r"\sqrt{y}" in latex_str


def test_latex_from_sympy_expression() -> None:
    """Verify converting a SymPy expression object to LaTeX."""
    x = sp.Symbol("x")
    expr = sp.Integral(x**2, x)
    latex_str = latex_from_sympy(expr)
    assert r"\int" in latex_str
    assert "x^{2}" in latex_str


def test_build_equation_from_sympy(tmp_path: Path) -> None:
    """Verify build_equation_from_sympy parses expression and renders PNG."""
    out_png = tmp_path / "sympy_eq.png"
    x, y = sp.symbols("x y")
    expr = x / (x + y)

    block = build_equation_from_sympy(expr, output_path=out_png)

    assert block["type"] == "equation"
    assert r"\frac{x}{x + y}" in block["latex"]
    assert out_png.exists()
    assert out_png.stat().st_size > 0
