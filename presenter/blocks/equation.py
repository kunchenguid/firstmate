"""LaTeX equation block builder and mathtext PNG renderer.

Renders LaTeX mathematical equations to crisp PNG images using matplotlib's
built-in mathtext engine (headless Agg backend). Optionally leverages SymPy
for parsing and formatting mathematical expressions to LaTeX.
"""

from __future__ import annotations

import os
from pathlib import Path
import tempfile
from typing import Any

import matplotlib
# Enforce headless rendering
matplotlib.use("Agg")
import matplotlib.pyplot as plt

try:
    import sympy as sp  # type: ignore[import-untyped]
    _HAS_SYMPY = True
except ImportError:
    sp = None  # type: ignore[assignment]
    _HAS_SYMPY = False


def _ensure_output_path(output_path: str | Path | None = None) -> Path:
    """Resolve an output path or create a safe temporary PNG file."""
    if output_path is not None:
        p = Path(output_path).resolve()
        p.parent.mkdir(parents=True, exist_ok=True)
        return p

    fd, tmp = tempfile.mkstemp(prefix="presenter_eq_", suffix=".png")
    os.close(fd)
    return Path(tmp).resolve()


def latex_from_sympy(expr: Any) -> str:
    """Convert a SymPy expression or mathematical string to a LaTeX string.

    Args:
        expr: A SymPy expression object, or a mathematical expression string
              suitable for sympify (e.g., 'x**2 + sqrt(y)').

    Returns:
        Formatted LaTeX string.

    Raises:
        ImportError: If sympy is not installed.
    """
    if not _HAS_SYMPY:
        raise ImportError(
            "Sympy is not installed; install sympy to use sympy expression conversions"
        )

    if isinstance(expr, str):
        parsed = sp.sympify(expr)
        return sp.latex(parsed)

    return sp.latex(expr)


def render_latex_to_png(
    latex: str,
    output_path: str | Path | None = None,
    *,
    font_size_pt: float = 14.0,
    dpi: int = 300,
    color: str = "black",
    background: str = "transparent",
    pad_inches: float = 0.05,
) -> Path:
    """Render a LaTeX math string to a PNG image using matplotlib mathtext.

    Args:
        latex: LaTeX expression (e.g. 'E = mc^2' or r'\\frac{1}{2}').
        output_path: Optional destination filesystem path.
        font_size_pt: Font size in points. Defaults to 14.0.
        dpi: Image resolution in dots per inch. Defaults to 300.
        color: Font color (e.g. 'black', '#111111').
        background: 'transparent' or a valid color string (e.g. 'white').
        pad_inches: Padding around the rendered text.

    Returns:
        Path to the saved PNG image.
    """
    cleaned = latex.strip()
    if not cleaned:
        raise ValueError("LaTeX string cannot be empty")

    # Strip surrounding $ or $$ if caller provided them
    while cleaned.startswith("$") and cleaned.endswith("$") and len(cleaned) > 1:
        cleaned = cleaned[1:-1].strip()

    math_text = f"${cleaned}$"

    resolved_out = _ensure_output_path(output_path)

    # Use a minimal figure size with tight bbox
    fig = plt.figure(figsize=(0.01, 0.01), dpi=dpi)
    try:
        is_transparent = background == "transparent"
        if not is_transparent:
            fig.patch.set_facecolor(background)

        fig.text(
            0,
            0,
            math_text,
            fontsize=font_size_pt,
            color=color,
            va="bottom",
            ha="left",
        )

        fig.savefig(
            resolved_out,
            format="png",
            dpi=dpi,
            bbox_inches="tight",
            transparent=is_transparent,
            pad_inches=pad_inches,
        )
    finally:
        plt.close(fig)

    return resolved_out


def build_equation(
    latex: str,
    *,
    output_path: str | Path | None = None,
    font_size_pt: float | None = 14.0,
    dpi: int = 300,
    render_image: bool = True,
    color: str = "black",
    background: str = "transparent",
) -> dict[str, Any]:
    """Build an equation block dict matching the shared presenter block contract.

    Shared contract:
        {"type": "equation", "latex": str, "font_size_pt": float|null, "image": "<path>"}

    Args:
        latex: LaTeX equation string.
        output_path: Optional explicit path for the rendered PNG file.
        font_size_pt: Font size in points (or None). Defaults to 14.0.
        dpi: Render DPI for the image. Defaults to 300.
        render_image: If True, renders the equation to a PNG file and populates
                      the 'image' key. If False, 'image' will be None.
        color: Font color for rendered image.
        background: Background color ('transparent' or a color string).

    Returns:
        An equation block dict with keys 'type', 'latex', 'font_size_pt', and 'image'.
    """
    image_path: str | None = None

    if render_image:
        size = font_size_pt if font_size_pt is not None else 14.0
        rendered = render_latex_to_png(
            latex=latex,
            output_path=output_path,
            font_size_pt=size,
            dpi=dpi,
            color=color,
            background=background,
        )
        image_path = str(rendered)

    return {
        "type": "equation",
        "latex": latex,
        "font_size_pt": font_size_pt,
        "image": image_path,
    }


def build_equation_from_sympy(
    expr: Any,
    *,
    output_path: str | Path | None = None,
    font_size_pt: float | None = 14.0,
    dpi: int = 300,
    render_image: bool = True,
    color: str = "black",
    background: str = "transparent",
) -> dict[str, Any]:
    """Build an equation block from a SymPy expression or math expression string.

    Args:
        expr: SymPy expression or mathematical string (e.g., 'x**2 + y/2').
        output_path: Optional explicit path for the rendered PNG file.
        font_size_pt: Font size in points.
        dpi: Render DPI.
        render_image: Whether to render PNG image.
        color: Font color.
        background: Background color.

    Returns:
        Equation block dict.
    """
    latex_str = latex_from_sympy(expr)
    return build_equation(
        latex=latex_str,
        output_path=output_path,
        font_size_pt=font_size_pt,
        dpi=dpi,
        render_image=render_image,
        color=color,
        background=background,
    )


__all__ = [
    "render_latex_to_png",
    "latex_from_sympy",
    "build_equation",
    "build_equation_from_sympy",
]
