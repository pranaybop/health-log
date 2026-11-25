/*
  Offline shell for Log. Network first for this site's own files, so a new deploy
  always wins when there's a connection; the cached copy is only used offline.
  Data never goes through here: the Supabase calls are cross-origin and pass straight by,
  and the last dashboard data is kept by the page itself (localStorage "log.cache").
*/
const CACHE = "log-shell-v1";

self.addEventListener("install", () => self.skipWaiting());

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    for (const key of await caches.keys()) if (key !== CACHE) await caches.delete(key);
    await self.clients.claim();
  })());
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  event.respondWith((async () => {
    const cache = await caches.open(CACHE);
    try {
      const res = await fetch(req);
      if (res && res.ok) cache.put(req, res.clone());
      return res;
    } catch (err) {
      const hit = await cache.match(req, { ignoreSearch: req.mode === "navigate" });
      if (hit) return hit;
      if (req.mode === "navigate") {
        const shell = await cache.match("./") || await cache.match("./index.html");
        if (shell) return shell;
      }
      throw err;
    }
  })());
});
