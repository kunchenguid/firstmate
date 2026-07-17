# GitHub-safe README motion

Use motion only when it explains a sequence, transition, state change, or relationship. GIF is opt-in and never the default. Keep the static SVG as the editable source and fallback; GitHub does not play animation embedded inside SVG, so deliver a GIF for the README only after the user explicitly chooses motion.

## Confirm the output

When a hero, badge, workflow, or diagram has meaningful motion and the user has not specified static or animated output, ask once:

> Should this stay as a static SVG, or would you like a GitHub-safe GIF animation with the SVG kept as the editable fallback?

Do not ask when motion would be purely decorative or the user already chose an output.
If the user declines or does not answer, continue with static SVG only.

## Make motion feel comfortable

- Animate only the few layers needed to explain the idea. One to three focal movements are usually enough.
- Keep entry travel short and visually related to the composition. Start around `4–8%` of the canvas dimension instead of sending elements across the whole frame.
- Use calm ease-out movement around `0.7–1.2 seconds`. Let elements arrive naturally; do not add bounce, elastic overshoot, or abrupt direction changes by default.
- Leave enough still time to read the finished composition. A `1.5–2.5 second` settled hold is a useful starting point.
- Once an element settles, keep it pixel-still. Avoid idle bobbing, pulsing, floating, or rotation unless it communicates a real live state.
- Do not animate every label, icon, and background detail. Motion needs one clear reading order, not constant activity.
- Keep entrance and exit subordinate to the content. If viewers notice the animation technique before they understand the project, simplify it.
- Make the last frame match the first frame so the loop restarts without a visible jump.

## Motion defaults

- Start from an approved static SVG. Motion should clarify it, not rescue a weak composition.
- Use `30 FPS`, `4–6 seconds`, and a calm loop as starting points.
- Size raster output for the real embed. Start at the SVG's native canvas width—usually `1200px` for this Skill—and preview it at GitHub's actual content width before increasing resolution. Native-size rendering avoids resampling noise and can be much smaller while looking indistinguishable after browser downscaling. Use `1440–1600px` only when small text genuinely needs it and the loading cost remains acceptable; use `960px` for smaller embeds or previews.
- Keep the first frame meaningful and preserve essential text in Markdown or the static fallback.
- Animate a few semantic layers. Avoid moving grids, noise, gradients, or the whole canvas because full-frame changes inflate the GIF.
- Use ease-out entry, a genuinely still hold, and a short exit that returns cleanly to the first frame.
- Once an element settles, keep it pixel-still unless continuous movement communicates real state. Do not add idle bobbing by default; a one-pixel handoff can look like jitter.
- Avoid flashes, rapid pulses, and motion that competes with reading.

## Prepare the SVG and motion spec

Give every animated SVG element a stable `id`. Keep inherited transforms and typography on its ancestor groups; the renderer preserves the ancestor chain when extracting a layer.

Create a JSON spec next to the SVG:

```json
{
  "width": 1200,
  "fps": 30,
  "duration": 5.0,
  "colors": 256,
  "dither": "none",
  "clip_to_base_alpha": true,
  "max_size_mb": 2.0,
  "reveals": [
    {
      "id": "title-highlight",
      "axis": "x",
      "start": 0.25,
      "end": 1.25,
      "exit": {"start": 4.1, "end": 4.96}
    }
  ],
  "layers": [
    {
      "id": "project-card",
      "enter": {"start": 0.4, "end": 1.3, "from": [72, -22]},
      "exit": {"start": 4.1, "end": 4.96, "to": [20, -10]}
    }
  ]
}
```

Offsets use source-SVG units and scale with the requested output width.
Use `clip_to_base_alpha: true` when moving layers must stay inside a rounded full-frame background. Leave it off for assets whose base layer contains intentional transparent holes.

## Render the GIF

The bundled script requires Python with Pillow, `ffmpeg`, and either `rsvg-convert` or macOS `sips`:

```bash
python3 scripts/render_motion_gif.py \
  assets/readme/hero.svg \
  assets/readme/hero.gif \
  --spec assets/readme/hero-motion.json
```

Use `--keep-frames /tmp/readme-motion-frames` only when individual layers or frames need inspection.

## Keep flat animation compact

- Use one shared palette and `diff_mode=rectangle` so frames store only changed regions.
- Prefer the SVG's native pixel width or a clean integer scale. Arbitrary upscaling introduces interpolation colors that increase GIF size without necessarily improving the README-sized result. Compare candidates at the final CSS width, not at 100% pixels.
- Start with `192` colors for simple flat artwork. Use the full `256` colors when the composition contains prominent text, gradients, translucent shapes, or is displayed full-width.
- Use `dither: none` for large flat fills, text, and interface geometry. Dithering adds moving pixel noise, makes the image dirtier, and increases file size.
- Add dithering only for gradients or photographic material after comparing the rendered result.
- Keep settled frames identical. A still hold compresses well and feels calmer.
- Preserve transparent corners in the final GIF. For rounded artwork, clip every visual layer to the same rounded frame; otherwise square corners or escaped decoration will appear on GitHub. The bundled script converts frame alpha to a reserved chroma key for compact RGB delta encoding, then marks that palette entry transparent in the GIF. If the artwork visibly uses the configured `transparent_color`, the script stops and asks for a different unused key instead of silently creating holes.
- Keep the transparent silhouette stable across the loop. Put moving layers inside an opaque or clipped frame; changing transparent boundaries can leave trails in GIF decoders, so the bundled script rejects them.
- Aim for about `2 MB` for a full-width animated hero and treat `5 MB` as a practical ceiling, even when the hosting limit is larger. If the animation cannot stay light, keep the first-screen hero static and place a smaller GIF demonstration later in the README.

## Verify before embedding

1. Inspect entry, the first settled frame, the full hold, exit, and loop boundary.
2. Confirm settled frames are pixel-identical; unexpected differences reveal idle movement or rendering noise.
3. Check the GIF at GitHub content width and on a narrow viewport.
4. Verify frame count, FPS, duration, dimensions, and size with `ffprobe`.
5. Keep the static SVG in the repository even when the README embeds the GIF.
6. Do not replace a README image reference without explicit approval.
