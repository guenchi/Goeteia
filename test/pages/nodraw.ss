;; A live GL context, a linked program, uploaded vertices and a frame
;; loop -- but every frame only clears and re-uploads.
(import (rnrs) (web js) (web dom) (gfx gl) (gfx glsl) (gfx fx))

(fx-init! (get-element-by-id "c"))

(define p
  (fx-program!
   '((attribute vec2 a_pos)
     (define (main) void
       (set! gl_Position (vec4 a_pos (fl 0) (fl 1)))))
   '((precision mediump float)
     (define (main) void
       (set! gl_FragColor (vec4 (fl 1) (fl 0) (fl 0) (fl 1)))))))

(define buf (fx-buffer!))
(define vbase (fx-alloc! 24))

(%mem-f32-set! vbase -1.0)
(%mem-f32-set! (+ vbase 4) -1.0)
(%mem-f32-set! (+ vbase 8) 3.0)
(%mem-f32-set! (+ vbase 12) -1.0)
(%mem-f32-set! (+ vbase 16) -1.0)
(%mem-f32-set! (+ vbase 20) 3.0)

(fx-loop!
 (lambda (t dt)
   (cmd-clear! 0.05 0.06 0.10 1.0)
   (fx-use! p buf)
   (cmd-buffer-data! vbase 24)))
