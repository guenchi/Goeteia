;; A STATEFUL WebGL mock, for tests that judge what a draw READS when
;; the real replayer has run the command stream -- not which calls the
;; stream made.
;;
;; It lives here, in one file, because the cells about cached GPU state
;; (R40: test/cmd-stamp-*.ss, test/cached-gpu-state-*.ss,
;; test/fx-uniform-dedup-within-a-stream.ss, and the no-half-command
;; cell test/gl-full-region-leaves-whole-commands.ss) all ask the same
;; questions of the same GL, and a copied instrument is two instruments
;; that drift.
;;
;; What it keeps, and why each part is there:
;;
;;   THE CURRENT PROGRAM AND ITS UNIFORMS.  A uniform call whose
;;     location was not obtained from the program currently in use is
;;     REJECTED and changes nothing -- the WebGL rule.  Without it a
;;     set made while another program is current would read as made,
;;     and a cache that remembers such a set could not be caught.
;;     Values are stored per program and survive across replays, as
;;     GL's do.
;;
;;   VAOS AS OBJECTS.  Attribute setup and the element-array binding
;;     are recorded on the vertex array bound when they are made (null
;;     is a default VAO), so a VAO bound without its setup reads as
;;     having none.
;;
;;   BUFFER CONTENTS.  bufferData hashes the bytes it is given (FNV-1a)
;;     and counts the upload, on the bound ARRAY_BUFFER, on the bound
;;     VAO's element buffer, or on the bound UNIFORM_BUFFER.  A draw
;;     can then be compared with another draw by what its buffers HOLD,
;;     in a run whose objects have other names.
;;
;;   WHAT A DRAW READS.  Each draw records one line: its kind, count
;;     and instance count; every uniform value the current program
;;     holds; every enabled attribute with a buffer (location, size,
;;     stride, offset, divisor, and the buffer's length and hash); and
;;     the element buffer's length and hash.  No object names are in
;;     the line, so two runs can be compared line for line.
;;
;;   EVERY CALL.  Each call is logged with its arguments (objects by
;;     name, typed arrays by length and hash), so a test can compare
;;     two replays of the same words call for call.
;;
;; A failure can be injected: the next bufferData throws, once.  A
;; replay that raises is observed through a JS caller (glstate-attempt):
;; a host exception does not reach a Scheme handler.
(library (glstate)
  (export glstate-canvas glstate-reset! glstate-draws glstate-draw-values
          glstate-uploads glstate-uniform-log glstate-pointers glstate-vaos
          glstate-calls glstate-fail-next-upload! glstate-attempt
          glstate-rejected glstate-last-upload)
  (import (rnrs) (web js))

  (define $src "globalThis.__glstate = (() => {
  const st = { calls: [], draws: [], ulog: [], uploads: [], rejected: 0, pointers: 0, vaos: 0, fail: 0, vp: [0, 0, 64, 64] };
  const fnv = (b) => { let h = 0x811c9dc5; for (let i = 0; i < b.length; i++) { h ^= b[i]; h = Math.imul(h, 0x01000193) >>> 0; } return h.toString(16); };
  const bytes = (v) => new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
  const show = (a) => {
    if (a === null) return 'null';
    if (a === undefined) return 'undef';
    if (typeof a === 'number') return String(Math.round(a * 1000) / 1000);
    if (typeof a === 'string') return a;
    if (typeof a === 'boolean') return a ? 'T' : 'F';
    if (ArrayBuffer.isView(a)) return 'bytes' + a.byteLength + '#' + fnv(bytes(a));
    if (Array.isArray(a)) return '[' + a.map(show).join(',') + ']';
    if (a && a.tag) return a.tag;
    return 'obj'; };
  st.attempt = (fn) => { try { fn(); return 'ok'; } catch (e) { return 'raised:' + (e && e.name); } };
  st.reset = () => { st.calls = []; st.draws = []; st.ulog = []; st.uploads = []; st.rejected = 0; st.pointers = 0; };
  st.values = (name) => st.draws.map(d => d.vals[name] === undefined ? undefined : d.vals[name][0]);
  st.make = (w, h) => {
    let ctx = null;
    return { width: w, height: h, addEventListener() {}, getContext() {
      if (ctx) return ctx;
      st.vp = [0, 0, w, h];
      const dflt = { tag: 'VAO0', attrs: {}, ebo: null };
      let cur = null, vao = dflt, ab = null, ub = null, np = 0, nv = 0, nb = 0, nt = 0;
      const vals = new Map();
      const uset = (loc, kind, arr) => {
        st.ulog.push(kind + ':' + (loc ? loc.n : 'null') + ':' + arr.map(show).join(','));
        if (!loc || loc.p !== cur) { st.rejected++; return; }
        let m = vals.get(cur); if (!m) { m = {}; vals.set(cur, m); }
        m[loc.n] = Array.from(arr, Number); };
      const upload = (t, data) => {
        if (st.fail > 0) { st.fail--; throw new Error('mock bufferData failure'); }
        const b = t === 'AB' ? ab : t === 'EAB' ? vao.ebo : t === 'UB' ? ub : null;
        if (!b) return;
        if (typeof data === 'number') { b.len = data; b.h = 'zero'; }
        else { b.len = data.byteLength; b.h = fnv(bytes(data)); }
        b.n++;
        st.uploads.push(t + ':' + b.len + ':' + b.h); };
      const draw = (kind, count, n) => {
        const m = (cur && vals.get(cur)) || {};
        const us = Object.keys(m).sort().map(k => k + '=' + m[k].map(show).join(',')).join(';');
        const as = Object.keys(vao.attrs).map(Number).sort((a, b) => a - b)
          .filter(l => vao.attrs[l].on && vao.attrs[l].buf)
          .map(l => { const a = vao.attrs[l];
            return l + '/' + a.size + '/' + a.stride + '/' + a.off + '/' + (a.div || 0) + '/' + a.buf.len + '/' + a.buf.h; }).join(' ');
        const e = kind === 'A' ? '-' : (vao.ebo ? vao.ebo.len + '/' + vao.ebo.h : 'none');
        st.draws.push({ vals: Object.assign({}, m), text: kind + ' ' + show(count) + ' ' + show(n) + ' | ' + us + ' | ' + as + ' | ' + e }); };
      const base = {
        VERTEX_SHADER: 'VS', FRAGMENT_SHADER: 'FS', COMPILE_STATUS: 'CS', LINK_STATUS: 'LS',
        ARRAY_BUFFER: 'AB', ELEMENT_ARRAY_BUFFER: 'EAB', UNIFORM_BUFFER: 'UB', VIEWPORT: 'VP',
        createShader() { return { tag: 'S' }; }, getShaderParameter() { return true; },
        createProgram() { return { tag: 'P' + (++np) }; }, getProgramParameter() { return true; },
        getUniformLocation(p, n) { return { tag: 'L:' + n, p, n }; }, getUniformBlockIndex() { return 0; },
        createVertexArray() { st.vaos++; return { tag: 'VAO' + (++nv), attrs: {}, ebo: null }; },
        bindVertexArray(v) { vao = v || dflt; },
        createBuffer() { return { tag: 'B' + (++nb), len: 0, h: 'none', n: 0 }; },
        createTexture() { return { tag: 'T' + (++nt) }; },
        bindBuffer(t, b) { if (t === 'AB') ab = b; else if (t === 'EAB') vao.ebo = b; else if (t === 'UB') ub = b; },
        bufferData(t, data) { upload(t, data); },
        enableVertexAttribArray(l) { (vao.attrs[l] = vao.attrs[l] || {}).on = true; },
        vertexAttribPointer(l, size, type, norm, stride, off) {
          const a = (vao.attrs[l] = vao.attrs[l] || {});
          a.buf = ab; a.size = size; a.stride = stride; a.off = off; st.pointers++; },
        vertexAttribDivisor(l, d) { (vao.attrs[l] = vao.attrs[l] || {}).div = d; },
        useProgram(p) { cur = p; },
        uniform1f(l, x) { uset(l, '1f', [x]); }, uniform2f(l, x, y) { uset(l, '2f', [x, y]); },
        uniform3f(l, x, y, z) { uset(l, '3f', [x, y, z]); }, uniform4f(l, x, y, z, w) { uset(l, '4f', [x, y, z, w]); },
        uniform1i(l, v) { uset(l, '1i', [v]); }, uniformMatrix4fv(l, t, m) { uset(l, 'm4', m); },
        viewport(x, y, w, h) { st.vp = [x, y, w, h].map(Number); },
        getParameter(k) { return k === 'VP' ? st.vp.slice() : null; },
        drawArrays(m, f, c) { draw('A', c, 0); }, drawElements(m, c) { draw('E', c, 0); },
        drawElementsInstanced(m, c, t, o, n) { draw('I', c, n); } };
      ctx = new Proxy(base, { get(t, k) {
        if (typeof k !== 'string') return t[k];
        if (k in t && typeof t[k] !== 'function') return t[k];
        if (/^[A-Z0-9_]+$/.test(k)) return k;
        const f = t[k];
        return (...a) => { st.calls.push(k + '(' + a.map(show).join(',') + ')'); return f ? f.apply(t, a) : undefined; }; } });
      return ctx; } }; };
  return st; })();")

  (define $st (begin (js-eval $src) (js-get (js-global) "__glstate")))

  (define ($list arr conv)
    (let ((n (js->number (js-get arr "length"))))
      (let loop ((i (- n 1)) (out '()))
        (if (< i 0) out (loop (- i 1) (cons (conv (js-index arr i)) out))))))
  (define ($str-or-false v) (if (js-eq? v (js-undefined)) #f (js->string v)))
  (define ($num-or-false v) (if (js-eq? v (js-undefined)) #f (js->number v)))

  ;; a canvas whose context is the mock; its viewport starts at (0 0 w h)
  (define (glstate-canvas w h) (js-call (js-get $st "make") $st w h))
  ;; forget what was logged (calls, draws, uploads, uniform sets and
  ;; rejections, pointer count); GL state and objects are kept
  (define (glstate-reset!) (js-call (js-get $st "reset") $st))
  ;; one line per draw since the last reset: what it read
  (define (glstate-draws)
    ($list (js-get $st "draws") (lambda (d) (js->string (js-get d "text")))))
  ;; per draw since the last reset: the first component of the named
  ;; uniform as the draw read it, or #f where the program holds none
  (define (glstate-draw-values name)
    ($list (js-call (js-get $st "values") $st (symbol->string name)) $num-or-false))
  ;; vertex and index uploads since the last reset, "AB:len:hash" or
  ;; "EAB:len:hash" (uniform-buffer allocations are left out)
  (define (glstate-uploads)
    (filter (lambda (s) (not (char=? (string-ref s 0) #\U)))
            ($list (js-get $st "uploads") js->string)))
  ;; the last upload of any kind, or #f
  (define (glstate-last-upload)
    (let ((u ($list (js-get $st "uploads") js->string)))
      (if (null? u) #f (list-ref u (- (length u) 1)))))
  ;; every uniform call since the last reset, accepted or not:
  ;; "1f:u_k:480", "2f:u_res:640,480", ...
  (define (glstate-uniform-log) ($list (js-get $st "ulog") js->string))
  (define (glstate-rejected) (js->number (js-get $st "rejected")))
  ;; vertexAttribPointer calls since the last reset
  (define (glstate-pointers) (js->number (js-get $st "pointers")))
  ;; vertex arrays created, ever
  (define (glstate-vaos) (js->number (js-get $st "vaos")))
  ;; every GL call since the last reset, with its arguments
  (define (glstate-calls) ($list (js-get $st "calls") js->string))
  (define (glstate-fail-next-upload!) (js-set! $st "fail" 1))
  ;; run thunk under a JS try: "ok", or "raised:<error name>"
  (define (glstate-attempt thunk)
    (js->string (js-call (js-get $st "attempt") $st thunk))))
