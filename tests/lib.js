// Shared bits for the Log tests: a static server for ios-app/www, the mocked backend, and checks.
const http = require("http");
const fs = require("fs");
const path = require("path");
const { makeFixture } = require("./fixture");

const PORT = Number(process.env.LOG_PORT || 4173);
const BASE = `http://localhost:${PORT}/`;
const WWW = path.join(__dirname, "..", "ios-app", "www");
const SHOTS = process.env.LOG_SHOTS || path.join(__dirname, "shots");
const API = "https://qnbshmenmurdaogslmrj.supabase.co/functions/v1/**";
const CLOCK = new Date("2026-11-24T23:20:00-06:00");
const PASSCODE = "2468"; // fake, for the mock only
const CORS = {
  "access-control-allow-origin": `http://localhost:${PORT}`,
  "access-control-allow-headers": "x-log-passcode, x-log-token, content-type",
  "access-control-allow-methods": "GET, POST, OPTIONS",
};
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".json": "application/json", ".webmanifest": "application/manifest+json", ".png": "image/png", ".svg": "image/svg+xml", ".ico": "image/x-icon" };

fs.mkdirSync(SHOTS, { recursive: true });

/* Serve ios-app/www. If something already listens on the port, use that. */
function serve() {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      const url = decodeURIComponent(new URL(req.url, BASE).pathname);
      let file = path.normalize(path.join(WWW, url));
      if (!file.startsWith(WWW)) { res.writeHead(403); return res.end(); }
      if (fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, "index.html");
      fs.readFile(file, (err, buf) => {
        if (err) { res.writeHead(404); return res.end("not found"); }
        res.writeHead(200, { "content-type": TYPES[path.extname(file)] || "application/octet-stream", "cache-control": "no-store" });
        res.end(buf);
      });
    });
    server.once("error", () => resolve({ close: () => {} }));
    server.listen(PORT, "127.0.0.1", () => resolve(server));
  });
}

function checker() {
  const results = [];
  const check = (name, ok, detail) => {
    results.push({ name, ok: !!ok });
    console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? "  " + detail : ""}`);
  };
  check.failed = () => results.filter((r) => !r.ok).map((r) => r.name);
  check.count = () => results.length;
  return check;
}

const json = (body, status) => ({ status: status || 200, headers: { ...CORS, "content-type": "application/json" }, body: JSON.stringify(body) });

module.exports = { serve, checker, json, makeFixture, PORT, BASE, WWW, SHOTS, API, CLOCK, PASSCODE, CORS };
