---
name: styles-ui
description: Generate a production-grade style-system skill at the quality of skeuomorphic-ui and glassmorphism. Invoke with /styles-ui <style-name> to create a complete SKILL.md that defines the visual language, tokens, component patterns, and quality checklist for a design system.
user-invocable: true
metadata:
  internal: true
---

# Styles UI

Generate a complete, production-grade style-system SKILL.md. The output must match the quality bar of `skeuomorphic-ui` and `glassmorphism` — not a palette dump, not a vibe description, but a buildable system that another agent can execute without asking follow-up questions.

## Invocation

```
/styles-ui <style-name>
```

The style name is kebab-case. Examples: `glassmorphism`, `skeuomorphic`, `brutalist-warm`, `editorial-dark`, `soft-industrial`.

## Generation Process

### Phase 1 — STYLE INTERROGATION

Before writing the skill file, answer these seven questions about the style. Each answer must be specific — no "depends on context" or "varies by component."

1. **Lighting model.** Where does light come from? (top, ambient, none, multiple sources) What does it hit first?
2. **Material.** What is the dominant surface material? (glass, metal, paper, plastic, nothing/digital-native) What are its optical properties?
3. **Depth language.** How does this style communicate layers? (shadows, blur, transparency, border-only, color-shift, nothing/flat)
4. **Color temperature.** Warm, cool, or neutral? What's the dominant undertone?
5. **Typography posture.** Serif, sans, mono? What's the voice — commanding, quiet, technical, editorial, playful?
6. **Density appetite.** Does this style breathe (generous whitespace) or pack (information-dense)? What's the typical content-to-chrome ratio?
7. **Motion character.** Sharp/snappy, liquid/smooth, or none? What's the default easing personality?

### Phase 2 — SYSTEM GENERATION

Generate the SKILL.md with these mandatory sections. Every section must contain concrete, copyable values — not prose descriptions of what values could be.

```markdown
---
name: <style-name>
description: "<one-line production-context trigger description>"
---

# <Style Title>

## Visual Language

One paragraph that captures the lighting model, material, depth language, and emotional register. This is what an agent reads to understand the aesthetic in 10 seconds.

## Color System

### Surfaces (dark/light or single-mode)
| Token | Value | Usage |
|--------|--------|-------|
| `--bg-root` | `#...` | Page background |
| `--bg-surface` | `#...` | Card, panel, modal |
| `--bg-surface-raised` | `#...` | Hover, active, dropdown |
| `--bg-surface-overlay` | `#...` | Modal backdrop, sheet |

### Text
| Token | Value | Usage |
|--------|--------|-------|
| `--text-primary` | `#...` | Headings, body |
| `--text-secondary` | `#...` | Labels, captions, muted |
| `--text-tertiary` | `#...` | Placeholders, disabled |

### Borders & Dividers
| Token | Value | Usage |
|--------|--------|-------|
| `--border-default` | `#...` | Card borders, inputs |
| `--border-subtle` | `#...` | Dividers, separators |
| `--border-focus` | `#...` | Focus rings |

### Accents
| Token | Value | Usage |
|--------|--------|-------|
| `--accent-primary` | `#...` | Primary buttons, links, active |
| `--accent-danger` | `#...` | Destructive actions |
| `--accent-success` | `#...` | Confirmation, positive metrics |

### Effects (if applicable)
| Token | Value | Usage |
|--------|--------|-------|
| `--glass-blur` | `...px` | Frosted surfaces |
| `--glass-opacity` | `0.XX` | Surface transparency |
| `--shadow-card` | `...` | Card elevation |
| `--shadow-modal` | `...` | Modal elevation |
| `--inner-glow` | `...` | Inset depth |

## Typography

### Scale
| Level | Size | Weight | Line-height | Usage |
|--------|------|--------|-------------|-------|
| `display` | `...` | `...` | `...` | Hero, empty states |
| `h1` | `...` | `...` | `...` | Page titles |
| `h2` | `...` | `...` | `...` | Section headers |
| `h3` | `...` | `...` | `...` | Card titles |
| `body` | `...` | `...` | `...` | Paragraphs, descriptions |
| `body-sm` | `...` | `...` | `...` | Labels, metadata |
| `caption` | `...` | `...` | `...` | Timestamps, footnotes |
| `mono` | `...` | `...` | `...` | Code, data, keys |

### Font Stack
```
--font-sans: '...', ...;
--font-mono: '...', ...;
```

## Spacing

| Token | Value | Usage |
|--------|--------|-------|
| `--space-xs` | `...px` | Icon padding, tight inline |
| `--space-sm` | `...px` | Input padding, small gaps |
| `--space-md` | `...px` | Card padding, section gaps |
| `--space-lg` | `...px` | Section spacing, modal padding |
| `--space-xl` | `...px` | Page margins, hero spacing |
| `--space-2xl` | `...px` | Major section breaks |

## Radius

| Token | Value | Usage |
|--------|--------|-------|
| `--radius-sm` | `...px` | Buttons, inputs, tags |
| `--radius-md` | `...px` | Cards, panels, modals |
| `--radius-lg` | `...px` | Large containers, sheets |
| `--radius-full` | `9999px` | Pills, avatars |

## Component Patterns

### Buttons
- Primary: [describe visual treatment — fill, border, shadow, hover]
- Secondary: [describe]
- Ghost: [describe]
- Danger: [describe]
- Sizes: sm, md, lg — specific padding and font sizes
- States: default, hover, active, focus-visible, disabled

### Inputs
- Default: [describe visual treatment]
- Focus: [describe ring/glow behavior]
- Error: [describe]
- Disabled: [describe]
- Placeholder style: [color, weight, italic?]

### Cards
- Default: [surface, border, shadow, radius, padding]
- Interactive: [hover lift, border change, shadow change]
- Header/body/footer layout convention

### Modals / Sheets
- Backdrop: [color, opacity, blur]
- Panel: [surface, shadow, radius, max-width, position]
- Close affordance: [position, style]

### Empty / Loading / Error States
- Empty: [illustration style, copy tone, CTA]
- Loading: [skeleton vs spinner rule, skeleton shape rules]
- Error: [icon, copy tone, retry affordance]

## Motion

### Defaults
- Duration: `...ms` for micro, `...ms` for entrance, `...ms` for page transitions
- Easing: `cubic-bezier(...)` for enter, `cubic-bezier(...)` for exit
- Hover: `...ms` transition on background/border/shadow

### Specific Animations
- Page enter: [describe — fade, slide, scale, none]
- Modal open: [describe]
- List item enter: [staggered, none, etc.]
- Notification: [slide-in direction, auto-dismiss timing]

## Layout Conventions

- Max content width: `...px`
- Sidebar width (if applicable): `...px`
- Grid: `...` columns, `...px` gap
- Responsive breakpoints: sm (`...px`), md (`...px`), lg (`...px`), xl (`...px`)

## Anti-Patterns

- Never [common mistake for this style]
- Never [another common mistake]
- [At least 3 concrete "never" rules]

## Quality Checklist

- [ ] Color tokens used consistently — no raw hex values in components
- [ ] Typography scale applied — no ad-hoc font sizes
- [ ] Spacing tokens used — no magic numbers
- [ ] All interactive elements have hover, focus-visible, and active states
- [ ] Empty, loading, and error states exist for data-dependent views
- [ ] Dark/light mode tokens defined (if applicable)
- [ ] Motion respects `prefers-reduced-motion`
- [ ] Focus rings visible and consistent
- [ ] Touch targets >= 44px for interactive elements
```

### Phase 3 — QUALITY GATE

Before delivering the generated skill, verify:

- [ ] Every token table has concrete values, not placeholders
- [ ] The visual language paragraph could only describe this style — it is not generic
- [ ] At least 5 component patterns are specified with all states
- [ ] Anti-patterns are specific to this style, not universal rules
- [ ] The quality checklist has 8+ items
- [ ] Color values are internally consistent (same temperature, same saturation band)

If any verification fails, fix the section before delivering.

### Phase 4 — DELIVER

Write the generated SKILL.md to the path the captain specifies, or to `.agents/skills/<style-name>/SKILL.md` by default.

After writing, state:
- The file path
- One-line summary of the visual language
- Three distinctive decisions that make this style different from generic output
