;; expect: #t
;; Uniforms that carry the viewport's size are resolved when they are
;; replayed, and are always sent.
;;
;; fx-uniform-viewport-height! and fx-uniform-viewport-size! encode an
;; upload whose VALUE the replayer reads from GL at the moment it runs:
;; the height, or the width and height, of the viewport in force.  The
;; fullscreen quad's u_resolution and the sprite batch's u_resolution go
;; through the second; particle point sizes through the first
;; (particles-size-follows-the-viewport.ss).  The design and its review
;; are in archive/goeteia-t4-viewport-design-2026-09-25.md.
;;
;; ALWAYS SENT.  fx-uniform! skips a uniform whose value has not changed
;; since it last encoded one, and it decides that at ENCODE time.  A
;; value resolved at replay cannot take part in that comparison, so a
;; uniform written through a viewport helper is marked and never skipped
;; afterwards -- whether the next write is the helper again or a literal
;; fx-uniform!.  Two rows pin that: one where a literal value was
;; remembered BEFORE the helper wrote (deleting the entry once would
;; pass it, never remembering again is what it asks), and one where a
;; literal upload after the helper is encoded and discarded by
;; cmd-begin! (deleting once fails it: the discarded upload refills the
;; memory and the next, real one is skipped).
;;
;; ON THE TREE BEFORE THE CHANGE this cell does not compile: the helpers
;; do not exist there.  That is red, but it reads nothing.  What it
;; separates is a correct helper from one that forgets the marker or
;; deletes the entry once.  The u_resolution rows that ARE read on the
;; old tree are in test/fx.ss and test/sprite.ss (viewport-res-ok).
(import (rnrs) (web js) (gfx gl) (gfx fx) (gfx particles))

(js-eval "globalThis.__gllog = [];
globalThis.__mkcanvas = (w, h) => {
  const log = globalThis.__gllog; const push = (...a) => log.push(a.join(':'));
  let ctx = null;
  return { width: w, height: h, addEventListener(k, f) {}, getContext(kind) {
    if (ctx) return ctx;
    ctx = { VERTEX_SHADER:'VS', FRAGMENT_SHADER:'FS', COMPILE_STATUS:'CS', LINK_STATUS:'LS', COLOR_BUFFER_BIT:16384, DEPTH_BUFFER_BIT:256, ARRAY_BUFFER:'AB', DYNAMIC_DRAW:'DD', FLOAT:'F', TRIANGLES:'TRI', POINTS:'PTS', TRIANGLE_STRIP:'STRIP', DEPTH_TEST:'DT', ELEMENT_ARRAY_BUFFER:'EAB', UNSIGNED_SHORT:'US', TEXTURE_2D:'T2D', TEXTURE0:33984, TEXTURE_MIN_FILTER:'MIN', TEXTURE_MAG_FILTER:'MAG', TEXTURE_WRAP_S:'WS', TEXTURE_WRAP_T:'WT', LINEAR:'LIN', LINEAR_MIPMAP_LINEAR:'LML', CLAMP_TO_EDGE:'CL', RGBA:'RGBA', UNSIGNED_BYTE:'UB', NEAREST:'NEA', FRAMEBUFFER:'FB', DEPTH_ATTACHMENT:'DA', COLOR_ATTACHMENT0:'CA0', RENDERBUFFER:'RB', DEPTH_COMPONENT16:'D16', DEPTH_COMPONENT24:'D24', DEPTH_COMPONENT:'DC', UNSIGNED_INT:'UI', NONE:'NONE', VIEWPORT:'VP',
      __vp: [0, 0, w, h],
      createShader(k){ return {kind:k} }, shaderSource(){}, compileShader(){}, getShaderParameter(){ return true }, createProgram(){ return {id:'P'+(this._p=(this._p||0)+1)} }, attachShader(){}, linkProgram(){}, getProgramParameter(){ return true }, bindAttribLocation(){}, createVertexArray(){ return {id:'V'+(this._v=(this._v||0)+1)} }, bindVertexArray(){}, createBuffer(){ return {id:'B'+(this._b=(this._b||0)+1)} }, getUniformLocation(p,n){ return {id:'U:'+n} }, createTexture(){ return {id:'T'+(this._t=(this._t||0)+1)} }, bindTexture(){}, texParameteri(){}, generateMipmap(){}, texImage2D(){}, activeTexture(){}, createFramebuffer(){ return {id:'F'+(this._fb=(this._fb||0)+1)} }, bindFramebuffer(){}, framebufferTexture2D(){}, createRenderbuffer(){ return {id:'R'+(this._rb=(this._rb||0)+1)} }, bindRenderbuffer(){}, renderbufferStorage(){}, framebufferRenderbuffer(){}, drawBuffers(){}, enable(){}, disable(){}, blendFunc(){}, depthMask(){}, clearColor(){}, clear(){}, useProgram(){}, bindBuffer(){}, bufferData(){}, enableVertexAttribArray(){}, vertexAttribPointer(){}, vertexAttribDivisor(){},
      viewport(x, y, vw, vh) { const n = [x, y, vw, vh].map(Number); push('viewport', n.join(',')); this.__vp = n; },
      getParameter(k) { return k === 'VP' ? this.__vp.slice() : null; },
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
(define (uploads prefix)
  (let loop ((l (entries)) (out '()))
    (cond ((null? l) (reverse out))
          ((prefixed? (car l) prefix)
           (loop (cdr l) (cons (substring (car l) (string-length prefix) (string-length (car l))) out)))
          (else (loop (cdr l) out)))))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
(define (clear-log!) (js-set! log "length" 0))
(define (V w h) (cmd-viewport! 0 0 w h))

(fx-init! (js-call (js-get (js-global) "__mkcanvas") (js-undefined) 640 480))

;; ---- the fullscreen quad's u_resolution ----
(define q
  (fx-fullscreen!
   '((precision mediump float)
     (uniform vec2 u_resolution)
     (define (main) void
       (set! gl_FragColor (vec4 (/ gl_FragCoord.xy u_resolution) (fl 0) (fl 1)))))))
(clear-log!) (cmd-begin!) (fx-fullscreen-use! q 0.0) (cmd-flush!)
(want "the fullscreen quad on the canvas gets the canvas's size"
      (uploads "uniform2f:U:u_resolution:") '("640.00:480.00"))
(clear-log!) (cmd-begin!) (V 320 150) (fx-fullscreen-use! q 0.0) (cmd-flush!)
(want "under a 320x150 viewport it gets 320x150, not the canvas"
      (uploads "uniform2f:U:u_resolution:") '("320.00:150.00"))

;; ---- the dedup marker, on a program this cell owns ----
;; A particle program declares float u_height; any program declaring the
;; uniform will do, and this one is not shared with any other row.
(define (fresh-program) (fx-program3! (particles-vertex-shader) (particles-fragment-shader)))
(define (try thunk) (guard (e (#t (list 'raised (condition-who e)))) (thunk)))

;; 1: a literal value remembered before the helper wrote.
(let ((p (fresh-program)))
  (want "dedup 1: literal, helper, literal all reach GL"
        (try (lambda ()
               (clear-log!) (cmd-begin!) (V 320 150)
               (fx-uniform! p 'u_height 480.0)
               (fx-uniform-viewport-height! p 'u_height)
               (fx-uniform! p 'u_height 480.0)
               (cmd-flush!)
               (uploads "uniform1f:U:u_height:")))
        '("480.00" "150.00" "480.00")))

;; 2: a literal upload after the helper, discarded by cmd-begin!.
(let ((p (fresh-program)))
  (want "dedup 2: a discarded literal does not suppress the next one"
        (try (lambda ()
               (clear-log!) (cmd-begin!) (V 320 150)
               (fx-uniform-viewport-height! p 'u_height)
               (cmd-flush!)
               (cmd-begin!) (fx-uniform! p 'u_height 480.0)
               (cmd-begin!) (fx-uniform! p 'u_height 480.0)
               (cmd-flush!)
               (uploads "uniform1f:U:u_height:")))
        '("150.00" "480.00")))

;; The first of the two for a vec2, through a fullscreen quad's own
;; program: the marker is per uniform name, whatever its type.
(let ((p (fx-quad-program (fx-fullscreen!
                           '((precision mediump float)
                             (uniform vec2 u_resolution)
                             (define (main) void
                               (set! gl_FragColor (vec4 (/ gl_FragCoord.xy u_resolution) (fl 0) (fl 1)))))))))
  (want "dedup 1 for a vec2: literal, helper, literal all reach GL"
        (try (lambda ()
               (clear-log!) (cmd-begin!) (V 320 150)
               (fx-uniform! p 'u_resolution 640.0 480.0)
               (fx-uniform-viewport-size! p 'u_resolution)
               (fx-uniform! p 'u_resolution 640.0 480.0)
               (cmd-flush!)
               (uploads "uniform2f:U:u_resolution:")))
        '("640.00:480.00" "320.00:150.00" "640.00:480.00")))

;; CONTROL for the instrument: an ordinary uniform still deduplicates --
;; the marker is per name, not a switch that turns caching off.
(let ((p (fresh-program)))
  (want "CONTROL an unmarked uniform sent twice with one value is uploaded once"
        (begin (clear-log!) (cmd-begin!)
               (fx-uniform! p 'u_size_max 96.0) (fx-uniform! p 'u_size_max 96.0)
               (cmd-flush!)
               (uploads "uniform1f:U:u_size_max:"))
        '("96.00")))

(display (if (null? fails) #t (reverse fails)))
