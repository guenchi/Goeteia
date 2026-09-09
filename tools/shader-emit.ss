;; expect: #t
;; Print every shader this tree can emit, so that something outside
;; Scheme can hand them to a real GLSL compiler.
;;
;; This is not a test -- it is the first half of
;; test/shader-compile.mjs, which runs it and compiles what it prints.
;;
;; It lives in tools/ and not in test/ because in test/ a program's whole
;; stdout IS its verdict: this one printed twenty-two shaders where the
;; runner expected `#t`, and failed on all three targets.  That is the
;; same trap that made a test's own stand-down announcement fail it
;; earlier the same night, in a second form: a directory where printing
;; is the answer is no place for a program whose job is to print.
;;
;; The last entry is deliberately invalid.  Without it, "everything
;; compiled" could also mean the compiler was never reached: the page
;; verifier's GL answers true to every shader it is shown, so a run
;; against a stub would look identical to a run against a compiler.
(import (rnrs) (gfx glsl)
        (gfx fx) (gfx ibl) (gfx post) (gfx sprite) (gfx scene)
        (gfx gltf) (gfx mesh) (gfx particles))

(define (render dialect forms)
  (cond ((not forms) "")
        ((string=? dialect "es300") (glsl300-fs->string forms))
        (else (glsl->string forms))))
(define (render-vs dialect forms)
  (cond ((not forms) "")
        ((string=? dialect "es300") (glsl300-vs->string forms))
        (else (glsl->string forms))))

(define (emit! lib rows)
  (for-each
   (lambda (row)
     (let ((name (car row)) (dialect (symbol->string (cadr row)))
           (vs (caddr row)) (fs (cadddr row)))
       (display "=== ") (display lib) (display "/") (display name)
       (display " ") (display dialect) (newline)
       (display "--- vertex ---") (newline)
       (display (render-vs dialect vs)) (newline)
       (display "--- fragment ---") (newline)
       (display (render dialect fs)) (newline)))
   rows))

(emit! "fx" (fx-quad-shaders))
(emit! "ibl" (ibl-shaders))
(emit! "post" (post-shaders))
(emit! "sprite" (sprite-shaders))
(emit! "scene" (scene-shaders))
(emit! "gltf" (gltf-shaders))
(emit! "mesh" (mesh-shaders))
(emit! "particles" (particles-shaders))

;; the control: a vertex shader a real compiler must refuse
(display "=== control/known-bad es100") (newline)
(display "--- vertex ---") (newline)
(display (glsl->string '((define (main) void (local int n (fl 1 0)))))) (newline)
(display "--- fragment ---") (newline)
(newline)
(display #t)
