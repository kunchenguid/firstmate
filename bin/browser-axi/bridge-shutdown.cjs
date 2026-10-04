const http = require("node:http");
const {syncBuiltinESMExports} = require("node:module");
const {basename} = require("node:path");

if (/^chrome-devtools-axi-bridge\.(?:js|ts)$/.test(basename(process.argv[1] || ""))) {
  const createServer = http.createServer;
  http.createServer = function (...args) {
    const listener = args[0];
    if (typeof listener === "function") {
      args[0] = function (request, response) {
        if (request.method === "POST" && request.url === "/firstmate/shutdown") {
          const host = request.headers.host || "";
          const origin = request.headers.origin;
          const expected = process.env.CHROME_DEVTOOLS_AXI_SESSION || "";
          const supplied = request.headers["x-firstmate-browser-session"];
          if (!/^(?:127\.0\.0\.1|localhost|\[::1\])(?::[0-9]+)?$/.test(host) || origin !== undefined || expected === "" || supplied !== expected) {
            response.writeHead(403, {"content-type": "application/json"});
            response.end(JSON.stringify({status: "forbidden"}));
            return;
          }
          response.writeHead(202, {"content-type": "application/json"});
          response.end(JSON.stringify({status: "stopping", session: expected}), () => {
            process.kill(process.pid, "SIGTERM");
          });
          return;
        }
        return listener.apply(this, arguments);
      };
    }
    return createServer.apply(this, args);
  };
  syncBuiltinESMExports();
}
