;; expect: #t
;; fx-loop! and fx-loop-fixed! end every frame with no vertex array of
;; the library's bound (R56: archive/goeteia-m26-2026-11-12.md).
;;
;; THE DEFECT.  A frame left the last vertex array it drew with bound.
;; Host code sharing the context that set an attribute pointer after the
;; frame, without binding a vertex array of its own first, wrote it into
;; the library's, and the library's next draw through that vertex array
;; read the host's buffer.  limits.md ("What the records assume") forbids
;; configuring a library-owned vertex array, but the host could not know
;; it was configuring one.
;;
;; THE RULE.  The frame loops encode cmd-unbind-vao! after the caller's
;; commands, before the flush: what is bound after the frame is the
;; default vertex array.  A frame of one's own (cmd-begin! ... cmd-flush!)
;; is unchanged; it ends with cmd-unbind-vao! if it wants the same.
;;
;; Mock: test/lib/glstate.ss, with requestAnimationFrame captured so the
;; cell runs each frame itself.  The host's step binds a buffer of its
;; own, fills it, and points attribute 0 at it, with no vertex array
;; bound by it.
;;
;; Rows (base = the tree before the change):
;;   L1  fx-loop!: after the host's step, the next frame's draw reads
;;       what the first frame's read (base: attribute 0 reads the host's
;;       buffer); and again after a second step, a frame later -- frames
;;       after the first have a non-zero dt
;;   L2  fx-loop!: every frame's last vertex-array call binds none, the
;;       first three frames (base: it binds the library's)
;;   L3  fx-loop-fixed!: as L1
;;   L4  fx-loop-fixed!: as L2
;;   L6  fx-loop!: a frame whose own commands leave exactly one word of
;;       the region runs, and ends binding none (a cleanup that is skipped
;;       or misplaced near the end of the region)
;;   L7  fx-loop!: a frame whose own commands fill the region raises the
;;       region's overflow error, (cmd-region! "command region overflow"
;;       65536), and does not run: nothing is replayed, the position is back
;;       at the end of the frame's own commands, and the byte past the
;;       region is untouched (a cleanup that is skipped when it does not
;;       fit, letting the frame flush).  The error is raised inside the
;;       frame callback, where (web js) catches it and hands it to its
;;       report hook; the row installs its own hook (js-callback-error!)
;;       for that one frame, reads what it was given, and puts the default
;;       back -- the default writes the console, which the runner counts
;;       as a failure.
;;   L5  a WebGL 1 context (the fallback: no vertex arrays at all) runs an
;;       fx-loop! frame that draws nothing through a vertex array: the
;;       unbind does nothing there (an unguarded unbind raises a TypeError
;;       at replay; green on base, which encodes no unbind)
(import (rnrs) (web js) (gfx gl) (gfx fx) (glstate))

(js-eval "globalThis.requestAnimationFrame = cb => { globalThis.__tick = cb; };
globalThis.__host_step = (gl) => {
  const b = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, b);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([9, 8, 7, 6, 5, 4, 3, 2]));
  gl.enableVertexAttribArray(0);
  gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 8, 0); };")

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))

(define canvas (glstate-canvas 64 64))
(fx-init! canvas)
(define ctx (js-method canvas "getContext" "webgl2"))
(define (host-step!) (js-call (js-get (js-global) "__host_step") (js-undefined) ctx))
(define clock 0)
;; run the frame the loop registered last
(define (pump!)
  (set! clock (+ clock 16))
  (js-call (js-get (js-global) "__tick") (js-undefined) clock))
(define (prog)
  (fx-program! '((attribute vec2 a_pos)
                 (define (main) void (set! gl_Position (vec4 a_pos (fl 0) (fl 1)))))
               '((precision mediump float)
                 (define (main) void (set! gl_FragColor (vec4 (fl 1) (fl 0) (fl 0) (fl 1)))))))
(define (filled seed)
  (let ((b (fx-buffer!)) (at (fx-alloc! 64)))
    (let fill ((i 0))
      (when (< i 16)
        (%mem-f32-set! (+ at (* 4 i)) (+ seed (* 0.5 (fixnum->flonum i))))
        (fill (+ i 1))))
    (cmd-begin!) (cmd-bind-buffer! b) (cmd-buffer-data! at 64) (cmd-flush!)
    b))
;; one frame: its draws, and its last vertex-array call
(define (frame!)
  (glstate-reset!) (pump!)
  (list (glstate-draws)
        (let ((vs (filter (lambda (c) (and (>= (string-length c) 16)
                                           (string=? (substring c 0 16) "bindVertexArray(")))
                          (glstate-calls))))
          (if (null? vs) 'none (list-ref vs (- (length vs) 1))))))

;; frames f1, host step, f2, host step, f3: what each drew and its last
;; vertex-array call
(define (three-frames!)
  (let* ((f1 (frame!)) (_ (host-step!)) (f2 (frame!)) (__ (host-step!)) (f3 (frame!)))
    (list f1 f2 f3)))
(define (check-loop who fs)
  (let ((f1 (car fs)) (f2 (cadr fs)) (f3 (caddr fs)))
    (want (string-append who ": after the host's step the draw reads what it read")
          (car f2) (car f1))
    (want (string-append who ": after a second step, a frame later, the same")
          (car f3) (car f1))
    (want (string-append who ": every frame ends binding no vertex array")
          (map cadr fs)
          '("bindVertexArray(null)" "bindVertexArray(null)" "bindVertexArray(null)"))))

(let ((p (prog)) (vb (filled 1.0)))
  (fx-loop! (lambda (t dt) (fx-use! p vb) (cmd-draw-arrays! GL-TRIANGLES 0 3)))
  (check-loop "L1/L2 fx-loop!" (three-frames!)))

(let ((p (prog)) (vb (filled 20.0)))
  (fx-loop-fixed! 0.01 (lambda (step) #t)
                  (lambda (a t dt) (fx-use! p vb) (cmd-draw-arrays! GL-TRIANGLES 0 3)))
  (check-loop "L3/L4 fx-loop-fixed!" (three-frames!)))

;; L6/L7: the region is [0, 65536), 16,384 words; the loop writes a
;; 5-word viewport first.  The frame's own words are five-word clears and
;; two-word buffer binds -- no vertex-array command among them, so the
;; frame's last vertex-array call can only be the loop's.  3,274 clears
;; and 4 binds are 16,378 words: one word is left.  3,275 clears and 2
;; binds are 16,379: none is.
(define fill-buf (filled 40.0))
(define (fill! clears binds)
  (let loop ((i 0)) (when (< i clears) (cmd-clear! 0.0 0.0 0.0 1.0) (loop (+ i 1))))
  (let loop ((i 0)) (when (< i binds) (cmd-bind-buffer! fill-buf) (loop (+ i 1)))))
(fx-loop! (lambda (t dt) (fill! 3274 4)))
(let ((f (frame!)))
  (want "L6 a frame leaving one word runs and ends binding none" (cadr f) "bindVertexArray(null)")
  (want "L6 and it ran all its words" (cmd-pos) 65536))
(define sentinel (%mem-u8-ref 65536))
(define pos-after-fill #f)
(fx-loop! (lambda (t dt) (fill! 3275 2) (set! pos-after-fill (cmd-pos))))
(define reported '())
(glstate-reset!)
(js-callback-error! (lambda (e) (set! reported (cons e reported))))
(pump!)
(js-callback-error! #f)
(want "L7 the frame raised the region's overflow error"
      (map (lambda (e) (if (error? e)
                           (list (condition-who e) (condition-message e) (condition-irritants e))
                           'not-an-error))
           reported)
      (list (list 'cmd-region! "command region overflow" (list 65536))))
(want "L7 the frame's commands filled the region" pos-after-fill 65536)
(want "L7 and nothing was replayed" (glstate-calls) '())
(want "L7 the position stays at the end of the frame's own commands" (cmd-pos) 65536)
(want "L7 the byte past the region is untouched" (%mem-u8-ref 65536) sentinel)

;; L5, last: it attaches the library to another canvas
(js-eval "globalThis.__gl1canvas = { width: 64, height: 64, addEventListener() {},
  getContext(k) { return k === 'webgl2' ? null : { viewport() {}, clearColor() {}, clear() {} }; } };")
(fx-init! (js-get (js-global) "__gl1canvas"))
(fx-loop! (lambda (t dt) (cmd-clear! 0.0 0.0 0.0 1.0)))
(want "L5 a WebGL 1 context runs the frame"
      (glstate-attempt (lambda () (pump!))) "ok")

(display (if (null? fails) #t (reverse fails)))
