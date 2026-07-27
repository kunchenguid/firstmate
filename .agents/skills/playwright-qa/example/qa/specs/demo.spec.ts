import { test, expect } from '@playwright/test';
import { pathToFileURL } from 'node:url';
import path from 'node:path';

// Self-contained proof that the scaffolded harness runs: it drives the static
// index.html one directory up, exercises a render -> click -> assert flow, and
// writes exact-viewport screenshot evidence. Runs once per named viewport
// project (see playwright.config.ts), so `npx playwright test` produces one PNG
// per viewport under qa/screenshots/.
const pageUrl = pathToFileURL(path.resolve(__dirname, '../../index.html')).href;

test('demo page renders and reacts to a click', async ({ page }, testInfo) => {
  await page.goto(pageUrl);

  // Assert the page rendered.
  await expect(page.getByRole('heading', { level: 1 })).toHaveText(
    'Firstmate Playwright QA harness',
  );
  await expect(page.locator('#status')).toHaveText('Ready.');

  // Drive an interaction and assert the result.
  await page.getByRole('button', { name: 'Run the checks' }).click();
  await expect(page.locator('#status')).toHaveText('Checks passed.');

  // Capture exact-viewport visual evidence.
  await page.screenshot({
    path: `qa/screenshots/demo-${testInfo.project.name}.png`,
  });
});
