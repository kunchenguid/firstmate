# chrome-devtools-axi browser workaround

On this machine, `chrome-devtools-axi` fails on every page, including a known-good local page, with `Protocol error (Target.setDiscoverTargets): Target closed`.

This is a workaround for an upstream browser-launch defect, not the intended browser design.

The failure is not environment-wide because a hand-launched headless Chrome from `~/.cache/ms-playwright/chromium-1228/chrome-linux64/chrome` returned the DOM for `data:text/html,<h1>hello</h1>`.

The failure is not a missing browser because Puppeteer's `chrome` and `chrome-headless-shell` installations completed under `~/.cache/puppeteer/` while the tool's default launch continued to fail.

The failure is not fixed by `chrome-devtools-axi stop` and a session restart.

The failure is not fixed by `CHROME_DEVTOOLS_AXI_CHROME_ARGS="--no-sandbox --disable-dev-shm-usage --disable-gpu"`.

The verified mechanism is to launch one loopback-only headless Chrome with `bin/fm-browser.sh url` and point `chrome-devtools-axi` at the returned `CHROME_DEVTOOLS_AXI_BROWSER_URL`.

`bin/fm-browser.sh url` reuses the machine-scoped browser when its debug endpoint answers `/json/version`, and starts one only when the probe fails.

Use `bin/fm-browser.sh status` to inspect the endpoint and `bin/fm-browser.sh stop` to terminate only the browser started by the helper.

Set `FM_BROWSER_PORT` to use another loopback port, or set `CHROME_DEVTOOLS_AXI_BROWSER_URL` to repoint a process at an operator-managed browser.
