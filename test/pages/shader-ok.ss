;; Control: a page whose shader a real compiler accepts.
(import (rnrs) (web js) (web dom) (gfx glsl) (gfx fx))
(fx-init! (get-element-by-id "c"))
(define q
  (fx-fullscreen!
   '((precision mediump float)
     (uniform float u_time)
     (define (main) void
       (set! gl_FragColor (vec4 (sin u_time) (fl 0 5) (fl 0 5) (fl 1)))))))
(fx-loop! (lambda (t dt) (fx-fullscreen-use! q t) (fx-fullscreen-draw! q)))
