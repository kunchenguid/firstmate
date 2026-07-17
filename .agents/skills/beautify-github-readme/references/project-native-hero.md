# Project-native hero

Design the README title from the repository's actual content. Do not place a generic banner above a separate screenshot by default.

## Start from five facts

Write these before opening the SVG:

```text
Project category:
Main user:
Main action:
Best proof:
Native visual material:
```

Native visual material is the thing the project really works with: cluster relationships, tensors, tables, code, layers, timelines, maps, icons, terminal output, or generated artifacts.

## Use a stable information anatomy

A useful title can contain five parts:

1. Category or technical context.
2. Repository name.
3. One concrete description.
4. Real project material.
5. Small repository metadata.

Keep the anatomy stable enough to communicate clearly, but move, resize, or omit parts to suit the project. Do not turn it into one fixed template.

## Choose typography from the project

| Project character | Useful type direction |
| --- | --- |
| Infrastructure / systems | large sans-serif + mono metadata |
| Research / database | sober serif or restrained sans-serif + measured diagrams |
| Programming language / low-level tool | industrial display type + code mono |
| Creative tool / design system | open sans-serif or expressive display type + specimens |
| Documentation / knowledge project | quiet readable type + editorial hierarchy |

Use type to express how the project speaks. Do not use serif merely to look premium or monospace merely to look technical.

## Choose a composition mode

- **Split** — title on one side, project structure or artifact on the other. Use when the project has one clear visual proof.
- **Integrated** — let diagrams, paths, code, screenshots, or specimens share the same grid as the title. Use when content and identity are inseparable.
- **Artifact wall** — place several real outputs on a controlled diagonal and let the title occupy one cell or the negative space between them.
- **Background proof** — enlarge one real artifact behind or around the title. Use only when contrast remains clear.
- **Title-only** — use typography and spacing alone when the project is intentionally minimal and has no honest visual proof.

Do not force every repository into a left-title/right-graphic split. Choose the mode after seeing the material.

## Choose how identity and proof meet

Two successful openings are both valid. Choose between them by testing proof legibility, not by applying one house template:

### One-board hero

Combine the category, project name, plain-language promise, project-native motif, and a few real outputs in one composed PNG/WebP. This works when the outputs stay recognizable at README width and the variety itself explains the product. A UI-generation repository, for example, can place several real interface results around the title so the first image communicates both identity and capability.

### Title followed by proof

Use a concise SVG title first, then place a large screenshot wall or showcase immediately below it. This works when the proof contains many pages, dense screenshots, or fine detail that would become too small inside a short hero. A presentation repository, for example, can let the SVG establish the product name and method, while the next image gives the slide outputs enough room to be judged.

Both openings should preserve the same information functions:

```text
context → project name → concrete promise → process cue → real proof
```

These are roles, not fixed positions. Do not copy the same eyebrow, highlight bar, grid, left/right split, or metadata row across repositories. Reuse the reasoning and redesign the composition from the project's material.

Ask these before deciding:

1. Can the proof still be understood when the image is scaled to GitHub content width?
2. Does one artifact explain the product, or does the visitor need to compare several outputs?
3. Is the title likely to change often enough that an editable SVG should stay separate?
4. Would combining title and proof reduce clarity, or merely save vertical space?

## Combine title and demonstration

When the first screenshot, output, or diagram explains the project, combine it with the title into one composition:

```text
category + repository name + concrete description + real proof
```

For vector material, keep the whole composition in SVG. For screenshots, photos, or generated raster work, compose the title and images in a layout tool or HTML canvas and export one PNG/WebP. If many artifacts need more room, keep the SVG title and raster proof as two adjacent README modules. Do not rely on fragile external image links inside SVG.

## Use project-specific tests

Before accepting the hero, ask:

1. If the repository name disappears, could this hero belong to an unrelated project?
2. Does the visual material explain the project, or does it only make the page look technical?
3. Can a first-time visitor tell what the repository does without reading the body?
4. Does the typography fit the project's character and audience?
5. Could the title and proof be composed more tightly instead of appearing as two unrelated blocks?

If the first answer is yes or the second answer is decoration, redesign it.

## Example translations

- Kubernetes: cluster relationships, production scheduling, strict black system layout.
- PyTorch: tensor or network paths, open research spacing, orange computational flow.
- PostgreSQL: tables and relationships, stable deep blue, serif or measured database typography.
- Rust: code structure, industrial display type, strong separation between language and example.
- Icon system: keylines, 4×4 sheets, transparent outputs, cropped specimens.

Use the examples as reasoning patterns, not as templates to copy.
