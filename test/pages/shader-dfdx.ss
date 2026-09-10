;; Valid GLSL in ES 3.00 and not in ES 1.00: dFdx is core in the former
;; and needs GL_OES_standard_derivatives enabled in the latter.  This
;; page emits an ES 1.00 shader and does not enable it.
(import (rnrs) (web js) (web dom) (gfx glsl) (gfx fx))
(fx-init! (get-element-by-id "c"))
(define q
  (fx-fullscreen!
   '((precision mediump float)
     (uniform vec2 u_resolution)
     (define (main) void
       (local vec2 p (/ gl_FragCoord.xy u_resolution))
       (local float d (dFdx p.x))
       (set! gl_FragColor (vec4 d (fl 0 5) (fl 0 5) (fl 1)))))))
(fx-loop! (lambda (t dt) (fx-fullscreen-use! q t) (fx-fullscreen-draw! q)))
