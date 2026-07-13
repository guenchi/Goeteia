;; Ten thousand particles, raw WebGL, no Three.js.
;; Per frame Scheme updates every particle in the staging memory
;; (unboxed float trees, zero allocation) and encodes the whole frame
;; as a command buffer -- ONE bridge call replays it.
(import (rnrs) (web js) (gfx gl) (gfx glsl))

(define N 10000)
(define POS 4096)                        ; xy pairs, 8 bytes each
(define VEL (+ POS (* 8 N)))
(%mem-grow 3)                            ; room for both arrays

;; a small LCG for initial positions/velocities
(define seed 12345)
(define (rnd!)                           ; -> [0,1) flonum
  (set! seed (remainder (+ (* seed 1103515245) 12345) 2147483648))
  (fl/ (fixnum->flonum (remainder seed 100000)) 100000.0))

(let init ((i 0))
  (when (< i N)
    (let ((b (* 8 i)))
      (%mem-f32-set! (+ POS b) (fl- (fl* 2.0 (rnd!)) 1.0))
      (%mem-f32-set! (+ POS b 4) (fl- (fl* 2.0 (rnd!)) 1.0))
      (%mem-f32-set! (+ VEL b) (fl* 0.01 (fl- (rnd!) 0.5)))
      (%mem-f32-set! (+ VEL b 4) (fl* 0.01 (fl- (rnd!) 0.5))))
    (init (+ i 1))))

;; move; bounce off the walls by flipping the velocity
(define (step-axis! p v)
  (let ((x (fl+ (%mem-f32-ref p) (%mem-f32-ref v))))
    (when (or (fl<? x -1.0) (fl<? 1.0 x))
      (%mem-f32-set! v (fl- 0.0 (%mem-f32-ref v))))
    (%mem-f32-set! p (fl+ (%mem-f32-ref p) (%mem-f32-ref v)))))
(define (step!)
  (let loop ((i 0))
    (when (< i N)
      (let ((b (* 8 i)))
        (step-axis! (+ POS b) (+ VEL b))
        (step-axis! (+ POS b 4) (+ VEL b 4)))
      (loop (+ i 1)))))

;; GL setup: one program, one buffer
(define canvas (js-method (js-get (js-global) "document")
                          "getElementById" "c"))
(gl-attach! canvas)
;; shaders authored as s-expressions, rendered by (gfx glsl)
(gl-program! 0
  (glsl->string
   '((attribute vec2 p)
     (define (main) void
       (set! gl_Position (vec4 p (fl 0) (fl 1)))
       (set! gl_PointSize (fl 2)))))
  (glsl->string
   '((precision mediump float)
     (define (main) void
       (set! gl_FragColor (vec4 (fl 0 28) (fl 0 53) (fl 0 93) (fl 1)))))))
(gl-buffer! 1)
(cmd-region! 0)

(define (frame!)
  (step!)
  (cmd-begin!)
  (cmd-viewport! 0 0 800 600)
  (cmd-clear! 0.07 0.08 0.12 1.0)
  (cmd-use-program! 0)
  (cmd-bind-buffer! 1)
  (cmd-buffer-data! POS (* 8 N))
  (cmd-vertex-attrib! 0 2 0 0)
  (cmd-draw-arrays! GL-POINTS 0 N)
  (cmd-flush!))

(letrec ((tick (lambda _
                 (frame!)
                 (js-method (js-global) "requestAnimationFrame" tick))))
  (js-method (js-global) "requestAnimationFrame" tick))
