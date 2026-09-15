"""PVT and specification table builders for presenter.

Provides numeric formatting for significant figures, decimals, SI engineering
notation with units, column alignment, and domain-specific builders for
datasheet specification tables and PVT (Process, Voltage, Temperature) corner tables.
"""

from __future__ import annotations

from dataclasses import dataclass
import math
from typing import Any, Callable, Mapping, Sequence

# Metric SI prefixes from atto (10^-18) to exa (10^18)
SI_PREFIXES: dict[int, str] = {
    18: "E",
    15: "P",
    12: "T",
    9: "G",
    6: "M",
    3: "k",
    0: "",
    -3: "m",
    -6: "µ",
    -9: "n",
    -12: "p",
    -15: "f",
    -18: "a",
}


def format_sigfigs(val: Any, sig_figs: int = 3) -> str:
    """Format a numeric value to a specified number of significant figures.

    Args:
        val: Numeric value, string representation of a number, or None.
        sig_figs: Number of significant figures (positive integer >= 1).

    Returns:
        Formatted string representation with appropriate precision.
    """
    if val is None or val == "":
        return "-"
    try:
        f = float(val)
    except (ValueError, TypeError):
        return str(val)

    if math.isnan(f):
        return "NaN"
    if math.isinf(f):
        return "Inf" if f > 0 else "-Inf"
    if f == 0.0:
        return "0." + "0" * (sig_figs - 1) if sig_figs > 1 else "0"

    exp = math.floor(math.log10(abs(f)))
    decimals = sig_figs - 1 - exp

    # For numbers within reasonable magnitude, format as standard fixed decimal
    if -4 <= exp < sig_figs:
        if decimals > 0:
            return f"{f:.{decimals}f}"
        rounded = round(f, decimals)
        return str(int(rounded))

    # For very large or very small numbers, use scientific notation
    return f"{f:.{sig_figs - 1}e}"


def format_decimals(val: Any, decimals: int = 2) -> str:
    """Format a numeric value to a fixed number of decimal places."""
    if val is None or val == "":
        return "-"
    try:
        f = float(val)
    except (ValueError, TypeError):
        return str(val)

    if math.isnan(f):
        return "NaN"
    if math.isinf(f):
        return "Inf" if f > 0 else "-Inf"

    return f"{f:.{decimals}f}"


def format_engineering(val: Any, unit: str | None = None, sig_figs: int = 3) -> str:
    """Format a numeric value using engineering notation (SI prefixes).

    Args:
        val: Numeric value or string representation.
        unit: Base unit symbol (e.g., 'V', 'A', 'Hz', 's', 'F', 'Ω').
        sig_figs: Number of significant figures. Defaults to 3.

    Returns:
        String with scaled number and prefixed unit (e.g., '25.0 µA', '1.50 MHz').
    """
    if val is None or val == "":
        return "-"
    try:
        f = float(val)
    except (ValueError, TypeError):
        return str(val)

    if math.isnan(f) or math.isinf(f):
        return str(f)
    if f == 0.0:
        return f"0 {unit}".strip() if unit else "0"

    sign = -1 if f < 0 else 1
    f_abs = abs(f)
    exp = math.floor(math.log10(f_abs))
    eng_exp = int(math.floor(exp / 3.0) * 3)
    eng_exp = max(-18, min(18, eng_exp))

    mantissa = sign * (f_abs / (10 ** eng_exp))
    prefix = SI_PREFIXES.get(eng_exp, f"e{eng_exp}")

    m_exp = math.floor(math.log10(abs(mantissa)))
    decimals = sig_figs - 1 - m_exp
    if decimals > 0:
        s = f"{mantissa:.{decimals}f}"
    else:
        s = str(int(round(mantissa)))

    u = f"{prefix}{unit}" if unit else prefix
    return f"{s} {u}".strip() if u else s


def format_number(
    val: Any,
    *,
    sig_figs: int | None = None,
    decimals: int | None = None,
    unit: str | None = None,
    engineering: bool = False,
) -> str:
    """Format a number with optional significant figures, decimals, engineering notation, and unit."""
    if val is None or val == "":
        return "-"

    if engineering:
        return format_engineering(val, unit=unit, sig_figs=sig_figs or 3)

    if sig_figs is not None:
        formatted = format_sigfigs(val, sig_figs=sig_figs)
    elif decimals is not None:
        formatted = format_decimals(val, decimals=decimals)
    else:
        try:
            f = float(val)
            formatted = f"{f:g}"
        except (ValueError, TypeError):
            return str(val)

    if unit:
        return f"{formatted} {unit}"
    return formatted


@dataclass
class ColumnSpec:
    """Specification for a table column's formatting, alignment, and unit."""

    header: str
    key: str | None = None
    unit: str | None = None
    sig_figs: int | None = None
    decimals: int | None = None
    engineering: bool = False
    align: str = "left"  # 'left', 'right', 'center'
    include_unit_in_header: bool = True
    formatter: Callable[[Any], str] | None = None

    def format_cell(self, val: Any) -> str:
        """Format a single cell value according to this column specification."""
        if self.formatter is not None:
            return self.formatter(val)

        # If unit is already in header, do not repeat it in every cell
        cell_unit = None if self.include_unit_in_header else self.unit
        return format_number(
            val,
            sig_figs=self.sig_figs,
            decimals=self.decimals,
            unit=cell_unit,
            engineering=self.engineering,
        )

    def display_header(self) -> str:
        """Return the column header title, incorporating unit if configured."""
        if self.unit and self.include_unit_in_header:
            if not self.header.endswith(f"[{self.unit}]") and not self.header.endswith(f"({self.unit})"):
                return f"{self.header} [{self.unit}]"
        return self.header


@dataclass
class SpecItem:
    """Specification row item for a datasheet table."""

    parameter: str
    symbol: str | None = None
    min_val: Any = None
    typ_val: Any = None
    max_val: Any = None
    unit: str | None = None
    conditions: str | None = None
    comments: str | None = None


@dataclass
class PVTCorner:
    """Process, Voltage, Temperature operating corner definition."""

    name: str
    process: str
    voltage: float | int | str
    temperature: float | int | str
    metrics: Mapping[str, Any] | None = None


def build_table(
    headers: Sequence[str],
    rows: Sequence[Sequence[Any] | Mapping[str, Any]],
    *,
    caption: str | None = None,
    style: str = "grid",
    col_specs: Sequence[ColumnSpec] | Mapping[str, ColumnSpec] | None = None,
    alignments: Sequence[str] | None = None,
) -> dict[str, Any]:
    """Build a standard table block dict adhering to the presenter shared contract.

    Shared contract:
        {"type": "table", "caption": str|null, "headers": [str, ...],
         "rows": [[value, ...], ...], "style": "grid|plain|striped"}

    Args:
        headers: List of column header names.
        rows: Sequence of rows (each row is either a sequence of cell values or a dict).
        caption: Optional table title/caption.
        style: Table visual style ('grid', 'plain', or 'striped'). Defaults to 'grid'.
        col_specs: Optional column formatting specifications.
        alignments: Optional list of column alignments ('left', 'right', 'center').

    Returns:
        Table block dict.
    """
    valid_styles = {"grid", "plain", "striped"}
    if style not in valid_styles:
        raise ValueError(f"style must be one of {valid_styles}, got '{style}'")

    # Map specs to columns
    specs_list: list[ColumnSpec | None] = []
    if col_specs is not None:
        if isinstance(col_specs, Mapping):
            specs_list = [col_specs.get(h) for h in headers]
        else:
            specs_list = list(col_specs)
            while len(specs_list) < len(headers):
                specs_list.append(None)
    else:
        specs_list = [None] * len(headers)

    # Resolve display headers
    formatted_headers: list[str] = []
    for i, h in enumerate(headers):
        spec = specs_list[i]
        if spec is not None:
            formatted_headers.append(spec.display_header())
        else:
            formatted_headers.append(str(h))

    # Resolve alignments
    resolved_alignments: list[str] = []
    for i in range(len(headers)):
        if alignments is not None and i < len(alignments):
            resolved_alignments.append(alignments[i])
        elif specs_list[i] is not None:
            resolved_alignments.append(specs_list[i].align)  # type: ignore[union-attr]
        else:
            resolved_alignments.append("left")

    # Format rows
    formatted_rows: list[list[Any]] = []
    for row in rows:
        formatted_row: list[Any] = []
        if isinstance(row, Mapping):
            for i, h in enumerate(headers):
                spec = specs_list[i]
                key = spec.key if spec and spec.key else h
                val = row.get(key, "-")
                if spec is not None:
                    formatted_row.append(spec.format_cell(val))
                else:
                    formatted_row.append(val if val is not None else "-")
        else:
            for i, val in enumerate(row):
                if i < len(specs_list) and specs_list[i] is not None:
                    formatted_row.append(specs_list[i].format_cell(val))  # type: ignore[union-attr]
                else:
                    formatted_row.append(val if val is not None else "-")
        formatted_rows.append(formatted_row)

    block: dict[str, Any] = {
        "type": "table",
        "caption": caption,
        "headers": formatted_headers,
        "rows": formatted_rows,
        "style": style,
    }
    if alignments is not None or any(a != "left" for a in resolved_alignments):
        block["alignments"] = resolved_alignments

    return block


def build_spec_table(
    specs: Sequence[SpecItem | Mapping[str, Any]],
    *,
    caption: str | None = "Electrical Specifications",
    style: str = "grid",
    sig_figs: int = 3,
    include_symbol: bool = True,
    include_conditions: bool = True,
    headers: Sequence[str] | None = None,
) -> dict[str, Any]:
    """Build an electrical or hardware specification table block.

    Args:
        specs: Sequence of SpecItem objects or mappings.
        caption: Table caption.
        style: 'grid', 'plain', or 'striped'.
        sig_figs: Number of significant figures for numeric min/typ/max values.
        include_symbol: Whether to include the 'Symbol' column.
        include_conditions: Whether to include the 'Conditions' column.
        headers: Optional custom header list.

    Returns:
        A table block dict per the shared contract.
    """
    if headers is not None:
        table_headers = list(headers)
    else:
        table_headers = ["Parameter"]
        if include_symbol:
            table_headers.append("Symbol")
        table_headers.extend(["Min", "Typ", "Max", "Units"])
        if include_conditions:
            table_headers.append("Conditions")

    col_specs: list[ColumnSpec] = []
    for h in table_headers:
        if h in ("Min", "Typ", "Max"):
            col_specs.append(
                ColumnSpec(header=h, sig_figs=sig_figs, align="right", include_unit_in_header=False)
            )
        elif h == "Units":
            col_specs.append(ColumnSpec(header=h, align="center"))
        elif h == "Symbol":
            col_specs.append(ColumnSpec(header=h, align="center"))
        else:
            col_specs.append(ColumnSpec(header=h, align="left"))

    rows_data: list[list[Any]] = []
    for item in specs:
        if isinstance(item, SpecItem):
            param = item.parameter
            symbol = item.symbol or "-"
            min_v = item.min_val
            typ_v = item.typ_val
            max_v = item.max_val
            unit = item.unit or "-"
            cond = item.conditions or "-"
        else:
            param = item.get("parameter", item.get("name", "-"))
            symbol = item.get("symbol", "-")
            min_v = item.get("min", item.get("min_val"))
            typ_v = item.get("typ", item.get("typ_val"))
            max_v = item.get("max", item.get("max_val"))
            unit = item.get("unit", item.get("units", "-"))
            cond = item.get("conditions", item.get("condition", "-"))

        row: list[Any] = [param]
        if include_symbol and "Symbol" in table_headers:
            row.append(symbol)
        if "Min" in table_headers:
            row.append(min_v)
        if "Typ" in table_headers:
            row.append(typ_v)
        if "Max" in table_headers:
            row.append(max_v)
        if "Units" in table_headers:
            row.append(unit)
        if include_conditions and "Conditions" in table_headers:
            row.append(cond)
        rows_data.append(row)

    return build_table(
        headers=table_headers,
        rows=rows_data,
        caption=caption,
        style=style,
        col_specs=col_specs,
    )


def build_pvt_table(
    corners: Sequence[PVTCorner | Mapping[str, Any]],
    *,
    caption: str | None = "PVT Operating Corners",
    style: str = "grid",
    sig_figs: int = 3,
    voltage_unit: str = "V",
    temp_unit: str = "°C",
    metric_headers: Sequence[str] | None = None,
) -> dict[str, Any]:
    """Build a PVT (Process, Voltage, Temperature) corner results table.

    Args:
        corners: Sequence of PVTCorner objects or mappings.
        caption: Table caption.
        style: 'grid', 'plain', or 'striped'.
        sig_figs: Number of significant figures for numeric values.
        voltage_unit: Unit string for voltage column. Defaults to 'V'.
        temp_unit: Unit string for temperature column. Defaults to '°C'.
        metric_headers: Optional sequence of result metric keys/headers.

    Returns:
        A table block dict per the shared contract.
    """
    # Inspect metric headers if not explicitly given
    extra_headers: list[str] = []
    if metric_headers is not None:
        extra_headers = list(metric_headers)
    else:
        for c in corners:
            m = c.metrics if isinstance(c, PVTCorner) else c.get("metrics")
            if isinstance(m, Mapping):
                for k in m.keys():
                    if k not in extra_headers:
                        extra_headers.append(k)

    headers = [
        "Corner",
        "Process",
        f"Voltage [{voltage_unit}]",
        f"Temp [{temp_unit}]",
        *extra_headers,
    ]

    col_specs = [
        ColumnSpec(header="Corner", align="left"),
        ColumnSpec(header="Process", align="center"),
        ColumnSpec(
            header=f"Voltage [{voltage_unit}]",
            sig_figs=sig_figs,
            align="right",
            include_unit_in_header=True,
        ),
        ColumnSpec(
            header=f"Temp [{temp_unit}]",
            sig_figs=sig_figs,
            align="right",
            include_unit_in_header=True,
        ),
    ]
    for h in extra_headers:
        col_specs.append(ColumnSpec(header=h, sig_figs=sig_figs, align="right"))

    rows_data: list[list[Any]] = []
    for c in corners:
        if isinstance(c, PVTCorner):
            name = c.name
            proc = c.process
            volt = c.voltage
            temp = c.temperature
            metrics = c.metrics or {}
        else:
            name = c.get("name", c.get("corner", "-"))
            proc = c.get("process", "-")
            volt = c.get("voltage", c.get("volt", "-"))
            temp = c.get("temperature", c.get("temp", "-"))
            metrics = c.get("metrics", {})

        row: list[Any] = [name, proc, volt, temp]
        for h in extra_headers:
            row.append(metrics.get(h, "-") if isinstance(metrics, Mapping) else "-")
        rows_data.append(row)

    return build_table(
        headers=headers,
        rows=rows_data,
        caption=caption,
        style=style,
        col_specs=col_specs,
    )


__all__ = [
    "format_sigfigs",
    "format_decimals",
    "format_engineering",
    "format_number",
    "ColumnSpec",
    "SpecItem",
    "PVTCorner",
    "build_table",
    "build_spec_table",
    "build_pvt_table",
]
