# Deterministic Route Mocking & Fixture Matrix

Visual Regression Testing (VRT) must be 100% deterministic, reproducible offline, and independent of live database states or rate-limit expirations.

---

## 1. Principles of Deterministic VRT

1. **Zero Database Dependency**: Intercept API requests in Playwright using `page.route()` and respond with static, deterministic JSON fixtures.
2. **Frozen Clocks / Time**: If components display relative timestamps (e.g., "5 seconds ago", "updated 12:43 PM"), mock the Date object or inject fixed ISO strings in the payload.
3. **Consistent Dimensions**: Fixed desktop (`1280x900`) and mobile (`390x844`) viewport dimensions.
4. **Font Loading Completion**: Wait for `document.fonts.ready` before taking snapshots to prevent intermittent font rendering diffs.

---

## 2. Playwright Route Mocking Pattern

```javascript
// Intercept state endpoint with static test fixture
await page.route('**/api/state', async (route) => {
  await route.fulfill({
    status: 200,
    contentType: 'application/json',
    body: JSON.stringify(MOCK_FIXTURE_STATE),
  });
});

// Intercept telemetry endpoint
await page.route('**/api/telemetry', async (route) => {
  await route.fulfill({
    status: 200,
    contentType: 'application/json',
    body: JSON.stringify(MOCK_FIXTURE_TELEMETRY),
  });
});
```

---

## 3. Scenario Matrix Template

Each scenario should test a specific component state:

| Scenario ID | Title | Route / State | Interaction Target |
| :--- | :--- | :--- | :--- |
| `01-picker-default` | Column Picker (Closed) | Default state | None |
| `01-picker-open` | Column Picker (Dropdown Open) | Default state | Click `.fqd-col-picker__btn` |
| `02-headroom-default` | Fleet Headroom (Default 50) | Full mock state | None |
| `02-headroom-sim-all` | Fleet Headroom (Simulate All) | Full mock state | Click `.fqd-fleet-headroom__sim-btn:has-text("All")` |
| `05-radar-full` | Quota Radar | Multiple accounts | None |
| `07-drawer-open` | Account Drawer (Open) | Account selected | Click row or trigger drawer open |
