;; expect: #t
;; A particle's size on screen is computed against the height of the
;; viewport IN FORCE WHEN THE DRAW RUNS, not the canvas.
;;
;; The vertex shader turns a world size into pixels with u_height, and
;; particles-draw! used to upload the CANVAS height for it.  Drawn into
;; an off-screen target of another height -- a reduced-resolution pass,
;; a reflection, a post chain -- every particle came out scaled by the
;; ratio of the two, with nothing to say so.
;;
;; WHY AT REPLAY.  Commands are encoded into a buffer and replayed into
;; GL later, and the two orders can part: cmd-begin! discards what was
;; encoded, the same buffer can be flushed twice, cmd-region! moves the
;; start of the replay, an overflow stops a command half-way, a new
;; attach finds commands still in the buffer.  A height remembered when
;; the draw was ENCODED was wrong in each of those (measured on the
;; attempt that did that, 2026-09-25).  So the height is resolved when
;; the upload is REPLAYED: the replayer asks GL for the viewport in
;; force at that moment.  The design and its review are in
;; archive/goeteia-t4-viewport-design-2026-09-25.md.
;;
;; THE MOCK.  Each case gets its own canvas, and a canvas answers every
;; getContext with the SAME context, as a browser does.  The context
;; keeps its viewport as WebGL does: it starts as the size given at
;; creation; each argument is converted to a signed 32-bit integer
;; first, as WebIDL does for a GLint; a negative width or height is then
;; refused and changes nothing; a size larger than MAX_VIEWPORT_DIMS
;; (1024 here) is clamped; and getParameter(VIEWPORT) answers the
;; viewport in force.
;;
;; A NEGATIVE HEIGHT IS REFUSED, NOT CLAMPED.  cmd-viewport! writes its
;; words as unsigned 32-bit, so -1 reaches the replayer as 4294967295;
;; WebIDL's conversion to GLint turns that back into -1, and GL refuses
;; it.  An earlier version of this cell and of the design said it was
;; clamped to 1024, and its row started from a height already at 1024,
;; which could not tell the two apart (pointed out by codex, T4 review
;; round 1, 2026-09-25).  The row now starts from 77.
(import (rnrs) (web js) (gfx gl) (gfx fx) (gfx mat) (gfx particles))

(js-eval "globalThis.__gllog = [];
globalThis.__mkcanvas = (w, h, vp) => {
  const log = globalThis.__gllog; const push = (...a) => log.push(a.join(':'));
  let ctx = null;
  return { width: w, height: h, addEventListener(k, f) {}, getContext(kind) {
    if (ctx) return ctx;
    ctx = { VERTEX_SHADER:'VS', FRAGMENT_SHADER:'FS', COMPILE_STATUS:'CS', LINK_STATUS:'LS', COLOR_BUFFER_BIT:16384, DEPTH_BUFFER_BIT:256, ARRAY_BUFFER:'AB', DYNAMIC_DRAW:'DD', FLOAT:'F', TRIANGLES:'TRI', POINTS:'PTS', TRIANGLE_STRIP:'STRIP', DEPTH_TEST:'DT', ELEMENT_ARRAY_BUFFER:'EAB', UNSIGNED_SHORT:'US', TEXTURE_2D:'T2D', TEXTURE0:33984, TEXTURE_MIN_FILTER:'MIN', TEXTURE_MAG_FILTER:'MAG', TEXTURE_WRAP_S:'WS', TEXTURE_WRAP_T:'WT', LINEAR:'LIN', LINEAR_MIPMAP_LINEAR:'LML', CLAMP_TO_EDGE:'CL', RGBA:'RGBA', UNSIGNED_BYTE:'UB', NEAREST:'NEA', FRAMEBUFFER:'FB', DEPTH_ATTACHMENT:'DA', COLOR_ATTACHMENT0:'CA0', RENDERBUFFER:'RB', DEPTH_COMPONENT16:'D16', DEPTH_COMPONENT24:'D24', DEPTH_COMPONENT:'DC', UNSIGNED_INT:'UI', NONE:'NONE', VIEWPORT:'VP', MAX_VIEWPORT_DIMS:'MVD',
      __vp: vp ? Array.from(vp) : [0, 0, w, h],
      createShader(k){ return {kind:k} }, shaderSource(){}, compileShader(){}, getShaderParameter(){ return true }, createProgram(){ return {id:'P'+(this._p=(this._p||0)+1)} }, attachShader(){}, linkProgram(){}, getProgramParameter(){ return true }, bindAttribLocation(){}, createVertexArray(){ return {id:'V'+(this._v=(this._v||0)+1)} }, bindVertexArray(){}, createBuffer(){ return {id:'B'+(this._b=(this._b||0)+1)} }, getUniformLocation(p,n){ return {id:'U:'+n} }, createTexture(){ return {id:'T'+(this._t=(this._t||0)+1)} }, bindTexture(){}, texParameteri(){}, generateMipmap(){}, texImage2D(){}, activeTexture(){}, createFramebuffer(){ return {id:'F'+(this._fb=(this._fb||0)+1)} }, bindFramebuffer(){}, framebufferTexture2D(){}, createRenderbuffer(){ return {id:'R'+(this._rb=(this._rb||0)+1)} }, bindRenderbuffer(){}, renderbufferStorage(){}, framebufferRenderbuffer(){}, drawBuffers(){}, enable(){}, disable(){}, blendFunc(){}, depthMask(){}, clearColor(){}, clear(){}, useProgram(){}, bindBuffer(){}, bufferData(){}, enableVertexAttribArray(){}, vertexAttribPointer(){}, vertexAttribDivisor(){},
      viewport(x, y, vw, vh) {
        const n = [x, y, vw, vh].map(v => Number(v) | 0);
        push('viewport', n.join(','));
        if (n[2] < 0 || n[3] < 0) { push('glerror', 'INVALID_VALUE'); return; }
        this.__vp = [n[0], n[1], Math.min(n[2], 1024), Math.min(n[3], 1024)];
      },
      getParameter(k) { return k === 'VP' ? this.__vp.slice() : k === 'MVD' ? [1024, 1024] : null; },
      uniform1f(loc, x){ push('uniform1f', loc.id, Number(x).toFixed(2)) }, uniform2f(loc, x, y){ push('uniform2f', loc.id, Number(x).toFixed(2), Number(y).toFixed(2)) }, uniform3f(){}, uniform1i(){}, uniform4f(){}, uniformMatrix4fv(){}, drawArrays(m, f, c){ push('draw', m, f, c) } };
    return ctx; } }; };")

(define log (js-get (js-global) "__gllog"))
(define (entries)
  (let loop ((i 0) (out '()))
    (if (= i (js->number (js-get log "length")))
        (reverse out)
        (loop (+ i 1) (cons (js->string (js-index log i)) out)))))
(define (prefixed? s p)
  (and (>= (string-length s) (string-length p)) (string=? (substring s 0 (string-length p)) p)))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))

;; A fresh canvas of w x h, attached.  vp, when given, is the context's
;; viewport at creation instead of the canvas size, as a JS array.
(define (fresh-canvas w h . vp)
  (let ((c (if (null? vp)
               (js-call (js-get (js-global) "__mkcanvas") (js-undefined) w h)
               (js-call (js-get (js-global) "__mkcanvas") (js-undefined) w h (car vp)))))
    (fx-init! c)
    c))
(define (clear-log!) (js-set! log "length" 0))
;; The u_height values uploaded since the log was cleared, in order.
(define (heights)
  (let loop ((l (entries)) (out '()))
    (cond ((null? l) (reverse out))
          ((prefixed? (car l) "uniform1f:U:u_height:")
           (loop (cdr l) (cons (substring (car l) 21 (string-length (car l))) out)))
          (else (loop (cdr l) out)))))
(define (D) (particles-draw! (make-particles 16) (m4-identity)))
(define (V h) (cmd-viewport! 0 0 320 h))
(define (prime h) (cmd-begin!) (V h) (cmd-flush!))
;; the size fx-init! gives the command region
(define L 262144)

;; ---- the rows kept from the encode-time cells, read at replay ----

(let ((c (fresh-canvas 640 480)))
  (clear-log!) (cmd-begin!) (D) (cmd-flush!)
  (want "with no viewport encoded, the viewport the context started with" (heights) '("480.00")))

;; A canvas resized after its context was made: GL's viewport stays at
;; the creation size until it is set, and that is what is in force.
(let ((c (fresh-canvas 640 480)))
  (js-set! c "height" 300)
  (clear-log!) (cmd-begin!) (D) (cmd-flush!)
  (want "a canvas resized after creation, no viewport set: the viewport in force, not the canvas"
        (heights) '("480.00")))

(let* ((c (fresh-canvas 640 480))
       (target (fx-target! 200 150)))
  (clear-log!) (cmd-begin!) (fx-bind-target! target) (D) (cmd-flush!)
  (want "drawn into a 200x150 target, its height" (heights) '("150.00"))
  (clear-log!) (cmd-begin!) (V 100) (D) (cmd-flush!)
  (want "after an explicit viewport, that viewport's height" (heights) '("100.00"))
  (clear-log!) (cmd-begin!) (fx-bind-canvas!) (D) (cmd-flush!)
  (want "back on the canvas, the canvas height" (heights) '("480.00"))
  (let ((p (make-particles 16)))
    (clear-log!) (cmd-begin!) (V 150) (particles-draw! p (m4-identity)) (V 100) (particles-draw! p (m4-identity)) (cmd-flush!)
    (want "one system drawn under two viewports in one frame uploads each" (heights) '("150.00" "100.00"))
    (clear-log!) (cmd-begin!) (V 150) (particles-draw! p (m4-identity)) (cmd-flush!)
    (want "and the same system at the same height in a later frame uploads again" (heights) '("150.00")))
  (clear-log!) (cmd-begin!) (V 20) (V 70) (D) (cmd-flush!)
  (want "of two viewports encoded before the draw, the later one" (heights) '("70.00"))
  (clear-log!) (cmd-begin!) (V 0) (D) (cmd-flush!)
  (want "a zero-height viewport gives zero" (heights) '("0.00"))
  (prime 32)
  (clear-log!) (cmd-begin!) (D) (cmd-flush!)
  (want "a viewport set in an earlier frame is still the one in force" (heights) '("32.00"))
  ;; A viewport encoded and then discarded by cmd-begin! never ran.
  (prime 150)
  (cmd-begin!) (V 100)
  (clear-log!) (cmd-begin!) (D) (cmd-flush!)
  (want "a viewport encoded and then discarded by cmd-begin! is not the one in force" (heights) '("150.00")))

;; ---- the cases the encode-time attempt got wrong ----

;; 1  The same buffer flushed twice: the draw runs under a different
;;    viewport the second time.
(let ((c (fresh-canvas 640 480)))
  (prime 100)
  (clear-log!) (cmd-begin!) (D) (V 200) (cmd-flush!) (cmd-flush!)
  (want "1 a buffer flushed twice uploads the viewport in force at each replay" (heights) '("100.00" "200.00")))

;; 2  cmd-region! moves the replay past a viewport command.
(let ((c (fresh-canvas 640 480)))
  (prime 100)
  (clear-log!) (cmd-region! 0 L) (cmd-begin!) (V 200) (cmd-region! 20 L) (D) (cmd-flush!)
  (want "2 a viewport outside the replayed region is not in force" (heights) '("100.00")))

;; 3  A viewport command that overflows the region is never written.
(let ((c (fresh-canvas 640 480)))
  (prime 100)
  (clear-log!) (cmd-region! 0 L) (cmd-begin!) (cmd-region! 0 0)
  (guard (e (#t #f)) (V 200))
  (cmd-region! 0 L) (D) (cmd-flush!)
  (want "3 a viewport that overflowed the region never took effect" (heights) '("100.00")))

;; 4  fx-init! again on the same canvas: the same context, whose
;;    viewport is still what was last set.
(let ((c (fresh-canvas 640 480)))
  (prime 100)
  (fx-init! c)
  (clear-log!) (cmd-begin!) (D) (cmd-flush!)
  (want "4 re-attaching the same canvas keeps the context's viewport" (heights) '("100.00")))

;; 5  A viewport command still in the buffer when a new attach happens
;;    is replayed after it.
(let ((c (fresh-canvas 640 480)))
  (clear-log!) (cmd-region! 0 L) (cmd-begin!) (V 100)
  (fx-init! c)
  (D) (cmd-flush!)
  (want "5 a viewport encoded before a re-attach and replayed after it is in force" (heights) '("100.00")))

;; 6  GL clamps a viewport larger than MAX_VIEWPORT_DIMS, and refuses a
;;    negative one, leaving the viewport as it was.
(let ((c (fresh-canvas 640 480)))
  (clear-log!) (cmd-begin!) (V 2048) (D) (cmd-flush!)
  (want "6 a viewport above the limit is in force as clamped" (heights) '("1024.00"))
  (prime 77)
  (clear-log!) (cmd-begin!) (V -1) (D) (cmd-flush!)
  (want "6 a height of -1 is refused and the viewport stays where it was" (heights) '("77.00")))

;; 8  A context whose starting viewport is not the canvas size.
(let ((c (fresh-canvas 640 480 (js-eval "[0, 0, 320, 240]"))))
  (clear-log!) (cmd-begin!) (D) (cmd-flush!)
  (want "8 the context's starting viewport, not the canvas height" (heights) '("240.00")))

;; A new canvas is a new context, with its own starting viewport,
;; whatever the old one was left at.
(let ((c (fresh-canvas 640 480)))
  (prime 77)
  (let ((c2 (fresh-canvas 640 240)))
    (clear-log!) (cmd-begin!) (D) (cmd-flush!)
    (want "a new canvas answers its own viewport, not the old context's" (heights) '("240.00"))))

;; CONTROL for the mock: it records the request and holds the clamped
;; viewport, as the rows above assume.
(let ((c (fresh-canvas 640 480)))
  (clear-log!) (cmd-begin!) (V 2048) (cmd-flush!)
  (want "CONTROL the mock saw the request and holds the clamped viewport"
        (list (and (member "viewport:0,0,320,2048" (entries)) #t)
              (js->number (js-index (js-method (js-method c "getContext" "webgl2") "getParameter" "VP") 3)))
        (list #t 1024)))

(display (if (null? fails) #t (reverse fails)))
