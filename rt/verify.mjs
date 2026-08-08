// verify.mjs -- one .ss in, a structured verdict out.
//
//   goeteia verify <file.ss> [options]
//   node rt/verify.mjs <file.ss> [options]
//
// The pipeline is four stages, each a gate on the next:
//
//   compile   the self-hosted compiler turns the source into wasm.
//             Diagnostics are parsed into {file,line,col,hint,excerpt}
//             rather than dumped: the compiler already reports a real
//             file:line:column and appends advisory clauses, so the
//             caller gets fields, not a wall of text.
//   smoke     the module instantiates and runs against a mock DOM and
//             a RECORDING mock WebGL, and survives a few frames.
//   draw      (only when the spec asks) the frames actually issue
//             draw calls.
//   interact  (only when the spec asks) synthesizing user input
//             CHANGES what the next frames do.  This is decided
//             differentially: two runs with identical frame timing,
//             one with the input, one without.  A program whose
//             picture merely animates is not interactive, and a
//             same-vs-same comparison would call it one.
//   custom    per-page assertions from the check spec (see CUSTOM).
//
// Nothing about the mock world depends on the page under test: what a
// page needs is declared by its check spec, which is data, and every
// check kind is a separate entry in one table -- a new kind is a new
// entry, not an edit to the pipeline.  The spec format is documented
// in docs/verify.md.
//
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));

// The package root: rt/ always sits directly under it, so neither the
// caller's cwd nor a symlinked bin/ can move where the compiler, the
// bundled lib/ and the loader sources are found.
export const ROOT = path.resolve(HERE, '..');

// ---------------------------------------------------------------- //
// 1. compile
// ---------------------------------------------------------------- //

// "at /path/to/file.ss:12 (fn-name)" -- the loc context the compiler
// prints from $with-loc before re-raising
const RE_AT = /^at (.+?):(\d+)(?: \((.*)\))?\s*$/;
// "unhandled exception: who: message"
const RE_EXN = /^unhandled exception:\s*(.*)$/;
// the reader's own position, which carries a column:
// "list opened at FILE line 2 column 1 never closed"
const RE_READER = /\bat (.+?) line (\d+) column (\d+)/;
// how many arguments the format string wants
const RE_FMT = /~[sad]/g;

// An argument may be a whole expanded s-expression; keep the message
// a message
const clip = (s, n = 160) =>
    String(s).length > n ? String(s).slice(0, n) + ' …' : String(s);

function excerptOf(file, line, col) {
    if (!file || !line) return null;
    let text;
    try { text = fs.readFileSync(file, 'utf8'); } catch { return null; }
    const lines = text.split('\n');
    const src = lines[line - 1];
    if (src === undefined) return null;
    const shown = src.length > 200 ? src.slice(0, 200) + '...' : src;
    if (!col || col < 1) return `${line} | ${shown}`;
    // the reader's column counts bytes consumed, so it is 1-based on
    // the byte that ended the datum
    const pad = ' '.repeat(String(line).length) + ' | '
        + shown.slice(0, col - 1).replace(/[^\t]/g, ' ');
    return `${line} | ${shown}\n${pad}^`;
}

// Split "unbound variable ~s; exponent literals ... out 1e10" into a
// message with its arguments substituted and the advisory clause on
// its own.  errorf prints the format string verbatim and appends the
// arguments, so the trailing tokens belong to the ~s holes.
export function parseDiagnostic(output, sourceFile) {
    const lines = String(output || '').split('\n');
    const at = lines.map(l => l.match(RE_AT)).find(Boolean);
    const exn = lines.map(l => l.match(RE_EXN)).find(Boolean);
    const failed = lines.find(l => /^compile failed:/.test(l));

    let file = at ? at[1] : null;
    let line = at ? Number(at[2]) : null;
    let col = null;
    let hint = null;
    let message = exn ? exn[1] : (failed || 'compile failed').trim();

    // who: body
    let who = null;
    const wm = message.match(/^([a-z0-9$%!?*<>=+-]+):\s+([\s\S]*)$/i);
    if (wm) { who = wm[1]; message = wm[2]; }

    // the advisory clause, if the compiler appended one
    const semi = message.indexOf('; ');
    let tail = message;
    if (semi >= 0) { hint = message.slice(semi + 2); tail = message.slice(0, semi); }

    // errorf prints the format string verbatim and appends the
    // arguments, so the trailing tokens fill the ~s holes.  When a
    // hint clause followed, the arguments landed after IT.
    let args = [];
    const holes = tail.match(RE_FMT);
    if (holes) {
        if (hint !== null) {
            // the hint clause came between the format string and the
            // arguments, so the arguments are the hint's last tokens
            const toks = hint.trim().split(/\s+/);
            if (toks.length > holes.length) {
                args = toks.slice(toks.length - holes.length);
                hint = toks.slice(0, toks.length - holes.length).join(' ');
            }
        } else {
            // Everything after the LAST placeholder is the argument
            // text.  Splitting the whole message on whitespace would
            // tear an s-expression argument apart -- and those are
            // exactly the arguments the interesting errors carry.
            const last = tail.lastIndexOf(holes[holes.length - 1]);
            const argText = tail.slice(last + 2).trim();
            const cut = tail.slice(0, last + 2);
            if (argText) {
                args = holes.length === 1 ? [argText] : argText.split(/\s+/);
                if (args.length === holes.length) tail = cut;
                else args = [];
            }
        }
        if (args.length === holes.length) {
            let i = 0;
            tail = tail.replace(RE_FMT, () => clip(args[i++]));
        }
    }
    message = tail;
    if (who && who !== 'goeteia') message = `${who}: ${message}`;

    // a reader diagnostic names its own file/line/column, and it is
    // the precise one: the loc context only knows which form was
    // being read
    const rd = (hint || '') + ' ' + message;
    const rm = rd.match(RE_READER);
    let located = at ? 'form' : null;
    if (rm) {
        file = rm[1]; line = Number(rm[2]); col = Number(rm[3]);
        located = 'exact';
    }
    if (!file && sourceFile) file = sourceFile;

    // Several compiler errors ("cannot call ~s", "unbound variable
    // ~s") name the offending identifier but no position, because
    // the loc context only covers definitions.  Point at the first
    // place that identifier occurs and SAY it is a guess -- a wrong
    // guess the caller can see is worth more than no line at all.
    if (!line && args.length && file) {
        const hit = findIdent(file, args[args.length - 1]);
        if (hit) { line = hit.line; col = hit.col; located = 'guess'; }
    }

    return {
        stage: 'compile', message: message.trim(),
        file, line, col, located,
        hint: hint ? hint.trim() : null,
        excerpt: excerptOf(file, line, col),
        fn: at && at[3] ? at[3] : null,
    };
}

// Where in the source that argument most likely came from.  Three
// tries, most specific first: the whole form verbatim, the form's
// head symbol, a bare identifier as a whole word.  Comment lines are
// skipped -- a name usually appears in the prose above the code that
// uses it.
function findIdent(file, ident) {
    let text;
    try { text = fs.readFileSync(file, 'utf8'); } catch { return null; }
    const lines = text.split('\n').map(l => /^\s*;/.test(l) ? '' : l);
    const plain = s => {
        for (let i = 0; i < lines.length; i++) {
            const k = lines[i].indexOf(s);
            if (k >= 0) return { line: i + 1, col: k + 1 };
        }
        return null;
    };
    const arg = String(ident).trim();
    if (arg.startsWith('(')) {
        const whole = plain(arg);
        if (whole) return whole;
        const head = arg.slice(1).match(/^[^\s()]+/);
        return head ? plain('(' + head[0]) : null;
    }
    if (!/^[^\s()"']+$/.test(arg)) return null;
    for (let i = 0; i < lines.length; i++) {
        let from = 0;
        for (;;) {
            const k = lines[i].indexOf(arg, from);
            if (k < 0) break;
            const before = k === 0 ? '(' : lines[i][k - 1];
            const after = lines[i][k + arg.length] ?? ')';
            if (/[\s()'`,]/.test(before) && /[\s()'`,]/.test(after))
                return { line: i + 1, col: k + 1 };
            from = k + 1;
        }
    }
    return null;
}

function run(cmd, args, opts) {
    return new Promise(resolve => {
        const p = spawn(cmd, args, { ...opts, stdio: ['ignore', 'pipe', 'pipe'] });
        let out = '', err = '';
        p.stdout.on('data', d => { out += d; });
        p.stderr.on('data', d => { err += d; });
        p.on('error', e => resolve({ code: -1, out, err: err + e.message }));
        p.on('close', code => resolve({ code, out, err }));
    });
}

// Compile with the bundled self-hosted compiler, in a child process:
// the module under test is about to be instantiated in a mock world
// that replaces globals, and the compiler must not be running in it.
export async function compile(sourceFile, { script = false, outFile = null } = {}) {
    const src = path.resolve(sourceFile);
    // no outFile: the caller wants the bytes, not a file.  Compile
    // into a throwaway directory and take it back down, so a run over
    // many sources does not leave a copy of every module behind.
    const tmpDir = outFile ? null
        : fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-verify-'));
    const out = outFile || path.join(tmpDir, 'out.wasm');
    const drop = () => {
        if (tmpDir) try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch {}
    };
    const t0 = Date.now();
    const r = await run(process.execPath, [
        path.join(ROOT, 'rt/compile.mjs'),
        ...(script ? ['--script'] : []),
        src, out,
    ], { cwd: ROOT });
    const ms = Date.now() - t0;
    if (r.code !== 0 || !fs.existsSync(out)) {
        drop();
        return { ok: false, ms, errors: [parseDiagnostic(r.out + '\n' + r.err, src)] };
    }
    const wasm = fs.readFileSync(out);
    drop();
    return { ok: true, ms, wasmFile: outFile || null, wasm };
}

// ---------------------------------------------------------------- //
// 2. the mock browser
// ---------------------------------------------------------------- //
// Deliberately wider than any one page needs (a check spec decides
// what is looked at, not what exists): a page may build DOM, paint
// through WebGL, listen for input, or all three.

const TEXT_NODE = 3;

function stripTags(html) {
    return String(html).replace(/<[^>]*>/g, ' ');
}
function tagsIn(html) {
    const out = [];
    const re = /<\s*([a-zA-Z][a-zA-Z0-9-]*)\b/g;
    let m;
    while ((m = re.exec(String(html)))) out.push(m[1].toLowerCase());
    return out;
}

export function makeWorld({ width = 800, height = 600 } = {}) {
    const gl = [];                 // every recorded GL call, in order
    const nodes = [];              // every element ever created
    const listeners = [];          // {el, type, fn}
    const byId = new Map();
    const console_ = [];
    let seq = 0;
    let rafs = [];
    let timers = [];
    let now = 0;
    let rand = 0x2545f491;         // a seeded PRNG: two runs must agree

    const nextRand = () => {
        rand ^= rand << 13; rand >>>= 0;
        rand ^= rand >>> 17;
        rand ^= rand << 5; rand >>>= 0;
        return rand / 4294967296;
    };

    // ---- recording WebGL ------------------------------------------
    const rec = (op, extra) => { gl.push({ op, ...extra }); };
    function makeGL() {
        const base = {
            getExtension: () => null,
            getParameter: () => 0,
            createShader: () => ({ kind: 'shader', id: ++seq }),
            shaderSource(s, src) { rec('shaderSource', { len: String(src).length }); },
            compileShader() {},
            getShaderParameter: () => true,
            getShaderInfoLog: () => '',
            createProgram: () => ({ kind: 'program', id: ++seq }),
            attachShader() {}, linkProgram() {},
            getProgramParameter: () => true,
            getProgramInfoLog: () => '',
            bindAttribLocation(p, i, n) { rec('attribLoc', { i, n }); },
            getUniformLocation: (p, n) => ({ kind: 'uniform', n }),
            getUniformBlockIndex: () => 0,
            uniformBlockBinding() {},
            createBuffer: () => ({ kind: 'buffer', id: ++seq }),
            createTexture: () => ({ kind: 'texture', id: ++seq }),
            createFramebuffer: () => ({ kind: 'fb', id: ++seq }),
            createRenderbuffer: () => ({ kind: 'rb', id: ++seq }),
            createVertexArray: () => ({ kind: 'vao', id: ++seq }),
            createQuery: () => ({ kind: 'query', id: ++seq }),
            createTransformFeedback: () => ({ kind: 'tf', id: ++seq }),
            checkFramebufferStatus: () => 'FRAMEBUFFER_COMPLETE',
            bindVertexArray() {}, bindFramebuffer() {}, bindRenderbuffer() {},
            renderbufferStorage() {}, framebufferTexture2D() {},
            framebufferRenderbuffer() {}, drawBuffers() {},
            texParameteri() {}, generateMipmap() {},
            activeTexture() {}, bindTexture() {},
            texImage2D(...a) { rec('texImage2D', { n: a.length }); },
            texSubImage2D() {}, texStorage2D() {}, compressedTexImage2D() {},
            pixelStorei() {}, readPixels() {},
            bindBuffer(t, b) { rec('bindBuffer', { t, b: b && b.id }); },
            bufferData(t, d) {
                rec('bufferData', {
                    t, bytes: (d && d.byteLength !== undefined) ? d.byteLength : Number(d) | 0,
                });
            },
            bufferSubData() {}, bindBufferBase() {},
            enableVertexAttribArray() {},
            vertexAttribPointer(loc, n, ty, norm, stride, off) {
                rec('attrib', { loc, n, stride, off });
            },
            vertexAttribDivisor() {},
            useProgram(p) { rec('useProgram', { p: p && p.id }); },
            uniform1f(l, a) { rec('uniform1f', { n: l && l.n, v: [a] }); },
            uniform1i(l, a) { rec('uniform1i', { n: l && l.n, v: [a] }); },
            uniform2f(l, a, b) { rec('uniform2f', { n: l && l.n, v: [a, b] }); },
            uniform3f(l, a, b, c) { rec('uniform3f', { n: l && l.n, v: [a, b, c] }); },
            uniform4f(l, a, b, c, d) { rec('uniform4f', { n: l && l.n, v: [a, b, c, d] }); },
            uniformMatrix4fv(l, tr, v) {
                rec('uniformMatrix4fv', { n: l && l.n, v: Array.from(v || []) });
            },
            drawElements(mode, count, ty, off) { rec('drawElements', { mode, count }); },
            drawElementsInstanced(mode, count, ty, off, inst) {
                rec('drawElementsInstanced', { mode, count, inst });
            },
            drawArrays(mode, first, count) { rec('drawArrays', { mode, count }); },
            drawArraysInstanced(mode, first, count, inst) {
                rec('drawArraysInstanced', { mode, count, inst });
            },
            clearColor(r, g, b, a) { rec('clearColor', { v: [r, g, b, a] }); },
            clear(mask) { rec('clear', { mask: String(mask) }); },
            enable(c) { rec('enable', { c: String(c) }); },
            disable(c) { rec('disable', { c: String(c) }); },
            depthMask() {}, depthFunc() {}, blendFunc() {}, blendFuncSeparate() {},
            cullFace() {}, frontFace() {}, colorMask() {}, scissor() {},
            viewport(x, y, w, h) { rec('viewport', { w, h }); },
            blitFramebuffer() {}, beginQuery() {}, endQuery() {},
            getQueryParameter: () => 0,
            beginTransformFeedback() {}, endTransformFeedback() {},
            bindTransformFeedback() {}, transformFeedbackVaryings() {},
            deleteBuffer() {}, deleteTexture() {}, deleteProgram() {},
            deleteShader() {}, deleteFramebuffer() {}, deleteRenderbuffer() {},
        };
        // Unknown members: an ALL-CAPS name is a GL enum (the recorder
        // only ever uses them as distinguishable constants), anything
        // else is a call we do not model -- return a fresh object so
        // "create"-shaped calls still hand back something usable.
        return new Proxy(base, {
            get(t, p) {
                if (p in t) return t[p];
                if (typeof p !== 'string') return undefined;
                if (/^[A-Z][A-Z0-9_]*$/.test(p)) return p;
                return () => ({});
            },
            has: () => true,
        });
    }

    // ---- DOM -------------------------------------------------------
    function makeEl(tag) {
        const lower = String(tag).toLowerCase();
        const el = {
            nodeType: 1,
            tagName: String(tag).toUpperCase(),
            localName: lower,
            children: [],
            attrs: {},
            listeners: {},
            style: new Proxy({}, { set(t, k, v) { t[k] = String(v); return true; } }),
            dataset: {},
            classList: {
                _s: new Set(),
                add(...c) { c.forEach(x => this._s.add(x)); },
                remove(...c) { c.forEach(x => this._s.delete(x)); },
                toggle(c) { this._s.has(c) ? this._s.delete(c) : this._s.add(c); },
                contains(c) { return this._s.has(c); },
            },
            _html: '',
            value: '',
            checked: false,
            width, height,
            clientWidth: width, clientHeight: height,
            offsetWidth: width, offsetHeight: height,
            getBoundingClientRect: () => ({
                x: 0, y: 0, left: 0, top: 0, right: width, bottom: height, width, height,
            }),
            setAttribute(n, v) {
                this.attrs[n] = String(v);
                if (n === 'id') byId.set(String(v), this);
                if (n === 'width' || n === 'height') this[n] = Number(v);
                if (n === 'value') this.value = String(v);
            },
            getAttribute(n) { return n in this.attrs ? this.attrs[n] : null; },
            hasAttribute(n) { return n in this.attrs; },
            removeAttribute(n) { delete this.attrs[n]; },
            appendChild(c) { this.children.push(c); c.parent = this; return c; },
            removeChild(c) {
                this.children = this.children.filter(k => k !== c);
                return c;
            },
            insertBefore(c, ref) {
                const i = this.children.indexOf(ref);
                this.children.splice(i < 0 ? this.children.length : i, 0, c);
                c.parent = this;
                return c;
            },
            replaceChild(nw, old) {
                const i = this.children.indexOf(old);
                if (i < 0) this.children.push(nw); else this.children[i] = nw;
                nw.parent = this;
                return old;
            },
            addEventListener(k, f) {
                (this.listeners[k] ||= []).push(f);
                listeners.push({ el: this, type: k, fn: f });
            },
            removeEventListener(k, f) {
                this.listeners[k] = (this.listeners[k] || []).filter(g => g !== f);
            },
            dispatchEvent(ev) {
                (this.listeners[ev.type] || []).forEach(f => f(ev));
                return true;
            },
            click() { this.dispatchEvent({ type: 'click', target: this }); },
            focus() {}, blur() {},
            querySelector: () => null,
            querySelectorAll: () => [],
            getContext(kind) { return this._gl ||= makeGL(); },
            transferControlToOffscreen() { return this; },
            toDataURL: () => 'data:,',
            requestPointerLock() {}, requestFullscreen() {},
            appendData() {},
        };
        Object.defineProperty(el, 'textContent', {
            get() { return textOf(this); },
            set(v) {
                this.children = [];
                this._html = '';
                if (String(v).length) this.appendChild(makeText(v));
            },
            enumerable: true, configurable: true,
        });
        Object.defineProperty(el, 'innerText', {
            get() { return textOf(this); },
            set(v) { this.textContent = v; },
            enumerable: true, configurable: true,
        });
        Object.defineProperty(el, 'innerHTML', {
            get() { return this._html || this.children.map(htmlOf).join(''); },
            set(v) { this.children = []; this._html = String(v); },
            enumerable: true, configurable: true,
        });
        nodes.push(el);
        return el;
    }
    function makeText(s) {
        return { nodeType: TEXT_NODE, tagName: '#text', data: String(s),
                 textContent: String(s), children: [] };
    }
    function textOf(el) {
        if (!el) return '';
        if (el.nodeType === TEXT_NODE) return el.data;
        const own = el._html ? stripTags(el._html) : '';
        return own + (el.children || []).map(textOf).join(' ');
    }
    function htmlOf(el) {
        if (!el) return '';
        if (el.nodeType === TEXT_NODE) return el.data;
        const inner = el._html || (el.children || []).map(htmlOf).join('');
        return `<${el.localName}>${inner}</${el.localName}>`;
    }

    const root = makeEl('body');
    const head = makeEl('head');
    // The harness page, and the ONLY thing a program may assume is
    // already on it: a <div id="app"> to build DOM into and a
    // <canvas id="c"> to draw on.  rt/pack.mjs emits exactly these
    // two, so a program that verifies here finds the same hosts in
    // the packaged single-file page.
    const app = makeEl('div');
    app.setAttribute('id', 'app');
    root.appendChild(app);
    const canvas = makeEl('canvas');
    canvas.setAttribute('id', 'c');
    canvas.setAttribute('width', String(width));
    canvas.setAttribute('height', String(height));
    root.appendChild(canvas);

    const saved = new Map();
    const setG = (k, v) => {
        if (!saved.has(k)) saved.set(k, [k in globalThis, globalThis[k]]);
        globalThis[k] = v;
    };

    const driven = new Set();

    const world = {
        gl, nodes, listeners, byId, console: console_, root, driven,
        get now() { return now; },
        // Which controls the harness is ABLE to drive.  Frozen before
        // the act and used by every snapshot, so the set is identical
        // in the run that got input and the run that did not: were it
        // computed per run, the omission itself would differ and
        // every page with a wired-up control would look interactive.
        freezeDrivable() {
            this._drivable = new Set(nodes.filter(
                n => /^(input|select|textarea)$/.test(n.localName)
                     && ['input', 'change', 'click']
                         .some(t => (n.listeners[t] || []).length)));
        },
        // Everything a viewer could tell apart: structure, attributes,
        // resolved inline style, class list, text.  Text alone would
        // miss "the square turns blue".  The `value` of a drivable
        // control is left out: that field is the harness's input, not
        // the program's output.
        domSnapshot() {
            const walk = n => {
                if (!n) return null;
                if (n.nodeType === TEXT_NODE) return n.data;
                const o = { t: n.localName, a: { ...n.attrs }, s: { ...n.style } };
                if (n._html) o.h = n._html;
                if (n.classList._s.size) o.cl = [...n.classList._s].sort();
                const skip = this._drivable ? this._drivable.has(n) : driven.has(n);
                if (!skip) {
                    if (n.value !== '') o.v = n.value;
                    if (n.checked) o.k = 1;
                }
                o.c = (n.children || []).map(walk);
                return o;
            };
            return walk(root);
        },
        // every element with at least one listener of these types
        inputs: () => nodes.filter(n => n.localName === 'input'
                                        || n.localName === 'select'
                                        || n.localName === 'textarea'),
        buttons: () => nodes.filter(n => n.localName === 'button'),
        text: () => textOf(root),
        // elements carrying text of their own (a direct text child or
        // an innerHTML block), which is what "a paragraph" means
        // regardless of the tag the author chose
        textBlocks() {
            const out = [];
            const walk = n => {
                if (!n || n.nodeType === TEXT_NODE) return;
                const own = n._html
                    ? stripTags(n._html)
                    : (n.children || []).filter(c => c.nodeType === TEXT_NODE)
                        .map(c => c.data).join('');
                if (own.trim().length) out.push({ tag: n.localName, text: own.trim() });
                (n.children || []).forEach(walk);
            };
            walk(root);
            return out;
        },
        tagCounts() {
            const c = Object.create(null);
            const bump = t => { c[t] = (c[t] || 0) + 1; };
            for (const n of nodes) {
                if (n.parent || n === root) bump(n.localName);
                if (n._html) tagsIn(n._html).forEach(bump);
            }
            return c;
        },
        install() {
            setG('document', {
                createElement: makeEl,
                createElementNS: (ns, t) => makeEl(t),
                createTextNode: makeText,
                createDocumentFragment: () => makeEl('#fragment'),
                getElementById: id => byId.get(id) || null,
                querySelector: sel => {
                    const m = String(sel).match(/^#(.+)$/);
                    if (m) return byId.get(m[1]) || null;
                    return nodes.find(n => n.localName === String(sel).toLowerCase()) || null;
                },
                querySelectorAll: sel =>
                    nodes.filter(n => n.localName === String(sel).toLowerCase()),
                body: root, head, documentElement: root,
                addEventListener: (k, f) => { listeners.push({ el: 'document', type: k, fn: f }); },
                removeEventListener: () => {},
                title: '',
                readyState: 'complete',
            });
            setG('requestAnimationFrame', cb => { rafs.push(cb); return rafs.length; });
            setG('cancelAnimationFrame', () => {});
            setG('setTimeout', (cb, ms) => { timers.push({ cb, at: now + (ms || 0) }); return timers.length; });
            setG('clearTimeout', () => {});
            setG('setInterval', () => 0);
            setG('clearInterval', () => {});
            setG('performance', { now: () => now });
            setG('devicePixelRatio', 1);
            setG('innerWidth', width);
            setG('innerHeight', height);
            setG('addEventListener', (k, f) => { listeners.push({ el: 'window', type: k, fn: f }); });
            setG('removeEventListener', () => {});
            setG('matchMedia', q => ({ matches: false, media: String(q),
                                       addEventListener() {}, addListener() {} }));
            setG('getComputedStyle', el => new Proxy({}, {
                get: (t, p) => (el && el.style && p in el.style) ? el.style[p] : '',
            }));
            setG('console', {
                log: (...a) => console_.push(a.map(String).join(' ')),
                warn: (...a) => console_.push(a.map(String).join(' ')),
                error: (...a) => console_.push(a.map(String).join(' ')),
            });
            setG('alert', s => console_.push(`alert: ${s}`));
            setG('location', { href: 'http://localhost/', search: '', hash: '' });
            setG('fetch', () => Promise.reject(new Error('no network in the mock world')));
            setG('Image', class { constructor() { this.width = 1; this.height = 1; } });
            // deterministic clocks: two scenarios must be comparable
            setG('Date', new Proxy(Date, {
                get: (t, p) => (p === 'now' ? () => 1700000000000 : Reflect.get(t, p)),
                construct: (t, a) => new t(...(a.length ? a : [1700000000000])),
            }));
            this._mathRandom = Math.random;
            Math.random = nextRand;
        },
        uninstall() {
            for (const [k, [had, v]] of saved)
                if (had) globalThis[k] = v; else delete globalThis[k];
            saved.clear();
            if (this._mathRandom) Math.random = this._mathRandom;
        },
        // one animation frame at a fixed 60 Hz step
        pump() {
            now += 1000 / 60;
            const due = timers.filter(t => t.at <= now);
            timers = timers.filter(t => t.at > now);
            due.forEach(t => { try { t.cb(); } catch { /* a timer's own fault */ } });
            const cbs = rafs;
            rafs = [];
            cbs.forEach(cb => cb(now));
        },
        // fire one event at every listener registered for `type` on el
        fire(el, type, ev) {
            const fns = el === 'window' || el === 'document'
                ? listeners.filter(l => l.el === el && l.type === type).map(l => l.fn)
                : (el.listeners[type] || []);
            let n = 0;
            for (const f of fns) { f({ type, target: el, ...ev }); n++; }
            return n;
        },
    };
    return world;
}

// ---------------------------------------------------------------- //
// 3. scenarios
// ---------------------------------------------------------------- //

const IO_STUB = {
    write_byte() {}, read_byte: () => -1, path_byte() {},
    open_read: () => -1, open_write: () => -1,
    fread: () => -1, fwrite() {}, fclose() {},
};

async function jsbridge() {
    return import(pathToFileURL(path.join(ROOT, 'rt/jsbridge.mjs')).href);
}

// Run the module once: warm frames, then `act`, then more frames.
// The trace is everything a check can look at, and it is a pure
// function of (bytes, act) -- the clocks and the PRNG are stubbed, so
// two scenarios differ only where the acts differ.
export async function scenario(bytes, {
    warmFrames = 3, postFrames = 3, act = null, width = 800, height = 600,
} = {}) {
    const { makeJsBridge, callMain } = await jsbridge();
    const w = makeWorld({ width, height });
    w.install();
    const stdout = [];
    let ex = null;
    const trace = { frames: [], preText: '', postText: '', tags: {}, console: [] };
    try {
        const io = { ...IO_STUB, write_byte: b => stdout.push(b) };
        const { instance } = await WebAssembly.instantiate(
            bytes, { io, js: makeJsBridge(() => ex) });
        ex = instance.exports;
        await callMain(ex);
        await new Promise(r => setImmediate(r));

        const frame = () => {
            const from = w.gl.length;
            w.pump();
            return w.gl.slice(from);
        };
        for (let i = 0; i < warmFrames; i++) trace.frames.push(frame());
        trace.preText = w.text();
        w.freezeDrivable();
        trace.preDom = w.domSnapshot();
        trace.actions = act ? act(w) : [];
        await new Promise(r => setImmediate(r));
        trace.warm = warmFrames;
        for (let i = 0; i < postFrames; i++) trace.frames.push(frame());
        trace.postText = w.text();
        trace.postDom = w.domSnapshot();
        trace.tags = w.tagCounts();
        trace.console = w.console.slice();
        trace.gl = w.gl;
        trace.world = w;
        trace.stdout = Buffer.from(stdout).toString('utf8');
        trace.ok = true;
    } catch (e) {
        trace.ok = false;
        trace.error = e;
        trace.gl = w.gl;
        trace.world = w;
        trace.stdout = Buffer.from(stdout).toString('utf8');
    } finally {
        w.uninstall();
    }
    return trace;
}

// The comparable part of a trace, in three projections.  Two
// scenarios that differ under a projection differ in what the user
// would have seen through it.
//   page  -- everything: the frames issued AFTER the act plus the DOM
//   draws -- only the frames: "did the picture change"
//   text  -- only the readable text
export const PROJECT = {
    page: t => JSON.stringify({ frames: t.frames.slice(t.warm ?? 0), dom: t.postDom }),
    draws: t => JSON.stringify(t.frames.slice(t.warm ?? 0)),
    text: t => String(t.postText),
};
export const signature = PROJECT.page;

const DRAW_OPS = new Set(['drawElements', 'drawElementsInstanced',
                          'drawArrays', 'drawArraysInstanced']);
export function drawStats(trace) {
    const gl = trace.gl || [];
    const draws = gl.filter(e => DRAW_OPS.has(e.op) && (e.count | 0) > 0);
    return {
        draws: draws.length,
        draw_elements: draws.filter(e => e.op.startsWith('drawElements')).length,
        draw_arrays: draws.filter(e => e.op.startsWith('drawArrays')).length,
        vertices: draws.reduce((n, e) => n + (e.count | 0), 0),
        gl_ops: gl.length,
    };
}

// ---- the acts ---------------------------------------------------- //
// An act reports what it did, so a check can say the input it needed
// was not there at all rather than "nothing changed".

// A value the control is not already at: half a range away, clamped.
function otherValue(el) {
    const num = (v, d) => (v === undefined || v === null || v === '' || isNaN(Number(v))
        ? d : Number(v));
    const min = num(el.attrs.min, 0);
    const max = num(el.attrs.max, 100);
    const cur = num(el.value !== '' ? el.value : el.attrs.value, min);
    const lo = Math.min(min, max), hi = Math.max(min, max);
    const pick = (cur - lo) < (hi - lo) / 2 ? hi : lo;
    return String(pick === cur ? (lo + hi) / 2 : pick);
}

function driveControl(w, el) {
    const acts = [];
    for (const type of ['input', 'change']) {
        if (!(el.listeners[type] || []).length) continue;
        w.driven.add(el);
        el.value = otherValue(el);
        w.fire(el, type, { value: el.value });
        acts.push(`${el.localName}#${el.attrs.id || '?'} ${type}=${el.value}`);
    }
    if ((el.listeners.click || []).length) {
        w.fire(el, 'click', {});
        acts.push(`${el.localName}#${el.attrs.id || '?'} click`);
    }
    return acts;
}

// A drag across the middle of the canvas: down, three moves, up --
// on the canvas and, for programs that track the pointer on the
// window, there too.
function actPointerDrag(w) {
    const acts = [];
    const targets = [w.byId.get('c'), 'window', 'document'].filter(Boolean);
    const path = [[200, 300], [340, 280], [480, 260], [600, 240]];
    for (const t of targets) {
        const at = (x, y) => ({ offsetX: x, offsetY: y, clientX: x, clientY: y,
                                movementX: 60, movementY: -10, buttons: 1, button: 0 });
        let n = 0;
        n += w.fire(t, 'pointerdown', at(...path[0]));
        n += w.fire(t, 'mousedown', at(...path[0]));
        for (const [x, y] of path.slice(1)) {
            n += w.fire(t, 'pointermove', at(x, y));
            n += w.fire(t, 'mousemove', at(x, y));
        }
        n += w.fire(t, 'pointerup', at(...path[path.length - 1]));
        n += w.fire(t, 'mouseup', at(...path[path.length - 1]));
        if (n) acts.push(`drag on ${t === 'window' || t === 'document' ? t : 'canvas'}`
                         + ` reached ${n} listeners`);
    }
    return acts;
}

function actKeys(w) {
    const acts = [];
    for (const key of ['ArrowRight', 'ArrowUp', 'w', 'a', ' ']) {
        const n = w.fire('window', 'keydown', { key, code: key })
            + w.fire('document', 'keydown', { key, code: key });
        if (n) acts.push(`key ${key}`);
    }
    return acts;
}

// every control, every button, plus keyboard and pointer -- the whole
// vocabulary of "the user did something"
function actAll(w) {
    const acts = [];
    for (const el of w.inputs()) acts.push(...driveControl(w, el));
    for (const el of w.buttons()) {
        if ((el.listeners.click || []).length) {
            w.fire(el, 'click', {});
            acts.push(`button#${el.attrs.id || '?'} click`);
        }
    }
    for (const el of w.nodes) {
        if (el.localName === 'input' || el.localName === 'button') continue;
        for (const type of ['click', 'pointerdown', 'pointermove', 'change'])
            if ((el.listeners[type] || []).length) {
                w.fire(el, type, { offsetX: 400, offsetY: 300,
                                   clientX: 400, clientY: 300, buttons: 1 });
                acts.push(`${el.localName} ${type}`);
            }
    }
    acts.push(...actKeys(w));
    acts.push(...actPointerDrag(w));
    return acts;
}

function actNothing() { return []; }

function actInput(i) {
    return w => {
        const els = w.inputs();
        if (!els[i]) return [];
        return driveControl(w, els[i]);
    };
}

// ---------------------------------------------------------------- //
// 4. checks
// ---------------------------------------------------------------- //
// One entry per kind.  A handler gets (spec, ctx) and returns
// {ok, detail} or {manual, detail}.  ctx.run(key, act) memoizes a
// scenario so several checks can share one run.

const PROJ_NAME = {
    page: 'frame command stream and page state',
    draws: 'frame command stream',
    text: 'page text',
};

// The one judgement every interaction check is made of: does doing
// this change what the user sees, THROUGH this projection.  Decided
// differentially -- an animating picture changes by itself, and a
// same-vs-same comparison would call that interactivity.
async function differs(ctx, key, act, label, by = 'page') {
    const project = PROJECT[by];
    const base = await ctx.run('base', actNothing);
    const base2 = await ctx.run('base2', actNothing);
    if (project(base) !== project(base2))
        return { ok: false, nondet: true,
                 detail: `two identical runs with no input already disagree, so `
                         + `${label} cannot be judged (an unfrozen clock or random `
                         + `source sits on the render path)` };
    const with_ = await ctx.run(key, act);
    if (!with_.ok)
        return { ok: false,
                 detail: `${label}: the run threw once input was injected: `
                         + `${with_.error && with_.error.message}` };
    const acted = (with_.actions || []).length;
    if (!acted)
        return { ok: false,
                 detail: `${label}: nothing on the page has a listener registered, `
                         + `so the input has nowhere to go` };
    if (project(with_) === project(base))
        return { ok: false,
                 detail: `${label}: ${acted} input(s) synthesized `
                         + `(${with_.actions.join('; ')}), after which the `
                         + `${PROJ_NAME[by]} is byte for byte what it was with no input` };
    return { ok: true,
             detail: `${label}: after ${acted} synthesized input(s) `
                     + `(${with_.actions.join('; ')}), the ${PROJ_NAME[by]} changed` };
}

export const CUSTOM = {
    // -- static structure --
    dom_text_matches: (s, ctx) => {
        const re = new RegExp(s.pattern, s.flags || '');
        const t = ctx.base.postText;
        return { ok: re.test(t),
                 detail: `page text ${re.test(t) ? 'matches' : 'does not match'} /${s.pattern}/` };
    },
    dom_text_min_length: (s, ctx) => {
        const n = ctx.base.postText.replace(/\s+/g, ' ').trim().length;
        return { ok: n >= s.n, detail: `${n} characters of readable text (want >= ${s.n})` };
    },
    dom_text_count: (s, ctx) => {
        const re = new RegExp(s.pattern, (s.flags || '').includes('g')
            ? s.flags : (s.flags || '') + 'g');
        const n = (ctx.base.postText.match(re) || []).length;
        return { ok: n >= s.min,
                 detail: `/${s.pattern}/ occurs ${n} times in the page text (want >= ${s.min})` };
    },
    element_count: (s, ctx) => {
        const c = ctx.base.tags[s.tag] || 0;
        const ok = c >= (s.min ?? 0) && (s.max === undefined || c <= s.max);
        return { ok, detail: `${c} <${s.tag}> element(s) (want >= ${s.min ?? 0}`
                             + `${s.max !== undefined ? `, <= ${s.max}` : ''})` };
    },
    // How many separate blocks of text the page has, whatever tags the
    // author reached for.  "three paragraphs" must not become "three
    // <p> elements": <div>, <li> and <section> are all legitimate.
    text_blocks_min: (s, ctx) => {
        const n = ctx.base.world.textBlocks().length;
        return { ok: n >= s.n, detail: `${n} separate block(s) of text (want >= ${s.n})` };
    },
    console_matches: (s, ctx) => {
        const re = new RegExp(s.pattern, s.flags || '');
        const hit = ctx.base.console.some(l => re.test(l));
        return { ok: hit,
                 detail: `/${s.pattern}/ ${hit ? 'appears' : 'never appears'} in console output` };
    },

    // -- drawing --
    draws_min: (s, ctx) => {
        const d = drawStats(ctx.base).draws;
        return { ok: d >= s.n, detail: `${d} draw call(s) inside frames (want >= ${s.n})` };
    },
    gl_op_present: (s, ctx) => {
        const hit = (ctx.base.gl || []).some(e => e.op === s.op);
        return { ok: hit, detail: `GL call ${s.op} ${hit ? 'occurred' : 'never occurred'}` };
    },
    uniform_present: (s, ctx) => {
        const hit = (ctx.base.gl || []).some(e => /^uniform/.test(e.op) && e.n === s.name);
        return { ok: hit,
                 detail: `uniform "${s.name}" was ${hit ? 'set' : 'never set'}` };
    },

    // -- animation: the picture changes with no input at all --
    animates: (s, ctx) => {
        const f = ctx.base.frames.filter(x => x.length);
        if (f.length < 2)
            return { ok: false,
                     detail: `only ${f.length} frame(s) with content were recorded, `
                             + `so animation cannot be judged` };
        const a = JSON.stringify(f[f.length - 2]), b = JSON.stringify(f[f.length - 1]);
        return { ok: a !== b,
                 detail: a !== b ? 'consecutive frames issue different commands (the picture moves)'
                                 : 'consecutive frames issue identical commands (the picture is still)' };
    },
    uniform_varies_over_time: (s, ctx) => {
        const vals = ctx.base.frames.map(fr => {
            const u = fr.filter(e => /^uniform/.test(e.op) && e.n === s.name);
            return u.length ? JSON.stringify(u.map(e => e.v)) : null;
        }).filter(Boolean);
        if (vals.length < 2)
            return { ok: false,
                     detail: `uniform "${s.name}" is set in fewer than two frames, `
                             + `so it cannot be judged to vary` };
        const ok = new Set(vals).size > 1;
        return { ok, detail: `uniform "${s.name}" took ${new Set(vals).size} distinct `
                             + `value(s) across ${vals.length} frames` };
    },

    max_vertices_per_frame: (s, ctx) => {
        const frames = ctx.base.frames.filter(f => f.some(e => DRAW_OPS.has(e.op)));
        if (!frames.length) return { ok: false, detail: 'no frame issued a draw command' };
        const worst = Math.max(...frames.map(f => f.filter(e => DRAW_OPS.has(e.op))
            .reduce((n, e) => n + (e.count | 0), 0)));
        return { ok: worst <= s.n,
                 detail: `at most ${worst} vertices in one frame (want <= ${s.n}, `
                         + `i.e. the picture comes from a shader rather than geometry)` };
    },
    some_uniform_varies_over_time: (s, ctx) => {
        // any uniform at all whose value differs between frames: the
        // spec cannot dictate what the author names it
        const seen = new Map();
        ctx.base.frames.forEach((fr, i) => {
            for (const e of fr) {
                if (!/^uniform/.test(e.op)) continue;
                const k = `${e.op}:${e.n}`;
                (seen.get(k) || seen.set(k, new Set()).get(k)).add(JSON.stringify(e.v));
            }
        });
        const varying = [...seen.entries()].filter(([, v]) => v.size > 1).map(([k]) => k);
        return { ok: varying.length > 0,
                 detail: varying.length
                     ? `uniforms varying over time: ${varying.join(', ')}`
                     : `${seen.size} uniform(s) recorded, none of which took a `
                       + `different value between frames` };
    },

    // -- interaction --
    input_count_min: (s, ctx) => {
        const n = ctx.base.world.inputs().length;
        return { ok: n >= s.n, detail: `${n} input control(s) on the page (want >= ${s.n})` };
    },
    // `by` picks the projection: "page" (default), "draws", "text"
    input_changes: (s, ctx) =>
        differs(ctx, `input${s.index}`, actInput(s.index),
                `control ${s.index + 1}`, s.by || 'page'),
    pointer_changes: (s, ctx) =>
        differs(ctx, 'pointer', actPointerDrag, 'dragging on the canvas', s.by || 'page'),
    keys_change: (s, ctx) =>
        differs(ctx, 'keys', actKeys, 'pressing the arrow keys', s.by || 'page'),
    // Every listed control must move the page, AND no two of them the
    // same way: one slider wired to both joints would otherwise pass
    // the per-control test twice over.
    inputs_change_independently: async (s, ctx) => {
        const by = s.by || 'page';
        const sigs = [];
        for (const i of s.indices) {
            const r = await differs(ctx, `input${i}`, actInput(i),
                                    `control ${i + 1}`, by);
            if (!r.ok) return r;
            sigs.push(PROJECT[by](await ctx.run(`input${i}`, actInput(i))));
        }
        const uniq = new Set(sigs).size;
        return { ok: uniq === sigs.length,
                 detail: `${sigs.length} control(s) each changed the ${PROJ_NAME[by]}, `
                         + `producing ${uniq} distinct outcome(s)`
                         + (uniq === sigs.length ? ''
                            : ' (two controls had exactly the same effect -- they are '
                              + 'not each driving a degree of freedom)') };
    },

    manual: s => ({ manual: true, ok: null, detail: s.note || 'needs human judgement' }),
};

// ---------------------------------------------------------------- //
// 5. the pipeline
// ---------------------------------------------------------------- //

export const DEFAULT_CHECKS = { needs_draw: false, needs_interact: false, custom: [] };

// A wasm trap says four words and names no line.  These are the ones
// this toolchain actually produces, each with the Scheme-level cause;
// a new trap is a new row, not a change to the pipeline.
const TRAP_HINTS = [
    [/illegal cast/i,
     'a wasm type assertion failed.  The usual cause is a value that left the '
     + 'i31 fixnum range (|x| >= 2^30) and then entered a path that accepts only '
     + 'fixnums -- bitwise operators, %mem-* accessors, character and index '
     + 'conversions all do.  Keep large numbers on the flonum side, or use a '
     + 'lookup table; do not do 32-bit bitwise arithmetic on big integers'],
    [/array element access out of bounds|out of bounds/i,
     'a vector or string index went out of bounds.  Check whether the loop bound '
     + 'is the length or the last index'],
    [/null|dereferenc/i,
     'a null reference was dereferenced: most often get-element-by-id returned '
     + 'null (the page hosts only #app and #c), or an object that exists only in '
     + 'a real browser is absent from the mock world'],
    [/divide by zero|division/i, 'division by zero'],
    [/unreachable/i,
     'a wasm trap (out of bounds, a failed type assertion, division by zero, or '
     + 'the program calling error itself).  Whatever the program wrote to stdout '
     + 'is in the stdout field, and the Scheme-level error text is usually there'],
    [/memory access out of bounds/i,
     'linear memory out of bounds: a %mem-* write landed on an address fx-alloc! '
     + 'never handed out, or the allocation was sized too small'],
];
export function trapHint(msg) {
    const row = TRAP_HINTS.find(([re]) => re.test(msg));
    return row ? row[1] : null;
}

export async function verifyBytes(bytes, checks = DEFAULT_CHECKS, opts = {}) {
    const spec = { ...DEFAULT_CHECKS, ...checks };
    const errors = [];
    const results = [];
    const cache = new Map();
    const runs = { n: 0 };
    const ctx = {
        run: async (key, act) => {
            if (cache.has(key)) return cache.get(key);
            const p = scenario(bytes, { ...opts, act }).then(t => { runs.n++; return t; });
            cache.set(key, p);
            return p;
        },
    };

    const base = await ctx.run('base', actNothing);
    ctx.base = base;
    if (!base.ok) {
        const e = base.error;
        errors.push({
            stage: 'smoke',
            message: `the module threw as soon as it ran: ${e && e.message}`,
            file: null, line: null, col: null,
            hint: trapHint(String(e && e.message)),
            excerpt: base.stdout ? base.stdout.trim().split('\n').slice(-3).join('\n') : null,
        });
        return { ok: false, stage: 'smoke', errors, checks: results,
                 stats: { bytes: bytes.length, ...drawStats(base) }, stdout: base.stdout };
    }

    const stats = {
        bytes: bytes.length,
        frames: base.frames.length,
        ...drawStats(base),
        dom_text_len: base.postText.replace(/\s+/g, ' ').trim().length,
        elements: base.world.nodes.length,
        inputs: base.world.inputs().length,
        buttons: base.world.buttons().length,
    };

    let stage = 'done';

    if (spec.needs_draw) {
        const d = stats.draws;
        const ok = d > 0;
        results.push({ kind: 'needs_draw', ok, detail: `${d} draw call(s) inside frames` });
        if (!ok) {
            stage = 'draw';
            errors.push({
                stage: 'draw',
                message: `drawing was required, but ${base.frames.length} frames issued `
                         + `no drawElements/drawArrays at all`,
                file: null, line: null, col: null,
                hint: stats.gl_ops === 0
                    ? 'not one WebGL call happened: the program never did '
                      + '(fx-init! (get-element-by-id "c")), so this looks like a static '
                      + 'page rather than a rendering program'
                    : 'a context was obtained and resources were uploaded, but no frame '
                      + 'issued a draw command: check that the drawing happens inside the '
                      + 'fx-loop! callback, and that the vertex count is not zero',
                excerpt: null,
            });
        }
    }

    if (spec.needs_interact && stage === 'done') {
        const r = await differs(ctx, 'all', actAll, 'synthesized input', 'page');
        results.push({ kind: 'needs_interact', ...r });
        if (!r.ok) {
            stage = 'interact';
            errors.push({
                stage: 'interact', message: r.detail,
                file: null, line: null, col: null,
                hint: r.nondet
                    ? 'take Math.random / Date.now and friends off the render path, or no '
                      + 'judgement of "did the input do anything" can stand'
                    : 'interaction has to connect the input to rendering or to the DOM: read '
                      + "the event target's value, write it into a signal or a state variable, "
                      + 'and let that drive the next frame',
                excerpt: null,
            });
        }
    }

    for (const c of (spec.custom || [])) {
        const h = CUSTOM[c.kind];
        if (!h) {
            results.push({ kind: c.kind, ok: false, detail: `unknown check kind "${c.kind}"` });
            if (stage === 'done') stage = 'custom';
            errors.push({ stage: 'custom', message: `unknown check kind "${c.kind}"`,
                          file: null, line: null, col: null,
                          hint: `implemented kinds: ${Object.keys(CUSTOM).join(', ')}`,
                          excerpt: null });
            continue;
        }
        let r;
        try { r = await h(c, ctx); }
        catch (e) { r = { ok: false, detail: `the check itself threw: ${e.message}` }; }
        results.push({ kind: c.kind, spec: c, ...r });
        if (r.manual) continue;
        if (!r.ok) {
            if (stage === 'done') stage = 'custom';
            errors.push({ stage: 'custom', message: `${c.kind}: ${r.detail}`,
                          file: null, line: null, col: null,
                          hint: c.hint || null, excerpt: null });
        }
    }

    stats.scenarios = runs.n;
    const scored = results.filter(r => !r.manual);
    return {
        ok: stage === 'done',
        stage,
        errors,
        checks: results,
        stats,
        stdout: base.stdout,
        summary: `${scored.filter(r => r.ok).length}/${scored.length} checks passed`
                 + (results.length > scored.length
                    ? `, ${results.length - scored.length} need human judgement` : ''),
    };
}

export async function verifyFile(sourceFile, checks = DEFAULT_CHECKS, opts = {}) {
    const t0 = Date.now();
    const c = await compile(sourceFile, opts);
    if (!c.ok) {
        return {
            ok: false, stage: 'compile', errors: c.errors, checks: [],
            stats: { bytes: 0, compile_ms: c.ms, total_ms: Date.now() - t0 },
            summary: 'did not compile',
        };
    }
    const r = await verifyBytes(c.wasm, checks, opts);
    r.stats.compile_ms = c.ms;
    r.stats.total_ms = Date.now() - t0;
    r.wasmFile = c.wasmFile;
    return r;
}

// ---------------------------------------------------------------- //
// CLI
// ---------------------------------------------------------------- //

export const VERIFY_USAGE = `Usage: goeteia verify <file.ss> [options]
  --needs draw,interact  require the draw and/or interact stage
  --checks <file.json>   a check spec (a literal JSON object also works)
  --json                 print the verdict as JSON and nothing else
  --out <report.json>    also write the JSON verdict to a file
  --wasm <out.wasm>      keep the compiled module (default: discarded)
  --script               compile with -O0 (faster, for quick feedback)
Exit status: 0 passed, 1 failed, 2 bad usage.  See docs/verify.md.`;

// The spec may be given as a path or written out on the command line.
// Reading the wider of the two costs one existsSync.
export function readChecks(arg) {
    const text = fs.existsSync(arg) ? fs.readFileSync(arg, 'utf8') : String(arg);
    let spec;
    try { spec = JSON.parse(text); }
    catch (e) {
        throw new Error(`--checks is neither a readable JSON file nor a JSON object: ${e.message}`);
    }
    if (!spec || typeof spec !== 'object' || Array.isArray(spec))
        throw new Error('--checks must be a JSON object');
    return spec;
}

// "draw,interact" -> {needs_draw: true, needs_interact: true}
export function parseNeeds(arg) {
    const out = {};
    for (const raw of String(arg).split(/[,\s]+/)) {
        const name = raw.trim();
        if (!name) continue;
        if (name === 'draw') out.needs_draw = true;
        else if (name === 'interact') out.needs_interact = true;
        else throw new Error(`--needs takes "draw" and/or "interact", not "${name}"`);
    }
    return out;
}

function report(r, source) {
    const lines = [];
    const said = new Set();
    for (const c of r.checks || []) {
        if (c.manual) { lines.push(`  --   ${c.kind}: ${c.detail}`); continue; }
        lines.push(`  ${c.ok ? 'ok  ' : 'FAIL'} ${c.kind}: ${c.detail}`);
        said.add(c.detail);
        said.add(`${c.kind}: ${c.detail}`);
    }
    for (const e of r.errors || []) {
        // an error that only restates a check adds nothing but its hint
        if (said.has(e.message)) {
            if (e.hint) lines.push(`       hint: ${e.hint}`);
            continue;
        }
        const where = e.file
            ? `${e.file}${e.line ? ':' + e.line : ''}${e.col ? ':' + e.col : ''}: ` : '';
        lines.push(`  FAIL ${e.stage}: ${where}${e.message}`);
        if (e.excerpt) lines.push(e.excerpt.replace(/^/gm, '       '));
        if (e.hint) lines.push(`       hint: ${e.hint}`);
    }
    lines.push(r.ok ? `ok   ${source}: ${r.summary}`
                    : `FAIL ${source} (stage ${r.stage})`);
    return lines.join('\n');
}

export async function runVerify(argv) {
    const args = {};
    const pos = [];
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a === '--json' || a === '--script') args[a.slice(2)] = true;
        else if (a === '--help' || a === '-h') { console.log(VERIFY_USAGE); return 0; }
        else if (a.startsWith('--')) {
            // a value-taking flag left dangling is a typo, not a
            // request to run with nothing required
            const v = argv[++i];
            if (v === undefined) {
                console.error(`goeteia verify: ${a} needs a value\n${VERIFY_USAGE}`);
                return 2;
            }
            args[a.slice(2)] = v;
        }
        else pos.push(a);
    }
    if (!pos[0]) { console.error(VERIFY_USAGE); return 2; }

    let checks = { ...DEFAULT_CHECKS };
    try {
        if (args.checks) checks = { ...checks, ...readChecks(args.checks) };
        if (args.needs) checks = { ...checks, ...parseNeeds(args.needs) };
    } catch (e) { console.error(`goeteia verify: ${e.message}`); return 2; }

    const r = await verifyFile(pos[0], checks,
        { script: !!args.script,
          ...(args.wasm ? { outFile: path.resolve(args.wasm) } : {}) });
    r.source = path.resolve(pos[0]);
    const json = JSON.stringify(r, (k, v) =>
        (k === 'world' || k === 'spec' ? undefined : v), 2);
    if (args.out) fs.writeFileSync(args.out, json);
    if (args.json) console.log(json);
    else console.log(report(r, pos[0]));
    return r.ok ? 0 : 1;
}

if (process.argv[1] &&
    import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href)
    runVerify(process.argv.slice(2)).then(c => process.exit(c));
