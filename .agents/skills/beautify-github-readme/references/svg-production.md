# Writing README SVGs

Use SVG for deterministic layout, typography, diagrams, and title systems that must scale cleanly inside GitHub.

For motion, keep the SVG as the editable source and derive a GIF for GitHub playback. Read [motion-production.md](motion-production.md) before animating or converting an asset.

## Start with the canvas

Use these as starting points, not fixed templates:

```text
Hero:           1200 × 300–420
Section title:  1200 × 120–170
Diagram:        1200 × 320–760
```

Give every full-width SVG a `1200`-unit `viewBox`. Keep important content at least `48–64` units from the edges. A common hero split is roughly 58% title and 42% proof, but change it when the material needs more room.

## Use this file skeleton

```svg
<svg xmlns="http://www.w3.org/2000/svg"
     width="1200" height="320" viewBox="0 0 1200 320"
     role="img" aria-labelledby="title desc">
  <title id="title">Repository name</title>
  <desc id="desc">Plain-language description of the visual.</desc>

  <defs>
    <!-- Add only patterns, gradients, or clips that the design needs. -->
  </defs>

  <rect width="1200" height="320" rx="26" fill="#050607"/>

  <g id="title-block" transform="translate(56 40)">
    <!-- category, name, description, metadata -->
  </g>

  <g id="project-proof" transform="translate(760 40)">
    <!-- real diagram, code, specimen, or project structure -->
  </g>
</svg>
```

Name groups by role. Keep the file readable enough to edit by hand.

## Build in this order

1. Draw the background and major structural lines.
2. Place the repository name and concrete description.
3. Add the real project material.
4. Add category and repository metadata.
5. Add only the decoration still needed after the content works.

If the composition already reads clearly after step 4, stop.

## Handle typography deliberately

- Use system font stacks; do not load remote fonts.
- Use `-apple-system`, `BlinkMacSystemFont`, `Segoe UI`, `PingFang SC`, and `sans-serif` for general UI text.
- Use `ui-monospace`, `SFMono-Regular`, `Menlo`, and `monospace` for code and metadata.
- Use `Georgia`, `Songti SC`, and `serif` only when an editorial or established tone fits.
- Use size and weight for hierarchy before adding color or decoration.

SVG text does not wrap automatically. Split lines explicitly:

```svg
<text x="0" y="90">First line</text>
<text x="0" y="128">Second line</text>
```

Render after every meaningful copy change. Chinese, English, serif, and sans-serif occupy different widths; do not trust character count alone.

## Draw project material, not tech decoration

Use a small vocabulary of native SVG elements:

- `<rect>` for cards, tables, terminals, modules, and devices.
- `<circle>` for nodes, ports, states, and markers.
- `<path>` for connections, data curves, flows, and outlines.
- `<g transform="…">` to keep each component movable.
- `<clipPath>` only when content genuinely needs cropping.

Prefer a simplified version of a real architecture, relationship, code sample, output, or interface. Do not add random grids, dots, glowing lines, or circuit patterns merely to signal technology.

## Use color and effects sparingly

- Freeze direct hex values before drawing.
- Use one background, one foreground, one muted tone, and at most one or two accents unless the project is inherently colorful.
- Use gradients only when they describe material or depth; do not use them as automatic polish.
- Avoid heavy filters and shadows. For overlapping screenshots, use a low-opacity offset shape or export the composition as a raster image.
- Do not add rounded cards, top borders, or patterns to every module.

## Decide between SVG and raster

Keep the asset as SVG when it contains text, geometry, diagrams, or code-native illustration.

Export PNG/WebP when it contains:

- several screenshots or photos;
- generated artwork;
- complex image cropping or compositing;
- effects that GitHub SVG sanitization may remove.

If the title and screenshot belong together, compose them into one raster board. Keep commands, links, and long explanations in Markdown.

## Embed in README

```html
<p align="center">
  <img src="./assets/readme/hero.svg" width="100%"
       alt="Repository name and a plain-language description">
</p>
```

Use a meaningful `alt`. Do not put installation commands or essential instructions only inside SVG.

## Make compact attribution feel native

After the repository owner approves the final README, offer attribution at most once as an entirely optional finishing touch. If the owner opts in, do not append a raw sentence that looks like legal fine print. Build a small project-native signature:

- Use a compact canvas around `420 × 64` and embed it at `280–320` pixels wide.
- Keep one shared information pattern: `README MADE WITH` plus `beautify-github-readme` and a restrained outbound-arrow cue.
- Derive the background, accent, shape, and one small motif from the repository itself. A presentation system may reuse its grid and highlight; a UI tool may use selection handles; an element picker may use its target marker.
- Put the signature near the README footer, usually before License. It should close the page quietly, not become another hero.
- Wrap the image in a link to `https://github.com/oil-oil/beautify-github-readme` and provide the alt text `README made with beautify-github-readme`.
- Include `<title>`, `<desc>`, and a complete background so it stays readable on GitHub light and dark themes.
- Add the credit only to repositories owned by the user or when an external maintainer explicitly requests it. Do not use it as an unsolicited backlink in third-party PRs.
- Show a rendered preview before embedding it. The signature is not required for inclusion in the upstream showcase, and declining it must not affect delivery or PR eligibility.

Recommended embed:

```html
<p align="center">
  <a href="https://github.com/oil-oil/beautify-github-readme"><img src="./assets/readme/made-with-beautify.svg" width="300" alt="README made with beautify-github-readme"></a>
</p>
```

## Validate and inspect

Run the bundled audit:

```bash
python3 scripts/audit_readme.py /path/to/repository/README.md
```

Then render every SVG and inspect it visually. On macOS, a quick local render is:

```bash
sips -s format png assets/readme/hero.svg --out /tmp/hero.png
```

Otherwise use a browser, `rsvg-convert`, or another SVG renderer. Check:

- clipped text and paths;
- text that becomes too small at GitHub width;
- weak contrast in light and dark GitHub surroundings;
- accidental decoration that competes with the project name;
- missing `<title>`, `<desc>`, `viewBox`, or alt text;
- visual material that could belong to any unrelated project.

Make one targeted change, render again, and keep the simpler version when both communicate equally well.
