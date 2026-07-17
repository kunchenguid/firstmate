# GitHub README canvas

## Reliable building blocks

GitHub README pages reliably support Markdown, tables, links, code blocks, details blocks, and embedded local images. Use HTML only for simple alignment and image sizing.

GitHub displays GIF animation but does not play animation embedded inside SVG. Keep an SVG source and static fallback for every animated visual. Read [motion-production.md](motion-production.md) before building motion.

Recommended image embed:

```html
<p align="center">
  <img src="./assets/readme/hero.svg" width="100%" alt="Project name and plain-language value">
</p>
```

## SVG defaults

- Use a `1200`-unit-wide `viewBox` for full-width modules.
- Typical heights: hero `300–420`, section banner `120–170`, visual explainer `320–760`.
- Include `<title>` and `<desc>` for major visual modules.
- Use system font families such as `-apple-system`, `BlinkMacSystemFont`, `Segoe UI`, `PingFang SC`, and `sans-serif`.
- Keep essential text at least `16` SVG units and section titles at least `36`.
- Use `rx` consistently and keep all important content away from edges.

## Avoid fragile SVG features

Do not depend on:

- `<script>`
- `foreignObject`
- external stylesheets or web fonts
- essential hover states or animation
- remote image URLs inside SVG
- filters that create very large or dirty shadows

Use paths, shapes, text, patterns, gradients, clipping paths, and simple transforms.

## Responsive behavior

GitHub scales the whole image. Small text and dense diagrams become unreadable on mobile. When the body copy matters, keep it in Markdown rather than inside SVG.

Avoid multi-column Markdown tables for long prose. They collapse poorly on narrow screens. Full-width visual boards can contain columns because the composition scales as one image, but text inside them must remain large.

## Asset strategy

Store repository-specific visuals under:

```text
assets/readme/
├── hero.svg
├── hero.gif
├── showcase.png
├── section-*.svg
└── workflow.svg
```

Use lowercase hyphenated names. Remove discarded variants before publishing unless the user wants to retain source explorations.

## Accessibility and trust

- Write alt text that communicates the purpose, not merely “banner”.
- Do not hide install commands or critical instructions inside images.
- Use real outputs and clearly label conceptual visuals.
- Check that text remains readable on both GitHub light and dark page backgrounds; the safest full-width SVG supplies its own background.
