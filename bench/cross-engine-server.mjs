import { createServer } from 'node:http';
import { readFileSync, existsSync, statSync, appendFileSync } from 'node:fs';
import { join, normalize } from 'node:path';
const root = process.argv[2] || '/tmp/benchsite';
const GIF = Buffer.from([71,73,70,56,57,97,1,0,1,0,128,0,0,0,0,0,255,255,255,33,249,4,1,0,0,0,0,44,0,0,0,0,1,0,1,0,0,2,2,68,1,0,59]);
createServer((req, res) => {
  console.error(req.method, req.url.slice(0, 60));
  if (req.url.startsWith('/bench-report')) {
    const d = new URL(req.url, 'http://x').searchParams.get('d') || '';
    appendFileSync('/tmp/bench-results.txt', d + '\n');
    res.writeHead(200, { 'Content-Type': 'image/gif' });
    res.end(GIF);
    return;
  }
  const p = normalize(join(root, decodeURIComponent(req.url.split('?')[0])));
  if (!p.startsWith(root) || !existsSync(p) || statSync(p).isDirectory()) {
    res.writeHead(404); res.end(); return;
  }
  const data = readFileSync(p);
  const mime = p.endsWith('.html') ? 'text/html'
    : p.endsWith('.mjs') ? 'text/javascript'
    : p.endsWith('.wasm') ? 'application/wasm' : 'application/octet-stream';
  res.writeHead(200, { 'Content-Type': mime });
  res.end(data);
}).listen(8104, () => console.error('bench server on 8104'));
