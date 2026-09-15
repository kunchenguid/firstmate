# presenter

`presenter` is a Python library for template-driven PowerPoint (`.pptx`) and Word (`.docx`) authoring.
It assembles a document from plain JSON-serializable content blocks, binds it to a corporate template through a TemplateBinding, and renders it through a format-specific engine.
Its target content is technical: schematics, waveform plots, symbolic equations, and PVT or specification tables.

This file is the library's documentation of record.
The block contract and the TemplateBinding contract below are the canonical text that every part of the library codes against.

## Layout

- `presenter/core/` - the foundation: the specification model (`spec.py`), block validation and typed accessors (`blocks.py`), the render entry point and engine registry (`render.py`), and the error hierarchy (`errors.py`).
- `presenter/templates/` - corporate template ingestion and master binding; produces TemplateBinding files.
- `presenter/render_docx/` - the DOCX datasheet render engine.
- `presenter/blocks/` and `presenter/artifacts.py` - technical content block generators and the artifact source that image and plot blocks reference.

Only `presenter/core/` ships in the foundation slice; the other packages register into it as they land.

## Install

```sh
pip install -e ".[dev]"
python -m pytest
```

Python 3.10 or newer is required.
Runtime dependencies are `python-pptx`, `python-docx`, `matplotlib`, `sympy`, and `pillow`; `pytest` is the only development extra.
The pytest configuration in `pyproject.toml` points at `tests/presenter`, so a bare `python -m pytest` from the repository root runs the library's suite and nothing else.

## Core API

Everything below is importable from `presenter.core`.

- `DocumentSpec` and `SlideSpec` are dataclasses describing one deliverable.
  A `SlideSpec` is one slide in a deck and one section in a document; each holds an ordered list of block dicts.
  Both round-trip to plain dicts through `to_dict()` and `from_dict()`, and `DocumentSpec` also offers `to_json()` and `from_json()`.
- `DocumentBuilder` assembles a `DocumentSpec` fluently: `DocumentBuilder(title).slide("Overview").add(block).build()`.
  Every `add` validates immediately, so an invalid block fails where it is added.
- `validate_block(block)` returns the normalized form of one block dict and raises `BlockValidationError` otherwise.
  `validate_blocks(blocks)` does the same for a list, labelling each error with its index.
  The typed accessors (`TextBlock`, `TableBlock`, `ImageBlock`, `PlotBlock`, `EquationBlock`, `TocBlock`, `PageBreakBlock`) offer attribute access through `from_dict()` and `to_dict()`, and `block_from_dict()` picks the right one.
  Builder helpers `text()`, `table()`, `image()`, `plot()`, `equation()`, `toc()`, and `pagebreak()` in `presenter.core.blocks` return validated dicts.
- `render(spec, binding, output_path)` dispatches on `binding["format"]` to the registered engine and returns the written path.
  The output path must end in the binding's format extension.
- `register_engine(fmt, engine)` plugs an engine into the registry; `unregister_engine`, `get_engine`, `registered_formats`, and `is_engine_implemented` inspect and manage it.
  The `pptx` and `docx` slots exist from import time with stubs that raise `EngineNotImplementedError` (a subclass of both `RenderError` and `NotImplementedError`) until a real engine registers.
- `PresenterError` is the base of every library error; `SpecError`, `BlockValidationError`, `BindingError`, `RenderError`, `UnknownFormatError`, and `EngineNotImplementedError` refine it.

### Engine contract

An engine is a plain callable `engine(document, binding, output_path) -> output_path`.
`document` is the normalized dict from `DocumentSpec.to_dict()`, `binding` is the TemplateBinding dict with `format` lower-cased, and `output_path` is a `pathlib.Path`.
The engine writes the file and returns the path it wrote.
Engines code against these plain dicts, not against `presenter.core` dataclasses, so each lane integrates without importing the others.

## Block contract

Shared block contract (plain JSON-serializable dicts):

- `{"type": "text", "style": "body|heading1|heading2|caption", "text": str}`
- `{"type": "table", "caption": str|null, "headers": [str, ...], "rows": [[value, ...], ...], "style": "grid|plain|striped"}`
- `{"type": "image", "source": "<artifact ref or filesystem path>", "width_in": float|null, "caption": str|null}`
- `{"type": "plot", "source": "<artifact ref to a rendered plot image>", "width_in": float|null, "caption": str|null}`
- `{"type": "equation", "latex": str, "font_size_pt": float|null}`
- `{"type": "toc"}` and `{"type": "pagebreak"}`

Validation rules layered on that contract by `presenter.core.blocks`:

- `style` defaults to `body` for text and `grid` for tables when omitted or `null`; every other optional field normalizes to `null` the same way, so an explicit `null` is always equivalent to omitting the field.
- A table's rows must each have exactly as many values as there are headers, and a value is a string, number, boolean, or `null`.
- `width_in` and `font_size_pt` must be positive numbers when given.
- `source` and `latex` must be non-empty strings.
- Keys outside the contract are rejected, so a misspelled field fails validation instead of being ignored.

## TemplateBinding contract

Shared TemplateBinding contract (JSON file, schema owned by the template lane):

```json
{"format": "pptx"|"docx", "template": "<path>", "name": str, "layouts": {...}, "placeholders": {...}, "styles": {...}}
```

`presenter.core.render.validate_binding` checks only the top-level shape it dispatches on: `format` must name a registered format, `template` must be a non-empty path string, `name` a string when present, and `layouts`, `placeholders`, and `styles` mappings when present.
The meaning of those mappings belongs to `presenter/templates/`.

## End-to-end example

This example is aspirational: it shows the intended shape once the template, DOCX, and content-block lanes have landed and registered their engines.
In the foundation slice alone, the final `render` call raises `EngineNotImplementedError` because no engine has registered yet.

```python
import json

from presenter.core import DocumentBuilder, render
from presenter.core.blocks import equation, image, pagebreak, plot, table, text, toc

# Produced by the template lane from a corporate .dotx or .potx file.
with open("bindings/acme-datasheet.json") as fh:
    binding = json.load(fh)  # {"format": "docx", "template": "templates/acme.dotx", ...}

spec = (
    DocumentBuilder("ACME LDO-3V3 Datasheet", author="Analog IC team")
    .slide("Contents").add(toc())
    .slide("Overview")
    .add(text("A 3.3 V, 500 mA low-dropout regulator.", style="body"))
    .add(image("artifact://schematics/ldo-top", width_in=5.0, caption="Top-level schematic"))
    .slide("Electrical characteristics")
    .add(table(
        ["Parameter", "Min", "Typ", "Max", "Unit"],
        [["Output voltage", 3.234, 3.3, 3.366, "V"], ["Dropout", None, 150, 250, "mV"]],
        caption="Over PVT unless noted",
        style="striped",
    ))
    .add(equation(r"V_{out} = V_{ref} \left(1 + \frac{R_1}{R_2}\right)", font_size_pt=12))
    .add(pagebreak())
    .slide("Transient response")
    .add(plot("artifact://plots/load-step", width_in=6.0, caption="Load step 10 mA to 500 mA"))
    .build()
)

render(spec, binding, "out/ldo-3v3-datasheet.docx")
```
