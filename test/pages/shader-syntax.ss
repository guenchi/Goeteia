;; A deliberate syntax error: the symbol passes through the GLSL DSL
;; verbatim, so the emitted text is malformed and a real compiler must
;; refuse it with a line number.
(import (rnrs) (web js) (web dom) (gfx glsl) (gfx fx))
(fx-init! (get-element-by-id "c"))
(define q
  (fx-fullscreen!
   '((precision mediump float)
     (uniform float u_time)
     (define (main) void
       (local float d @@)
       (set! gl_FragColor (vec4 d (fl 0 5) (fl 0 5) (fl 1)))))))
(fx-loop! (lambda (t dt) (fx-fullscreen-use! q t) (fx-fullscreen-draw! q)))
