// The dev server must forbid caching on every response it makes.
// Without this a browser happily reuses a previous build's .wasm or
// .js, so a saved source change appears not to take effect; the only
// workaround is to restart on a different port to mint a fresh origin.
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { startDevServer } from '../rt/dev.mjs';

// a directory with no build.sh: reload-only, so no subprocess runs
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-dev-'));
fs.writeFileSync(path.join(ROOT, 'index.html'),
                 '<html><body><h1>hi</h1></body></html>');
fs.writeFileSync(path.join(ROOT, 'style.css'), 'body{color:red}');
// a wasm preamble is enough; nothing here instantiates it
fs.writeFileSync(path.join(ROOT, 'app.wasm'),
                 Buffer.from([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0]));

// requests go through http.request rather than fetch: WHATWG URL
// parsing collapses `..` segments (even percent-encoded), which would
// rewrite the traversal case before the server ever saw it
function request(port, urlPath) {
    return new Promise((resolve, reject) => {
        const req = http.request({ port, path: urlPath }, res => {
            const chunks = [];
            res.on('data', c => chunks.push(c));
            res.on('end', () => resolve({
                status: res.statusCode,
                headers: res.headers,
                body: Buffer.concat(chunks),
            }));
        });
        req.on('error', reject);
        req.end();
    });
}

// open /livereload and resolve once the greeting has arrived, keeping
// the stream (and its request handle) open for the caller to destroy.
// The retry hint and the build counter are written separately, so they
// need not land in one chunk: read until the second one shows up.
function openSse(port) {
    return new Promise((resolve, reject) => {
        const req = http.request({ port, path: '/livereload' }, res => {
            let seen = '';
            res.on('data', chunk => {
                seen += chunk;
                if (/data: build \d+/.test(seen)) {
                    resolve({ req, headers: res.headers, greeting: seen });
                }
            });
        });
        req.on('error', reject);
        req.end();
    });
}

function assertUncacheable(what, headers) {
    assert.equal(headers['cache-control'], 'no-store',
                 `${what}: Cache-Control must be no-store`);
    assert.equal(headers.pragma, 'no-cache',
                 `${what}: Pragma must be no-cache`);
}

// the server greets on listen and narrates watch events (FSEvents can
// still report the fixture writes above); errors go to console.error,
// which stays untouched
const chatter = console.log;
console.log = () => {};
const server = startDevServer({ port: 0, root: ROOT });
await new Promise(r => server.once('listening', r));
const port = server.address().port;
assert.ok(port > 0, 'port 0 must bind to a real free port');

// a watchdog so a wedged request fails the run instead of hanging it
const watchdog = setTimeout(() => {
    console.error('dev-nocache: timed out');
    process.exit(1);
}, 20000);

// ---- static responses ----
const index = await request(port, '/');
assert.equal(index.status, 200);
assertUncacheable('index.html', index.headers);
assert.match(index.headers['content-type'], /^text\/html/);
// the live-reload script is still injected: the header change did not
// disturb the html rewrite that shares the same branch
assert.match(index.body.toString(), /EventSource\("\/livereload"\)/);

const css = await request(port, '/style.css');
assert.equal(css.status, 200);
assertUncacheable('style.css', css.headers);

const wasm = await request(port, '/app.wasm');
assert.equal(wasm.status, 200);
assertUncacheable('app.wasm', wasm.headers);
assert.equal(wasm.headers['content-type'], 'application/wasm');
assert.equal(wasm.body.length, 8);

// ---- error responses are uncacheable too ----
// a 404 that sticks in the cache outlives the file that fixes it
const missing = await request(port, '/nope.js');
assert.equal(missing.status, 404);
assertUncacheable('404', missing.headers);

const escape = await request(port, '/../../etc/hosts');
assert.equal(escape.status, 403);
assertUncacheable('403', escape.headers);

const bad = await request(port, '/%zz');
assert.equal(bad.status, 400);
assertUncacheable('400', bad.headers);

// ---- the SSE channel still works ----
const sse = await openSse(port);
assertUncacheable('/livereload', sse.headers);
assert.equal(sse.headers['content-type'], 'text/event-stream');
assert.equal(sse.headers.connection, 'keep-alive');
assert.match(sse.greeting, /retry: 500/);
assert.match(sse.greeting, /data: build \d+/);

// ---- shutdown leaves nothing behind ----
// The recursive watcher is closed with the server; were it not, the
// event loop would stay alive and `goeteia dev` could never exit.
// libuv releases a handle on a later turn, so poll rather than read
// once -- a leak still never drains, which is what this catches.
sse.req.destroy();
await new Promise(r => server.close(r));
const leaked = ['FSEventWrap', 'TCPServerWrap'];
let live = [];
for (let i = 0; i < 100; i++) {
    live = process.getActiveResourcesInfo();
    if (!leaked.some(h => live.includes(h))) break;
    await new Promise(r => setTimeout(r, 20));
}
assert.deepEqual(leaked.filter(h => live.includes(h)), [],
                 `handles outlived the server: ${live.join(', ')}`);

clearTimeout(watchdog);
console.log = chatter;
fs.rmSync(ROOT, { recursive: true, force: true });
