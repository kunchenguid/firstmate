"""Tests for presenter.blocks.tables module."""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any, Mapping
import pytest

# Ensure repository root is on sys.path
_REPO_ROOT = Path(__file__).resolve().parents[3]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from presenter.blocks.tables import (
    ColumnSpec,
    PVTCorner,
    SpecItem,
    build_pvt_table,
    build_spec_table,
    build_table,
    format_decimals,
    format_engineering,
    format_number,
    format_sigfigs,
)


def test_format_sigfigs() -> None:
    """Verify significant figures formatting logic."""
    # 3 significant figures
    assert format_sigfigs(1.2, 3) == "1.20"
    assert format_sigfigs(0.05, 3) == "0.0500"
    assert format_sigfigs(0.00123456, 3) == "0.00123"
    assert format_sigfigs(12345.6, 3) == "1.23e+04"
    assert format_sigfigs(-3.14159, 3) == "-3.14"
    assert format_sigfigs(0.0, 3) == "0.00"
    assert format_sigfigs(0.0, 1) == "0"

    # Edge cases
    assert format_sigfigs(None) == "-"
    assert format_sigfigs("") == "-"
    assert format_sigfigs("N/A") == "N/A"
    assert format_sigfigs(float("nan")) == "NaN"
    assert format_sigfigs(float("inf")) == "Inf"


def test_format_decimals() -> None:
    """Verify fixed decimal point formatting."""
    assert format_decimals(3.14159, 2) == "3.14"
    assert format_decimals(1.2, 3) == "1.200"
    assert format_decimals(0.0, 1) == "0.0"
    assert format_decimals(None) == "-"


def test_format_engineering() -> None:
    """Verify SI prefix engineering notation formatting."""
    assert format_engineering(0.000025, unit="A", sig_figs=3) == "25.0 µA"
    assert format_engineering(1500000, unit="Hz", sig_figs=3) == "1.50 MHz"
    assert format_engineering(3.3, unit="V", sig_figs=2) == "3.3 V"
    assert format_engineering(0.0, unit="V", sig_figs=3) == "0 V"
    assert format_engineering(None) == "-"


def test_format_engineering_nonfinite() -> None:
    """Verify engineering formatter labels non-finite values like sibling formatters."""
    assert format_engineering(float("nan")) == "NaN"
    assert format_engineering("nan") == "NaN"
    assert format_engineering(float("inf"), unit="V") == "Inf"
    assert format_engineering(float("-inf"), unit="V") == "-Inf"


def test_format_number() -> None:
    """Verify format_number dispatcher with various options."""
    assert format_number(1.234, sig_figs=2) == "1.2"
    assert format_number(1.234, decimals=1, unit="V") == "1.2 V"
    assert format_number(0.005, engineering=True, unit="A") == "5.00 mA"
    assert format_number(None) == "-"


def test_column_spec() -> None:
    """Verify ColumnSpec formatting, unit in header, and alignment."""
    col = ColumnSpec(header="Supply Voltage", unit="V", sig_figs=3, align="right")
    assert col.display_header() == "Supply Voltage [V]"
    assert col.format_cell(1.8) == "1.80"

    # Without unit in header
    col_in_cell = ColumnSpec(header="Current", unit="mA", sig_figs=3, include_unit_in_header=False)
    assert col_in_cell.display_header() == "Current"
    assert col_in_cell.format_cell(2.5) == "2.50 mA"

    # Custom formatter
    col_custom = ColumnSpec(header="Status", formatter=lambda x: f"STATUS_{x}".upper())
    assert col_custom.format_cell("ok") == "STATUS_OK"


def test_build_table_contract() -> None:
    """Verify build_table returns block dict strictly following shared contract."""
    headers = ["Parameter", "Value"]
    rows = [["VDD", 1.8], ["VSS", 0.0]]

    block = build_table(
        headers=headers,
        rows=rows,
        caption="Power Rails",
        style="grid",
    )

    assert block["type"] == "table"
    assert block["caption"] == "Power Rails"
    assert block["headers"] == ["Parameter", "Value"]
    assert block["rows"] == [["VDD", 1.8], ["VSS", 0.0]]
    assert block["style"] == "grid"


def test_build_table_invalid_style_raises() -> None:
    """Verify that invalid style parameter raises ValueError."""
    with pytest.raises(ValueError, match="style must be one of"):
        build_table(headers=["A"], rows=[[1]], style="fancy_shadow")


def test_build_table_with_col_specs_and_dicts() -> None:
    """Verify build_table formatting rows given as dictionaries with ColumnSpec."""
    headers = ["Name", "Voltage"]
    col_specs = {
        "Name": ColumnSpec(header="Name", align="left"),
        "Voltage": ColumnSpec(header="Voltage", unit="V", sig_figs=3, align="right"),
    }
    rows = [
        {"Name": "Core", "Voltage": 1.05},
        {"Name": "IO", "Voltage": 3.3},
    ]

    block = build_table(
        headers=headers,
        rows=rows,
        caption="Domains",
        style="striped",
        col_specs=col_specs,
    )

    assert block["type"] == "table"
    assert block["headers"] == ["Name", "Voltage [V]"]
    assert block["rows"] == [["Core", "1.05"], ["IO", "3.30"]]
    assert block["style"] == "striped"
    assert block["alignments"] == ["left", "right"]


def test_build_spec_table() -> None:
    """Verify build_spec_table creates a properly formatted datasheet table."""
    specs: list[SpecItem | Mapping[str, Any]] = [
        SpecItem(
            parameter="Quiescent Current",
            symbol="I_Q",
            min_val=None,
            typ_val=1.2,
            max_val=2.5,
            unit="mA",
            conditions="VIN = 3.3V",
        ),
        {
            "parameter": "Dropout Voltage",
            "symbol": "V_DO",
            "min": None,
            "typ": 120,
            "max": 200,
            "unit": "mV",
            "conditions": "IOUT = 100mA",
        },
    ]

    block = build_spec_table(specs, caption="DC Characteristics", style="striped")

    assert block["type"] == "table"
    assert block["caption"] == "DC Characteristics"
    assert block["style"] == "striped"
    assert "Parameter" in block["headers"]
    assert "Symbol" in block["headers"]
    assert "Min" in block["headers"]
    assert "Typ" in block["headers"]
    assert "Max" in block["headers"]
    assert "Units" in block["headers"]
    assert "Conditions" in block["headers"]

    # First row: min is None -> '-', typ is 1.2 -> '1.20', max is 2.5 -> '2.50'
    r0 = block["rows"][0]
    assert r0[0] == "Quiescent Current"
    assert r0[1] == "I_Q"
    assert r0[2] == "-"
    assert r0[3] == "1.20"
    assert r0[4] == "2.50"
    assert r0[5] == "mA"
    assert r0[6] == "VIN = 3.3V"

    # Second row
    r1 = block["rows"][1]
    assert r1[0] == "Dropout Voltage"
    assert r1[1] == "V_DO"
    assert r1[2] == "-"
    assert r1[3] == "120"
    assert r1[4] == "200"
    assert r1[5] == "mV"
    assert r1[6] == "IOUT = 100mA"


def test_build_spec_table_custom_header_order() -> None:
    """Verify values land under their named columns when headers are reordered."""
    specs: list[SpecItem | Mapping[str, Any]] = [
        SpecItem(parameter="IQ", min_val=1.0, typ_val=1.2, max_val=2.5, unit="mA"),
        {"parameter": "VDO", "min": 1.0, "typ": 1.2, "max": 2.5, "unit": "mV"},
    ]

    block = build_spec_table(
        specs,
        headers=["Min", "Typ", "Max", "Units", "Parameter"],
        include_symbol=False,
        include_conditions=False,
    )

    assert block["headers"] == ["Min", "Typ", "Max", "Units", "Parameter"]
    assert block["rows"] == [
        ["1.00", "1.20", "2.50", "mA", "IQ"],
        ["1.00", "1.20", "2.50", "mV", "VDO"],
    ]
    assert block["alignments"] == ["right", "right", "right", "center", "left"]


def test_build_spec_table_renamed_headers_with_units() -> None:
    """Verify unit-suffixed headers keep their values and apply numeric formatting."""
    block = build_spec_table(
        [{"parameter": "VDO", "min": 1.0, "typ": 1.2, "max": 2.5}],
        headers=["Parameter", "Min (V)", "Typ (V)", "Max (V)"],
        include_symbol=False,
        include_conditions=False,
    )

    assert block["headers"] == ["Parameter", "Min (V)", "Typ (V)", "Max (V)"]
    assert block["rows"] == [["VDO", "1.00", "1.20", "2.50"]]


def test_build_spec_table_unknown_header_raises() -> None:
    """Verify an unrecognized custom header fails loudly instead of mislabeling."""
    with pytest.raises(ValueError, match="Bogus"):
        build_spec_table(
            [{"parameter": "IQ", "typ": 1.2}],
            headers=["Parameter", "Bogus"],
            include_symbol=False,
            include_conditions=False,
        )


def test_build_spec_table_custom_headers_override_includes() -> None:
    """Verify a custom header list fully determines the emitted columns."""
    block = build_spec_table(
        [{"parameter": "IQ", "symbol": "I_Q", "typ": 1.2}],
        include_symbol=False,
        include_conditions=False,
        headers=["Parameter", "Symbol", "Typ"],
    )

    assert block["headers"] == ["Parameter", "Symbol", "Typ"]
    assert block["rows"] == [["IQ", "I_Q", "1.20"]]


def test_build_pvt_table() -> None:
    """Verify build_pvt_table creates a properly formatted corner simulation table."""
    corners: list[PVTCorner | Mapping[str, Any]] = [
        PVTCorner(
            name="Typical",
            process="TT",
            voltage=1.8,
            temperature=25,
            metrics={"Delay [ps]": 142.5, "Power [mW]": 12.3},
        ),
        PVTCorner(
            name="Fast-Fast",
            process="FF",
            voltage=1.98,
            temperature=-40,
            metrics={"Delay [ps]": 98.2, "Power [mW]": 18.7},
        ),
        {
            "name": "Slow-Slow",
            "process": "SS",
            "voltage": 1.62,
            "temperature": 125,
            "metrics": {"Delay [ps]": 215.1, "Power [mW]": 8.45},
        },
    ]

    block = build_pvt_table(corners, caption="PVT Simulation Summary")

    assert block["type"] == "table"
    assert block["caption"] == "PVT Simulation Summary"
    assert block["headers"] == [
        "Corner",
        "Process",
        "Voltage [V]",
        "Temp [°C]",
        "Delay [ps]",
        "Power [mW]",
    ]

    # Verify formatting of numeric values
    r0 = block["rows"][0]
    assert r0 == ["Typical", "TT", "1.80", "25.0", "142", "12.3"]

    r1 = block["rows"][1]
    assert r1 == ["Fast-Fast", "FF", "1.98", "-40.0", "98.2", "18.7"]

    r2 = block["rows"][2]
    assert r2 == ["Slow-Slow", "SS", "1.62", "125", "215", "8.45"]
