import { test, expect } from "@playwright/test";

/**
 * Bounded Phase 2 browser pilot.
 * Proves Playwright wiring + anonymous visitor can open the public site.
 * Full collection submit/approve flow belongs to the gallery app e2e suite.
 */
const base = process.env.PLAYWRIGHT_BASE_URL || "http://127.0.0.1:3000";

test.describe("persona: Anonymous visitor", () => {
  test("public home responds", async ({ page }) => {
    const res = await page.goto(base, { waitUntil: "domcontentloaded" });
    expect(res).not.toBeNull();
    expect(res!.ok() || res!.status() === 304).toBeTruthy();
    await page.screenshot({ path: "test-results/phase2-pilot-home.png", fullPage: true });
  });
});
