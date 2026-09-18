;; expect: #t
;; A string in a shader form is emitted VERBATIM, so the DSL is optional
;; and nothing says so.
;;
;; expr->glsl's first clause is ((string? e) e), at lib/gfx/glsl.ss:130.
;; A whole function body can therefore be written as raw GLSL text and
;; it emits exactly what a structured form emits: the same names, the
;; same calls, the same tokens, the same compiler result, the same
;; pixels. Every other check in this tree reads the emitted text or
;; the compiled program, so not one of them can tell the two apart.
;; That was measured, not assumed -- a raw string and its structured
;; equivalent both produced the identical `return not_defined(1.0);`.
;;
;; glsl-check does not close it either. It validates SHAPES: four
;; probes were all accepted -- a garbage string, a string calling an
;; undefined function, a structured call to an undefined function, and
;; a structured reference to an undeclared variable.
;;
;; So the convention "write shader bodies as forms, not as text" had
;; nothing behind it, which is the shape that left three examples
;; uncompilable for seven days: a rule everybody follows, that nothing
;; can notice being broken, is a rule that is one careless import away
;; from being over.
;;
;; WHAT THE CONVENTION ACTUALLY IS, measured across every shader
;; accessor in lib/gfx rather than guessed: 132 strings appear in
;; shader forms and every one of them is a NUMBER. Zero are
;; expressions. So the rule is not "no strings" -- that would be false
;; today and would have to be argued for -- it is the sharper and
;; already-true one: a string in a shader form is a numeric literal.
;;
;; Numbers are the one case where a string buys something the DSL
;; cannot give: (fl 0 5) cannot express 0.05, because Scheme reads 05
;; as 5. There is a width argument for that, and 132 places chose the
;; string instead. Whether they should is a separate question from
;; whether a body may be written as text, and this cell answers only
;; the second.
(import (rnrs) (gfx surface) (gfx fx) (gfx ibl) (gfx post) (gfx sprite)
        (gfx scene) (gfx mat) (gfx lod) (gfx gltf) (gfx mesh)
        (gfx particles))

;; A GLSL numeric literal and nothing else: an optional sign, digits,
;; an optional fraction, an optional exponent, end of string.
;;
;; It is a real scanner and not a test for "only digits and dots and
;; signs", because that spelling accepts "1.0-2.0" -- an expression
;; whose characters all look numeric. The loose version would have
;; admitted exactly the thing this cell exists to refuse.
(define (numeric-literal? s)
  (define n (string-length s))
  (define (digits i)
    (let loop ((i i) (any #f))
      (if (and (< i n) (char-numeric? (string-ref s i)))
          (loop (+ i 1) #t)
          (and any i))))
  (define (exponent i)
    (if (>= i n)
        i
        (and (memv (string-ref s i) '(#\e #\E))
             (let ((i (+ i 1)))
               (let ((i (if (and (< i n) (memv (string-ref s i) '(#\+ #\-)))
                            (+ i 1)
                            i)))
                 (digits i))))))
  (define (fraction i)
    (if (and (< i n) (char=? (string-ref s i) #\.))
        (digits (+ i 1))
        i))
  (let* ((i (if (and (> n 0) (memv (string-ref s 0) '(#\+ #\-))) 1 0))
         (i (digits i))
         (i (and i (fraction i)))
         (i (and i (exponent i))))
    (and i (= i n))))

(define offenders '())
(define string-count 0)

(define (walk who x)
  (cond ((string? x)
         (set! string-count (+ string-count 1))
         (unless (numeric-literal? x)
           (set! offenders (cons (cons who x) offenders))))
        ((pair? x) (walk who (car x)) (walk who (cdr x)))))

(define (scan-rows who rows)
  (for-each (lambda (r) (walk who (cdr r))) rows))

(walk "mat" (mat-shader-functions))
(walk "lod" (lod-shader-functions))
(walk "surface" (surface-shader-functions))
(scan-rows "fx" (fx-quad-shaders))
(scan-rows "ibl" (ibl-shaders))
(scan-rows "post" (post-shaders))
(scan-rows "sprite" (sprite-shaders))
(scan-rows "scene" (scene-shaders))
(scan-rows "gltf" (gltf-shaders))
(scan-rows "mesh" (mesh-shaders))
(scan-rows "particles" (particles-shaders))

;; THE CONTROL COMES FIRST, because everything below is satisfied by a
;; walk that reached nothing. The scanner must accept the spellings
;; this tree really contains, refuse a raw GLSL body, and -- the row
;; that the loose version of this predicate would have failed -- refuse
;; an expression made only of numeric-looking characters.
(define (control-ok?)
  (and (numeric-literal? "64.0")
       (numeric-literal? "2.51")
       (numeric-literal? "0.03")
       (numeric-literal? "9.0")
       (numeric-literal? "-1.5")
       (numeric-literal? "1e5")
       (numeric-literal? "1.5E-3")
       (not (numeric-literal? "abs(bottom.y-eye.y)"))
       (not (numeric-literal? "distance(bottom,eye)*clamp(s,0.0,1.0)"))
       (not (numeric-literal? "1.0-2.0"))
       (not (numeric-literal? "bottom.y<height?1.0:0.0"))
       (not (numeric-literal? ""))
       (not (numeric-literal? "."))
       (not (numeric-literal? "x"))))

;; And the walk must have reached the forms at all. A renamed accessor
;; or a shape this walker does not descend into would leave offenders
;; empty for a reason that has nothing to do with the convention.
;; The floor is well under the 132 measured, so adding or removing a
;; literal does not touch this row.
(define (reach-ok?) (> string-count 100))

(cond ((not (control-ok?))
       (display "CONTROL FAILED: the numeric-literal scanner does not ")
       (display "separate a number from an expression, so the verdict ")
       (display "below means nothing")
       (newline))
      ((not (reach-ok?))
       (display "the walk found only ")
       (display string-count)
       (display " strings in shader forms; it is not reaching them, ")
       (display "and an empty result reads as success")
       (newline))
      ((not (null? offenders))
       (display "these shader forms contain a string that is not a ")
       (display "numeric literal, so they emit raw GLSL that no check ")
       (display "in this tree can read:")
       (newline)
       (for-each (lambda (o)
                   (display "  ") (display (car o)) (display ": ")
                   (write (cdr o)) (newline))
                 offenders))
      (else (display #t)))
