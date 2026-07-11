// Live-reload dev server for the Goeteia site.
//
//   node dev.mjs           # serve on http://localhost:8100, watch + reload
//
// Watches the Scheme page sources, the shared chrome/libraries and the
// stylesheets; on any change it rebuilds the affected pages with the
// self-hosted compiler (~30 ms each) and tells open browsers to reload.
// Edit a site/*.ss and the page re-renders on save.
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

import http from 'http';
import fs from 'fs';
import path from 'path';
import { execFileSync } from 'child_process';

const ROOT = path.dirname(new URL(import.meta.url).pathname);
const PORT = Number(process.argv[2]) || 8100;
const PAGES = ['index', 'why', 'agent', 'manual'];

const MIME = {
  '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8',
  '.wasm': 'application/wasm', '.ss': 'text/plain; charset=utf-8',
  '.md': 'text/plain; charset=utf-8', '.json': 'application/json',
  '.png': 'image/png', '.svg': 'image/svg+xml', '.ico': 'image/x-icon',
};

// injected into every served .html: reconnect-on-drop SSE that reloads
const RELOAD_SNIPPET =
  '<script>(function(){function c(){var e=new EventSource("/livereload");' +
  'e.onmessage=function(m){if(m.data==="reload")location.reload()};' +
  'e.onerror=function(){e.close();setTimeout(c,500)}}c()})()</script>';

const clients = new Set();
function notifyReload() { for (const res of clients) res.write('data: reload\n\n'); }

// ---- build ----
function buildPage(page) {
  execFileSync('node', ['rt/compile.mjs', 'goeteia.wasm', `site/${page}.ss`, `/tmp/dev-${page}.wasm`], { cwd: ROOT });
  execFileSync('node', ['rt/run.mjs', `/tmp/dev-${page}.wasm`], { cwd: ROOT });
}
function rebuild(pages) {
  const t0 = Date.now();
  try {
    for (const p of pages) buildPage(p);
    console.log(`  rebuilt ${pages.join(', ')} in ${Date.now() - t0} ms`);
    notifyReload();
  } catch (e) {
    const msg = (e.stdout?.toString() || '') + (e.stderr?.toString() || '') || e.message;
    console.error(`  build error:\n${msg.trim()}`);
  }
}

// which pages does a changed file affect?
function affectedBy(file) {
  const m = file.match(/site\/(index|why|agent|manual)\.(ss|css)$/);
  if (m) return [m[1]];                 // one page's own source or css
  return PAGES;                         // chrome, libs, prelude, hero -> all
}

// ---- watch (debounced) ----
const WATCH = ['site', 'lib/web', 'rt'];
const pending = new Set();
let timer = null;
function onChange(file) {
  if (!/\.(ss|css|mjs)$/.test(file)) return;
  for (const p of affectedBy(file)) pending.add(p);
  clearTimeout(timer);
  timer = setTimeout(() => {
    const pages = [...pending]; pending.clear();
    console.log(`change -> ${file}`);
    rebuild(pages);
  }, 60);
}
for (const dir of WATCH) {
  const abs = path.join(ROOT, dir);
  if (fs.existsSync(abs))
    fs.watch(abs, { recursive: true }, (_e, f) => f && onChange(path.join(dir, f)));
}
// hero.ss and chrome dependencies at odd paths
for (const f of ['hero.ss', 'site/chrome.ss', 'src/prelude.ss'])
  if (fs.existsSync(path.join(ROOT, f)))
    fs.watchFile(path.join(ROOT, f), { interval: 200 }, () => onChange(f));

// ---- serve ----
http.createServer((req, res) => {
  const url = decodeURIComponent(req.url.split('?')[0]);
  if (url === '/livereload') {
    res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' });
    res.write('retry: 500\n\n');
    clients.add(res);
    req.on('close', () => clients.delete(res));
    return;
  }
  let file = path.join(ROOT, url === '/' ? 'index.html' : url);
  if (!file.startsWith(ROOT)) { res.writeHead(403); return res.end(); }
  fs.readFile(file, (err, buf) => {
    if (err) { res.writeHead(404); return res.end('not found'); }
    const ext = path.extname(file);
    res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    if (ext === '.html') buf = Buffer.from(buf.toString().replace('</body>', RELOAD_SNIPPET + '</body>'));
    res.end(buf);
  });
}).listen(PORT, () => {
  console.log(`Goeteia dev server: http://localhost:${PORT}`);
  console.log('watching site/*.ss, *.css, chrome + libs -- edit and save to re-render.');
  rebuild(PAGES);
});
