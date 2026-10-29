;; expect: #t
;; fx-target-mrt-msaa!: what it allocates, what it refuses, and the calls
;; its resolve makes, read from a recording mock GL.
;;
;; THE SAMPLE COUNT is the largest count both the colour format (RGBA16F)
;; and DEPTH_COMPONENT24 report that does not exceed the request; every
;; attachment is allocated at it, and fx-target-samples answers it.  A
;; request no common count satisfies is refused, naming the formats, and
;; nothing is allocated.  RGBA16F rendering needs EXT_color_buffer_float or
;; EXT_color_buffer_half_float; with neither the call is refused.  A
;; framebuffer that is not complete after allocation is refused and every
;; object made for it is deleted.  n below 1 or above MAX_DRAW_BUFFERS, a
;; size not positive, and samples below 1 are refused before anything is
;; allocated.
;;
;; THE RESOLVE (fx-resolve!) is one command.  It binds the multisampled
;; framebuffer as READ and the resolve framebuffer as DRAW, and for each
;; attachment i: readBuffer(COLOR_ATTACHMENTi), drawBuffers with that
;; attachment at position i and NONE elsewhere, a COLOR blit (NEAREST); then
;; one DEPTH blit (NEAREST); then restores the resolve framebuffer's
;; drawBuffers to all attachments and the read framebuffer's readBuffer to
;; COLOR_ATTACHMENT0, and binds the canvas.  n = 1 resolves depth as well.
;; The single-colour multisampled target (fx-target-msaa!) still resolves
;; with one colour blit, as before.
;;
;; The mock answers every method it does not model with a no-op, so the rows
;; read only the calls named here.  Each framebuffer's completeness check can
;; be made to fail on its own, and the limits are set separately, so a check
;; that is missing for one of them shows.  ON THE TREE BEFORE THE CHANGE the cell
;; does not compile: fx-target-mrt-msaa! does not exist there.
(import (rnrs) (web js) (gfx gl) (gfx fx))

(js-eval "globalThis.__g1 = { log: [], lists: {}, ext: { float: true, half: true }, failCheck: 0, checks: 0, maxDraw: 4, maxAttach: 4, maxRb: 4096, maxTex: 4096 };
globalThis.__g1canvas = (() => {
  const S = globalThis.__g1; const push = (...a) => S.log.push(a.join(':'));
  let n = 0; const obj = k => ({ id: k + (++n) });
  const C = { RGBA16F: 'RGBA16F', DEPTH_COMPONENT24: 'D24', RENDERBUFFER: 'RB', SAMPLES: 'SAMPLES', FRAMEBUFFER: 'FB',
    READ_FRAMEBUFFER: 'READ', DRAW_FRAMEBUFFER: 'DRAW', COLOR_ATTACHMENT0: 0x8CE0, COLOR_ATTACHMENT1: 0x8CE1,
    COLOR_ATTACHMENT2: 0x8CE2, COLOR_ATTACHMENT3: 0x8CE3, DEPTH_ATTACHMENT: 'DA', NONE: 'NONE',
    COLOR_BUFFER_BIT: 'COLOR', DEPTH_BUFFER_BIT: 'DEPTH', NEAREST: 'NEAREST', LINEAR: 'LINEAR',
    FRAMEBUFFER_COMPLETE: 'COMPLETE', MAX_DRAW_BUFFERS: 'MAXDB', MAX_COLOR_ATTACHMENTS: 'MAXCA',
    MAX_RENDERBUFFER_SIZE: 'MAXRB', MAX_TEXTURE_SIZE: 'MAXTEX', VIEWPORT: 'VP', TEXTURE_2D: 'T2D' };
  const att = v => (typeof v === 'number' && v >= 0x8CE0 && v <= 0x8CE3) ? 'CA' + (v - 0x8CE0) : String(v);
  const gl = {
    ...C,
    getExtension(name) { push('ext', name);
      if (name === 'EXT_color_buffer_float') return S.ext.float ? {} : null;
      if (name === 'EXT_color_buffer_half_float') return S.ext.half ? {} : null;
      return {}; },
    getInternalformatParameter(t, f, p) { return Int32Array.from(S.lists[f] || []); },
    getParameter(k) { if (k === 'MAXDB') return S.maxDraw; if (k === 'MAXCA') return S.maxAttach; if (k === 'MAXRB') return S.maxRb; if (k === 'MAXTEX') return S.maxTex; if (k === 'VP') return [0,0,64,64]; return null; },
    checkFramebufferStatus(t) { S.checks++; push('check'); return S.checks === S.failCheck ? 'INCOMPLETE' : 'COMPLETE'; },
    texImage2D(t, l, ifmt) { push('texImage', ifmt); },
    createRenderbuffer() { const o = obj('R'); push('createRB', o.id); return o; },
    createFramebuffer() { const o = obj('F'); push('createFB', o.id); return o; },
    createTexture() { const o = obj('T'); push('createTex', o.id); return o; },
    deleteRenderbuffer(o) { push('deleteRB', o && o.id); },
    deleteFramebuffer(o) { push('deleteFB', o && o.id); },
    deleteTexture(o) { push('deleteTex', o && o.id); },
    renderbufferStorageMultisample(t, s, f, w, h) { push('rbMS', s, f, w, h); },
    bindFramebuffer(t, fb) { push('bindFB', t, fb ? fb.id : 'null'); },
    readBuffer(b) { push('readBuffer', att(b)); },
    drawBuffers(a) { push('drawBuffers', Array.from(a, att).join(',')); },
    blitFramebuffer(a, b, c, d, e, f, g, h, mask, filter) { push('blit', [a,b,c,d,e,f,g,h].join(','), mask, filter); },
    drawArrays(m, f, c) { push('draw', c); }
  };
  const P = new Proxy(gl, { get(o, k) { return k in o ? o[k] : (() => null); } });
  globalThis.__g1webgl1 = { width: 64, height: 64, addEventListener() {},
    getContext(kind) { if (kind === 'webgl2') return null; push('webgl1-context', kind); return P; } };
  return { width: 64, height: 64, addEventListener() {}, getContext(kind) { return kind === 'webgl2' ? P : null; } };
})();")

;; exists, for-all and list-head are not bound in goeteia (a recorded gap);
;; these three stand in for them here
(define (any? p l) (and (pair? l) (or (p (car l)) (any? p (cdr l)))))
(define (all? p l) (or (null? l) (and (p (car l)) (all? p (cdr l)))))
(define (take l n) (if (or (= n 0) (null? l)) '() (cons (car l) (take (cdr l) (- n 1)))))
(define S (js-get (js-global) "__g1"))
(define logv (js-get S "log"))
(define (entries)
  (let loop ((i 0) (out '()))
    (if (= i (js->number (js-get logv "length")))
        (reverse out)
        (loop (+ i 1) (cons (js->string (js-index logv i)) out)))))
(define (prefixed? s p) (and (>= (string-length s) (string-length p)) (string=? (substring s 0 (string-length p)) p)))
(define (only-with prefixes)
  (filter (lambda (e) (any? (lambda (p) (prefixed? e p)) prefixes)) (entries)))
(define (clear-log!) (js-set! logv "length" 0))
(define (lists! colour depth)
  (js-eval (string-append "globalThis.__g1.lists = { RGBA16F: " colour ", D24: " depth " };")))
(define (ext! float half)
  (js-eval (string-append "globalThis.__g1.ext = { float: " float ", half: " half " };")))
(define (fail-check! k)
  (js-eval (string-append "globalThis.__g1.failCheck = " (number->string k) "; globalThis.__g1.checks = 0;")))
(define (limits! draw attach rb tex)
  (js-eval (string-append "Object.assign(globalThis.__g1, { maxDraw: " draw ", maxAttach: " attach
                          ", maxRb: " rb ", maxTex: " tex " });")))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
(define (try thunk) (guard (e (#t (list 'raised (condition-who e)))) (thunk)))

(fx-init! (js-get (js-global) "__g1canvas"))

;; ---- the sample count ----
(lists! "[8, 4, 2]" "[4]")
(clear-log!)
(define t1 (try (lambda () (fx-target-mrt-msaa! 2 16 16 8))))
(want "8 requested, RGBA16F [8 4 2] and D24 [4]: 4 is the common count"
      (try (lambda () (fx-target-samples t1))) 4)
(want "every multisampled attachment at 4"
      (only-with '("rbMS"))
      '("rbMS:4:RGBA16F:16:16" "rbMS:4:RGBA16F:16:16" "rbMS:4:D24:16:16"))
(lists! "[8, 4, 2]" "[4, 2]")
(want "2 requested, RGBA16F [8 4 2] and D24 [4 2]: 2"
      (try (lambda () (fx-target-samples (fx-target-mrt-msaa! 1 16 16 2)))) 2)
(lists! "[8, 4, 2]" "[8, 4, 2]")
(clear-log!)
(want "8 requested, both [8 4 2]: 8, the largest common count, not the smallest"
      (try (lambda () (fx-target-samples (fx-target-mrt-msaa! 2 16 16 8)))) 8)
(want "and every attachment allocated at 8"
      (only-with '("rbMS"))
      '("rbMS:8:RGBA16F:16:16" "rbMS:8:RGBA16F:16:16" "rbMS:8:D24:16:16"))
(want "6 requested, both [8 4 2]: 4, the largest common count not above the request"
      (try (lambda () (fx-target-samples (fx-target-mrt-msaa! 2 16 16 6)))) 4)
(define (refused-unallocated name thunk)
  (clear-log!)
  (want (string-append name ": refused") (try thunk) '(raised fx-target-mrt-msaa!))
  (want (string-append name ": nothing allocated")
        (only-with '("createRB" "createFB" "createTex")) '()))
(lists! "[8]" "[4]")
(refused-unallocated "8 requested, no common count" (lambda () (fx-target-mrt-msaa! 2 16 16 8)))
(lists! "[8, 4]" "[8, 4]")
(refused-unallocated "2 requested, every count above it" (lambda () (fx-target-mrt-msaa! 2 16 16 2)))
(lists! "[]" "[4]")
(refused-unallocated "a colour format that cannot multisample" (lambda () (fx-target-mrt-msaa! 2 16 16 4)))

;; ---- arguments ----
(lists! "[4]" "[4]")
(refused-unallocated "n of 0" (lambda () (fx-target-mrt-msaa! 0 16 16 4)))
(refused-unallocated "n over MAX_DRAW_BUFFERS" (lambda () (fx-target-mrt-msaa! 5 16 16 4)))
(refused-unallocated "a width of 0" (lambda () (fx-target-mrt-msaa! 2 0 16 4)))
(refused-unallocated "samples of 0" (lambda () (fx-target-mrt-msaa! 2 16 16 0)))
(refused-unallocated "a height of 0" (lambda () (fx-target-mrt-msaa! 2 16 0 4)))
(limits! "4" "2" "4096" "4096")
(refused-unallocated "n over MAX_COLOR_ATTACHMENTS, within MAX_DRAW_BUFFERS" (lambda () (fx-target-mrt-msaa! 3 16 16 4)))
(limits! "4" "4" "8" "4096")
(refused-unallocated "a width over MAX_RENDERBUFFER_SIZE" (lambda () (fx-target-mrt-msaa! 2 16 4 4)))
(refused-unallocated "a height over MAX_RENDERBUFFER_SIZE" (lambda () (fx-target-mrt-msaa! 2 4 16 4)))
(limits! "4" "4" "4096" "8")
(refused-unallocated "a width over MAX_TEXTURE_SIZE" (lambda () (fx-target-mrt-msaa! 2 16 4 4)))
(limits! "4" "4" "4096" "4096")

;; ---- the extension ----
(ext! "false" "true")
(clear-log!)
(want "with only EXT_color_buffer_half_float the target is made"
      (try (lambda () (fx-target-samples (fx-target-mrt-msaa! 2 16 16 4)))) 4)
(want "and that extension is the one enabled"
      (and (member "ext:EXT_color_buffer_half_float" (entries)) #t) #t)
(ext! "false" "false")
(refused-unallocated "with neither float extension" (lambda () (fx-target-mrt-msaa! 2 16 16 4)))
(ext! "true" "true")

;; ---- completeness: each framebuffer's check, failing on its own ----
(define (id-of e) (substring e (+ 1 (let f ((i 0)) (if (char=? (string-ref e i) #\:) i (f (+ i 1))))) (string-length e)))
(define (incomplete-row k)
  (fail-check! k)
  (clear-log!)
  (want (string-append "framebuffer check " (number->string k) " failing: refused")
        (try (lambda () (fx-target-mrt-msaa! 2 16 16 4))) '(raised fx-target-mrt-msaa!))
  (let ((made (map id-of (only-with '("createRB" "createFB" "createTex"))))
        (gone (map id-of (only-with '("deleteRB" "deleteFB" "deleteTex")))))
    (want (string-append "framebuffer check " (number->string k) " failing: everything made is deleted")
          (and (pair? made) (all? (lambda (m) (and (member m gone) #t)) made)) #t))
  (want (string-append "framebuffer check " (number->string k) " failing: both framebuffers were checked or it stopped at the failure")
        (>= (length (only-with '("check"))) k) #t))
(incomplete-row 1)
(incomplete-row 2)
(fail-check! 0)
(clear-log!)
(want "a complete target is checked twice, once per framebuffer"
      (begin (fx-target-mrt-msaa! 2 16 16 4) (length (only-with '("check")))) 2)

;; ---- the resolve, in stream order ----
(define (resolve-calls t n)
  (clear-log!)
  (cmd-begin!)
  (cmd-draw-arrays! GL-TRIANGLES 0 3)
  (fx-resolve! t)
  (cmd-draw-arrays! GL-TRIANGLES 0 6)
  (cmd-flush!)
  (only-with '("draw" "bindFB" "readBuffer" "drawBuffers" "blit")))
(lists! "[4]" "[4]")
(define t2 (fx-target-mrt-msaa! 2 16 16 4))
(let* ((log (resolve-calls t2 2))
       (core (filter (lambda (e) (not (prefixed? e "bindFB"))) log))
       (index-of (lambda (x l) (let f ((l l) (i 0)) (cond ((null? l) #f) ((equal? (car l) x) i) (else (f (cdr l) (+ i 1))))))))
  (want "n = 2: per-attachment selections and colour blits, then the depth blit, between the draws"
        (take core 8)
        '("draw:3"
          "readBuffer:CA0" "drawBuffers:CA0,NONE" "blit:0,0,16,16,0,0,16,16:COLOR:NEAREST"
          "readBuffer:CA1" "drawBuffers:NONE,CA1" "blit:0,0,16,16,0,0,16,16:COLOR:NEAREST"
          "blit:0,0,16,16,0,0,16,16:DEPTH:NEAREST"))
  (want "n = 2: then both restores, in either order, then the next draw"
        (let ((rest (list-tail core 8)))
          (and (= (length rest) 3)
               (or (equal? rest '("drawBuffers:CA0,CA1" "readBuffer:CA0" "draw:6"))
                   (equal? rest '("readBuffer:CA0" "drawBuffers:CA0,CA1" "draw:6")))))
        #t)
  (want "n = 2: READ and DRAW are bound before the first selection"
        (let ((first-sel (index-of "readBuffer:CA0" log)))
          (and first-sel
               (any? (lambda (e) (prefixed? e "bindFB:READ")) (take log first-sel))
               (any? (lambda (e) (prefixed? e "bindFB:DRAW")) (take log first-sel))
               #t))
        #t)
  (want "n = 2: the canvas is bound after the restores and before the next draw"
        (let ((canvas (index-of "bindFB:FB:null" log))
              (last-restore (max (or (index-of "drawBuffers:CA0,CA1" log) -1)
                                 (let f ((l log) (i 0) (k -1)) (cond ((null? l) k) ((equal? (car l) "readBuffer:CA0") (f (cdr l) (+ i 1) i)) (else (f (cdr l) (+ i 1) k))))))
              (next-draw (index-of "draw:6" log)))
          ;; < takes two arguments in goeteia (a recorded gap), so the chain is split
          (and canvas next-draw (< last-restore canvas) (< canvas next-draw)))
        #t))
(define t5 (fx-target-mrt-msaa! 3 16 16 4))
(let ((core (filter (lambda (e) (not (prefixed? e "bindFB"))) (resolve-calls t5 3))))
  (want "n = 3: the third attachment at position 2, a third colour blit, then depth"
        (take core 11)
        '("draw:3"
          "readBuffer:CA0" "drawBuffers:CA0,NONE,NONE" "blit:0,0,16,16,0,0,16,16:COLOR:NEAREST"
          "readBuffer:CA1" "drawBuffers:NONE,CA1,NONE" "blit:0,0,16,16,0,0,16,16:COLOR:NEAREST"
          "readBuffer:CA2" "drawBuffers:NONE,NONE,CA2" "blit:0,0,16,16,0,0,16,16:COLOR:NEAREST"
          "blit:0,0,16,16,0,0,16,16:DEPTH:NEAREST"))
  (want "n = 3: all three draw buffers restored"
        (and (member "drawBuffers:CA0,CA1,CA2" core) #t) #t))
(define t3 (fx-target-mrt-msaa! 1 16 16 4))
(want "n = 1 resolves its depth too"
      (filter (lambda (e) (prefixed? e "blit")) (resolve-calls t3 1))
      '("blit:0,0,16,16,0,0,16,16:COLOR:NEAREST" "blit:0,0,16,16,0,0,16,16:DEPTH:NEAREST"))
(define t4 (fx-target-msaa! 16 16 4))
(want "CONTROL the single-colour multisampled target still resolves with one colour blit"
      (filter (lambda (e) (prefixed? e "blit")) (resolve-calls t4 1))
      '("blit:0,0,16,16,0,0,16,16:COLOR:NEAREST"))

;; ---- the depth texture accessor ----
(want "fx-target-depth-texture of the MRT target is a slot"
      (integer? (fx-target-depth-texture t2)) #t)
(want "fx-target-depth-texture of a plain colour target is #f"
      (fx-target-depth-texture (fx-target! 16 16)) #f)
(want "fx-target-depth-texture of a depth-only target is its texture"
      (let ((d (fx-target! 16 16 #t))) (equal? (fx-target-depth-texture d) (fx-target-texture d))) #t)

;; ---- the single-sampled MRT's depth is a sampleable texture too ----
(clear-log!)
(define m2 (fx-target-mrt! 2 16 16))
(want "fx-target-mrt! allocates its depth as a DEPTH_COMPONENT24 texture"
      (and (member "texImage:D24" (only-with '("texImage"))) #t) #t)
(want "and makes no depth renderbuffer"
      (only-with '("createRB")) '())
(want "fx-target-depth-texture of the single-sampled MRT is a slot"
      (integer? (fx-target-depth-texture m2)) #t)

;; ---- WebGL1: refused before any extension is asked for ----
(fx-init! (js-get (js-global) "__g1webgl1"))
(clear-log!)
(want "on a WebGL1 context the constructor is refused"
      (try (lambda () (fx-target-mrt-msaa! 2 16 16 4))) '(raised fx-target-mrt-msaa!))
(want "and asks for no float extension first"
      (filter (lambda (e) (or (prefixed? e "ext:EXT_color_buffer") (prefixed? e "createRB") (prefixed? e "createFB"))) (entries))
      '())

(display (if (null? fails) #t (reverse fails)))
