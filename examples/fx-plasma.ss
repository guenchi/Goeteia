;; A fragment-shader effect in ~15 lines of harness: (web fx) wires
;; the program from its own glsl forms (u_time and u_resolution are
;; set automatically because the fragment declares them), and the
;; mouse feeds one extra uniform through the polled input layer.
(import (rnrs) (web js) (web dom) (web glsl) (web fx))

(define canvas (get-element-by-id "c"))
(fx-init! canvas)
(fx-init-input!)

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
