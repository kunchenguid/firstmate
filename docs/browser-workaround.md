# chrome-devtools-axi browser workaround

The upstream launch defect presents on every page, including a known-good local page, as `Protocol error (Target.setDiscoverTargets): Target closed`.

This is a workaround for an upstream browser-launch defect, not the intended browser design.

The failure is not environment-wide because a hand-launched headless Chrome returned the DOM for a known-good data URL.

The failure is not a missing browser because installed Puppeteer browsers do not repair the tool's default launch.

The failure is not fixed by `chrome-devtools-axi stop` and a session restart.

The failure is not fixed by `CHROME_DEVTOOLS_AXI_CHROME_ARGS="--no-sandbox --disable-dev-shm-usage --disable-gpu"`.

The verified mechanism is to launch one machine-scoped, loopback-only headless Chrome with `bin/fm-browser.sh url` and point `chrome-devtools-axi` at the returned `CHROME_DEVTOOLS_AXI_BROWSER_URL`.

`bin/fm-browser.sh url` reuses an endpoint when its `/json/version` probe succeeds, serializes concurrent startup, refuses after a bounded wait, and prints a URL only after the endpoint answers successfully.

Every local crewmate and secondmate launch receives that verified URL on a best-effort basis, unless the operator already supplied `CHROME_DEVTOOLS_AXI_BROWSER_URL`.

Browser failure never blocks a spawn, and an ambient operator URL is preserved unchanged.

Use `bin/fm-browser.sh status` to inspect the endpoint and `bin/fm-browser.sh stop` to terminate only the browser started by the helper.

The default debug port is `9222`, separate from Firstmate's known dashboard, Lavish, and bridge ports; set `FM_BROWSER_PORT` before `url`, `status`, or `stop` to use another loopback port.

Set `CHROME_DEVTOOLS_AXI_BROWSER_URL` before launching a crewmate or secondmate to repoint it at an operator-managed browser without starting the helper browser.
