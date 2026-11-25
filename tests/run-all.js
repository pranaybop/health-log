// Runs every test in order and exits non-zero if any fails. `npm test` from tests/.
const { spawnSync } = require("child_process");
const path = require("path");

const runs = [
  ["ui.test.js", "light"],
  ["ui.test.js", "dark"],
  ["health.test.js"],
  ["offline.test.js"],
  ["fit.test.js"],
];
const failed = [];
for (const [file, arg] of runs) {
  const label = arg ? `${file} ${arg}` : file;
  console.log(`\n=== ${label}`);
  const r = spawnSync(process.execPath, [path.join(__dirname, file), ...(arg ? [arg] : [])], { stdio: "inherit", env: process.env });
  if (r.status !== 0) failed.push(label);
}
console.log(failed.length ? `\n${failed.length} failed: ${failed.join(", ")}` : "\nEverything passed.");
process.exit(failed.length ? 1 : 0);
