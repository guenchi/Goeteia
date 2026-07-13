// Live-reload dev server for a Goeteia web project.
//
//   node rt/dev.mjs [port]      # serve the cwd on :8100, watch + reload
//
// Serves the current directory, watches its Scheme/JS/CSS sources, and on
// every save runs the project's ./build.sh (if present) to recompile, then
// pushes a reload over SSE to every open tab. Edit a .ss and the page
// re-renders on save. Project-agnostic: whatever ./build.sh does (SSG here,
// something else elsewhere) is the build step.
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

import http from 'http';
import fs from 'fs';
import path from 'path';
import { execFileSync } from 'child_process';

// Start the live-reload dev server: serve `root`, watch its sources, and
// run root/build.sh on every save before pushing an SSE reload.
export function startDevServer({ port = 8100, root = process.cwd() } = {}) {
const ROOT = root;
const PORT = port;
const HAS_BUILD = fs.existsSync(path.join(ROOT, 'build.sh'));

const MIME = {
  '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8',
  '.wasm': 'application/wasm', '.ss': 'text/plain; charset=utf-8',
  '.md': 'text/plain; charset=utf-8', '.json': 'application/json',
  '.png': 'image/png', '.svg': 'image/svg+xml', '.ico': 'image/x-icon',
};

// injected into every served .html: reconnecting SSE that reloads
// the tab.  Only the visible tab holds its stream -- browsers allow
// ~6 connections per host, and a pile of background example tabs
// each pinning one starves every new page into a blank screen.
const RELOAD_SNIPPET =
  '<script>(function(){var e=null,b=null;' +
  'function c(){if(e||document.hidden)return;e=new EventSource("/livereload");' +
  'e.onmessage=function(m){' +
  'if(m.data==="reload")location.reload();' +
  'else if(m.data.indexOf("build ")===0){' +
  'if(b!==null&&m.data!==b)location.reload();b=m.data}};' +
  'e.onerror=function(){if(e){e.close();e=null}setTimeout(c,500)}}' +
  'document.addEventListener("visibilitychange",function(){' +
  'if(document.hidden){if(e){e.close();e=null}}else c()});' +
  'c()})()</script>';

const clients = new Set();
let buildN = 0;                        // so reconnects catch missed reloads
const notifyReload = () => {
  buildN++;
  for (const r of clients) r.write('data: reload\n\n');
};

function build() {
  if (!HAS_BUILD) { notifyReload(); return; }
  const t0 = Date.now();
  try {
    execFileSync('sh', ['build.sh'], { cwd: ROOT, stdio: 'pipe' });
    console.log(`  built in ${Date.now() - t0} ms`);
    notifyReload();
  } catch (e) {
    console.error(`  build error:\n${((e.stdout || '') + (e.stderr || '')).toString().trim() || e.message}`);
  }
}

// ---- watch source files (debounced), ignore build outputs and vcs ----
const SRC = /\.(ss|css|mjs|js)$/;
const IGNORE = /(^|\/)(\.git|node_modules)(\/|$)/;
let timer = null;
function onChange(file) {
  if (!file || !SRC.test(file) || IGNORE.test(file)) return;
  clearTimeout(timer);
  timer = setTimeout(() => { console.log(`change -> ${file}`); build(); }, 60);
}
fs.watch(ROOT, { recursive: true }, (_e, f) => onChange(f));

// ---- serve ----
http.createServer((req, res) => {
  const url = decodeURIComponent(req.url.split('?')[0]);
  if (url === '/livereload') {
    res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' });
    res.write('retry: 500\n\n');
    res.write('data: build ' + buildN + '\n\n');
    clients.add(res);
    req.on('close', () => clients.delete(res));
    return;
  }
  const file = path.join(ROOT, url === '/' ? 'index.html' : url);
  if (!file.startsWith(ROOT)) { res.writeHead(403); return res.end(); }
  fs.readFile(file, (err, buf) => {
    if (err) { res.writeHead(404); return res.end('not found'); }
    const ext = path.extname(file);
    res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    if (ext === '.html') buf = Buffer.from(buf.toString().replace('</body>', RELOAD_SNIPPET + '</body>'));
    res.end(buf);
  });
}).listen(PORT, () => {
  console.log(`Goeteia dev server: http://localhost:${PORT}  (cwd: ${ROOT})`);
  console.log(HAS_BUILD ? 'watching sources; ./build.sh runs on save.' : 'watching sources; no build.sh -- reload only.');
  build();
});
}

if (import.meta.url === `file://${process.argv[1]}`) {
  startDevServer({ port: Number(process.argv[2]) || 8100 });
}
