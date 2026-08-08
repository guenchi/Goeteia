;; A full-screen gradient whose colour walks with time: six vertices,
;; one draw call per frame, one time uniform, and no input of any kind.
(import (rnrs) (web js) (web dom) (gfx glsl) (gfx fx))

(fx-init! (get-element-by-id "c"))

(define q
  (fx-fullscreen!
   '((precision mediump float)
     (uniform float u_time)
     (uniform vec2 u_resolution)
     (define (main) void
       (local vec2 p (/ gl_FragCoord.xy u_resolution))
       (set! gl_FragColor
             (vec4 (+ (fl 0 50) (* (fl 0 50) (sin (+ p.x u_time))))
                   (+ (fl 0 50) (* (fl 0 50) (sin (+ p.y (* u_time (fl 0 70))))))
                   (+ (fl 0 60) (* (fl 0 40) (sin (* u_time (fl 0 30)))))
                   (fl 1)))))))

(fx-loop!
 (lambda (t dt)
   (fx-fullscreen-use! q t)
   (fx-fullscreen-draw! q)))
