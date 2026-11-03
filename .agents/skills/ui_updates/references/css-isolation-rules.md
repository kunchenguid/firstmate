# CSS Isolation Rules & Scoping Standards

These rules ensure that UI components remain completely isolated and never cause CSS regressions across the fleet.

---

## 1. Forbidden Selectors (Zero Tolerance)

The following selector patterns are **strictly prohibited** in component-level stylesheets:

```css
/* ? BANNED: Bare element selectors */
button { ... }
input { ... }
select { ... }
textarea { ... }
label { ... }
table { ... }
th, td { ... }
h1, h2, h3, h4, h5, h6 { ... }
p, span, a { ... }

/* ? BANNED: Generic un-prefixed class names */
.card { ... }
.header { ... }
.active { ... }
.btn { ... }
.title { ... }
.container { ... }

/* ? BANNED: Universal or loose wildcard selectors */
* { ... }
*:before, *:after { ... }
div > button { ... }
```

---

## 2. Mandatory Scoped BEM Conventions

All styles must belong to a scoped block prefixed with the project and component name:

```css
/* Component Block */
.<project>-<component> {
  box-sizing: border-box;
  /* Local design tokens */
  --comp-bg: #111827;
  --comp-border: rgba(255, 255, 255, 0.1);
  --comp-text: #f9fafb;
}

/* Component Elements */
.<project>-<component>__header {
  display: flex;
  align-items: center;
  justify-content: space-between;
}

.<project>-<component>__btn {
  appearance: none;
  border: 1px solid var(--comp-border);
  background: var(--comp-bg);
  color: var(--comp-text);
  border-radius: 6px;
  cursor: pointer;
  transition: all 0.15s ease;
}

/* Component Modifiers */
.<project>-<component>__btn--active {
  background: var(--brand-accent, #3b82f6);
  border-color: var(--brand-accent, #3b82f6);
  color: #ffffff;
}

.<project>-<component>__btn--disabled {
  opacity: 0.5;
  cursor: not-allowed;
}
```

---

## 3. Layout and Overflow Containment

To prevent child components from pushing parent boundaries or causing horizontal scrollbar flashes:
- Use `min-width: 0` on flex items inside headers or card rows.
- Use `minmax(0, 1fr)` for grid columns containing dynamic text.
- Use `overflow: hidden` or `text-overflow: ellipsis` on dynamic labels or monospace IDs.
- Never use fixed pixel widths on container elements where mobile viewports (`390px`) could be squeezed.

---

## 4. Theme & Variable Hygiene

- Read global variables (`var(--bg-main)`, `var(--text-primary)`, `var(--border-subtle)`), but **never override `:root`** in a component CSS file.
- If a component requires custom colors, declare them inside the component's root selector:
  ```css
  .fqd-quota-radar {
    --radar-ring-color: rgba(99, 102, 241, 0.2);
    --radar-sweep-speed: 2.5s;
  }
  ```
