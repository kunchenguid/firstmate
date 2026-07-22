# Playwright QA harness - runnable example

This directory is the proof that the `playwright-qa` skill's harness works end to end.
It was produced by running `bin/fm-playwright-scaffold.sh` into this folder, adding a static `index.html`, and running the demo spec at both default viewports.

## What is here

- `index.html` - a static demo page with a heading and a button that flips a status line.
- `playwright.config.ts` - scaffolded config: headless, isolated, one project per named viewport (`desktop-1857x933`, `laptop-1440x900`).
- `qa/specs/demo.spec.ts` - drives `index.html` over a `file://` URL: render assert, click, result assert, then an exact-viewport screenshot.
- `qa/screenshots/demo-*.png` - the committed visual evidence, one PNG per viewport.
- `.gitignore` - keeps `node_modules/`, `package-lock.json`, and `qa/results/` out of git; only the screenshots are committed.

## Reproduce it

```sh
npm install -D @playwright/test
npx playwright install chromium
npx playwright test
```

Both projects pass and rewrite `qa/screenshots/demo-desktop-1857x933.png` (1857x933) and `qa/screenshots/demo-laptop-1440x900.png` (1440x900).

Nothing here installs into the firstmate repo: Playwright installs into this example's own gitignored `node_modules/`, exactly as it would install into a real target project.
