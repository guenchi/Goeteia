;; The plasma again -- but the whole render loop lives in a Worker
;; over an OffscreenCanvas (rt/worker.mjs).  The main thread only
;; forwards input; jam it with the button in the page and the
;; animation does not drop a frame.  There is no document here: the
;; canvas shim hangs off the worker global.
(import (rnrs) (web js) (gfx glsl) (gfx fx))

(define canvas (js-get (js-global) "__goeteia_canvas"))
(fx-init! canvas)
(fx-init-input! canvas)

(define q
  (fx-fullscreen!
   '((precision mediump float)
     (uniform float u_time)
     (uniform vec2 u_resolution)
     (uniform vec2 u_mouse)
     (define (main) void
       (local vec2 p (/ gl_FragCoord.xy u_resolution))
       (local float v (+ (sin (+ (* p.x (fl 10)) u_time))
                         (sin (- (* p.y (fl 8)) u_time))
                         (sin (+ (* (+ p.x p.y) (fl 6)) u_time))
                         (sin (- (* (distance p u_mouse) (fl 20))
                                 (* u_time (fl 2))))))
       (set! gl_FragColor
             (vec4 (+ (fl 0 50) (* (fl 0 50) (sin (* v (fl 3 14)))))
                   (+ (fl 0 50) (* (fl 0 50) (sin (+ (* v (fl 3 14)) (fl 2)))))
                   (+ (fl 0 50) (* (fl 0 50) (sin (+ (* v (fl 3 14)) (fl 4)))))
                   (fl 1)))))))

(fx-loop!
 (lambda (t dt)
   (fx-fullscreen-use! q t)
   (fx-uniform! (fx-quad-program q) 'u_mouse
                (/ (pointer-x) (fx-width))
                (- 1 (/ (pointer-y) (fx-height))))
   (fx-fullscreen-draw! q)))
