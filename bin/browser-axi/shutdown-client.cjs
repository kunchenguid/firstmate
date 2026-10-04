const http = require("node:http");

const port = Number(process.argv[2]);
const expected = process.argv[3];
if (!Number.isInteger(port) || port < 1 || port > 65535 || !/^fm-[0-9a-f]{40}$/.test(expected || "")) {
  process.exit(2);
}

const request = http.request({
  hostname: "127.0.0.1",
  port,
  path: "/firstmate/shutdown",
  method: "POST",
  timeout: 2000,
  headers: {"x-firstmate-browser-session": expected},
}, response => {
  let body = "";
  response.setEncoding("utf8");
  response.on("data", chunk => { body += chunk; });
  response.on("end", () => {
    try {
      const result = JSON.parse(body);
      process.exitCode = response.statusCode === 202 && result.status === "stopping" && result.session === expected ? 0 : 1;
    } catch {
      process.exitCode = 1;
    }
  });
});
request.on("timeout", () => request.destroy());
request.on("error", () => { process.exitCode = 1; });
request.end();
