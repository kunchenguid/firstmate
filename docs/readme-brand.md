# README brand direction: Ember Colossus

The repository front door is the product's first impression, so it carries its own brand rather than reading as a reference document: a dark field, one hot accent, a heavy plate mark, and a mascot that gives the product a face.
This page records the one direction that was built, how its mark and mascot are drawn, and where the artwork plugs into the product.
Two other directions were explored and dropped, and this page no longer carries them.
Asset paths are relative to `data/fd-juggernaut-concept-art/` in the concept-art working folder.

## The idea

Force over polish.
The brand should feel like the moment the wall gives way: hot, heavy, and already moving.
Copy stays short and in the product's own voice - Juggernaut is the agent distro, the Overwatch is the supervisor, operators do the work, and the reader is the captain.
The hero line is "Ship like it's a game." with the promise "Talk to one agent. Ship with a crew."

## The mark: B2 Monolith

A clipped bone plate on a 64x64 grid: a square with two opposite corners chamfered on the same angle as the mascot's armour plates, closed into a solid chin guard with a broad flat chin and a wide jaw.
The faceplate carries a single ember T-visor inside an aperture cut as a knockout, so the plate reads as an opening rather than a filled rectangle; in the one-ink masters the T is itself a knockout.
No gradients, no outline-only variant, and no second accent: the ember T is the one hot element at every size.

It is drawn as three paths in one viewBox, so it holds as vector at any size:

- the plate, filled with the ink colour and knocked out by a mask that cuts the helmet aperture,
- the T-visor cross, filled once in ink and once in ember on top, so the ember sits in the aperture rather than on the plate,
- variants that swap the ink and ember to CSS custom properties (`--mark-ink`, `--mark-accent`), so a host page recolours the mark without a second file.

### How it is drawn small

| Size | Use | What must survive |
| --- | --- | --- |
| 16 px | favicon | The silhouette alone: the flat chin and the plate mass. The mark is 9 px tall, the ember T is the only hot pixel, and the seam never renders. |
| 24 px | smallest inline use | Plate corners and the T-visor; below this size the symbol is used alone and the lockup never appears. |
| 32 px | tab and app icon | The chamfered corners and the chin guard, at the point where they stop being detail and start being shape. |
| 48 px and up | inline symbol, lockup | All of it, including the aperture that separates helmet from plate. |

Clear space is one plate corner - one eighth of the mark width - on every side, and the wordmark never enters it.

Files:

- `svg/d1-mark-b2.svg` - the working mark, recolourable through CSS custom properties.
- `svg/d1-mark-b2-colour.svg` - fixed two-ink colour version.
- `svg/d1-mark-b2-mono-dark.svg` and `svg/d1-mark-b2-mono-light.svg` - one-ink versions for dark and light surfaces.
- `sheets/assets/d1-mark-b2-512.png` and `sheets/assets/d1-mark-b2-mono-512.png` - 512 px raster exports used as the icon source.
- `sheets/assets/favicon/favicon-16.png`, `sheets/assets/favicon/favicon-32.png`, `sheets/assets/favicon/favicon-48.png`, and `sheets/assets/favicon/favicon.svg`. The 16 px PNG is the real tab test; the SVG is the master and the PNGs are exact raster exports of it.

## Wordmark and lockups

The wordmark is heavy condensed grotesque type, set uppercase with tight tracking and a hard baseline, and shipped as outlines so rendering never depends on a font being installed: `svg/d1-wordmark.svg`.
It fills with `currentColor`, so it inherits the surface ink and needs no second file for light or dark.

Three lockups cover the placements:

- **Primary** - symbol at 42 px beside the wordmark at 34 px cap height, on the dark field. This is the README and CLI default.
- **Reversed** - the same lockup in one dark ink on the light surface, for the light theme and for print.
- **Stacked** - symbol above the wordmark, for square placements such as the social preview and the first-run splash.

The symbol never sits below the wordmark's own weight: at lockup sizes the mark is at least as tall as the cap height.

## Social preview

The repository social preview is a 1200x630 composition: field colour, the wordmark on the left, the charging mascot bleeding off the right edge, and the tagline in mono caps.
It is exported once at that size - `sheets/d1-ember-colossus-social-1200x630.png` - because a social preview is cropped by the host and cannot be reflowed.

## The mascot

A siege colossus: slab pauldrons, block torso, cracked armour plates with molten ember glowing in the seams, and a hot T-visor inside a heavy faceless helmet.
It is generated concept art, not vector art, so the states ship as raster with one hand-authored vector master for the one-colour cases.

Four states, each a full-body pose on the near-black field with a bone rim light:

- **Idle** - planted, visor level, arms relaxed. The mass reads before the detail does. `img/d1-idle.png`
- **Charging** - a shoulder-first lunge with ember sparks trailing the leading arm. This is the motion frame: it is what the front door animates, what the loading state shows, and what the social preview bleeds off its edge. `img/d1-charging.png`
- **Secured** - fist raised with the seams at full glow. The win state, for a finished run. `img/d1-secured.png`
- **Pinned** - a damaged shoulder and dust at the feet. The failure state, for a run that stopped short. `img/d1-pinned.png`

Each pose has a one-colour check for placement on a single-ink surface and a rim composite for bleeds - for the idle pose `sheets/assets/d1-idle-mono.png`, `sheets/assets/d1-idle-mono-light.png`, and `sheets/assets/d1-idle-rim.png` - and the same three files exist for the other poses.
The one-colour masters are hand-authored SVG - `svg/d1-helmet-mono.svg` and `svg/d1-silhouette-mono.svg` - and the T-visor is a knockout in those too, never a painted accent.

## Palette

| Token | Dark field | Light surface |
| --- | --- | --- |
| Field | `#0A0908` | `#EFEAE1` |
| Ink | `#EDE6DA` bone | `#141210` |
| Accent | `#FF5A1F` ember | `#FF5A1F` |
| Accent, deep | `#C8330A` | `#C8330A` |

One accent hue, a dark field as the default theme, and a light theme behind `prefers-color-scheme`, so every hero asset is a `<picture>` pair rather than a single image.
The app icon carries its own dark field, so it holds on a light home screen without a second version.

## Where it wires in

1. **README hero** - replaces the current title block, badges and strapline with the social-preview composition at page width, plus a light and dark `<picture>` pair. Requirements and quick start stay accurate: a verified primary agent harness, git plus a `gh auth login`, and the CLI and dependencies for the chosen runtime backend with tmux as the reference default.
2. **Repository social preview** - the 1200x630 export above, uploaded as the repository's social preview image.
3. **CLI banner and first-run splash** - the primary lockup on the field colour for the banner, the stacked lockup plus the idle mascot for the splash.
4. **Loading and empty states** - "Muster the crew" with the charging frame while work stands up, and "No crew mustered" with the idle mascot when there is nothing running. Both need a still pose first, which the four states already carry.
5. **Terminal animation** - the mascot's motion frames replace the working boat animation, with charging for work under way, secured for a clean finish, and pinned for a failure.

Assets land as committed SVGs plus raster exports for the social preview and the icon sizes above, so no wiring step depends on regenerating concept art.
