;; expect: #t
;; (gfx glsl): two ways a literal turns into GLSL that no longer means
;; what was written, both silent.
;;
;; `--` is the decrement operator, not two negations.  The unary minus
;; branch concatenates its operand's text, so a negative literal under
;; a negation emits `(--1.0)`, which is a decrement applied to a
;; literal and is not valid GLSL.  Hand-written `(- (fl -1 0))` hits it
;; today; it becomes an ordinary path the moment anything substitutes a
;; negative value into `(- x)`.
;;
;; `(fl 1 -2)` emits `1.-2`.  The fraction digits are printed without
;; being looked at, so a negative count produces a token that is not a
;; number at all.
;;
;; Neither is caught anywhere: the page verifier's GL is a stub whose
;; compileShader does nothing and whose getShaderParameter returns true
;; (rt/verify.mjs:313-316), so an invalid shader passes every page test
;; with draws counted and frames animated.
(import (rnrs) (gfx glsl))

(define (has-sub? hay needle)
  (let ((h (string-length hay)) (n (string-length needle)))
    (let loop ((i 0))
      (cond ((> (+ i n) h) #f)
            ((string=? (substring hay i (+ i n)) needle) #t)
            (else (loop (+ i 1)))))))

(define (emit f)
  (guard (e (#t 'ERR))
    (glsl->string (list (list 'define '(main) 'void (list 'set! 'gl_Position f))))))

;; a refusal must name the form and say what about it is wrong, so a
;; caller can act on it without reading the library.
;;
;; This calls glsl->string itself rather than going through emit: emit
;; guards and answers 'ERR, so a refused? written on top of it never
;; reaches its own handler and is CONSTANTLY false -- it would report
;; the defect as unfixed no matter what the library did.  A dead
;; assertion and a real failure print the same single FAIL line, and
;; the dead one cannot be argued with, only measured.
(define (refused? f word)
  (guard (e ((error? e) (has-sub? (condition-message e) word))
            (else #f))
    (begin
      (glsl->string (list (list 'define '(main) 'void (list 'set! 'gl_Position f))))
      #f)))

(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))

;; ---- the defects ----
(let ((s (emit '(- (fl -1 0)))))
  (check "a negated negative float literal does not emit the decrement operator"
         (and (string? s) (not (has-sub? s "--")))))
(let ((s (emit '(- -1))))
  (check "a negated negative int literal does not emit the decrement operator"
         (and (string? s) (not (has-sub? s "--")))))
(check "a negative fraction-digit count is refused, saying so"
       (refused? '(fl 1 -2) "fl"))

;; ---- the other half: what must NOT change ----
;; A one-character fix here is easy to widen into "put a space after
;; every unary minus", which would rewrite the emitted bytes of every
;; shader in the tree for the sake of two cases.  These pin the shape
;; that must stay exactly as it is.
(check "an ordinary negation is emitted unchanged, with no separator"
       (equal? (emit '(- (fl 1 0)))
               "void main() { gl_Position = (-1.0); } "))
(check "a negation of a name is emitted unchanged"
       (equal? (emit '(- u_k))
               "void main() { gl_Position = (-u_k); } "))
(check "an ordinary float literal is untouched"
       (equal? (emit '(fl 1 0))
               "void main() { gl_Position = 1.0; } "))
(check "a bare negative literal, not under a negation, is still fine"
       (equal? (emit '(fl -1 0))
               "void main() { gl_Position = -1.0; } "))
;; arities the printer accepts today, which the payload check must not
;; start refusing: (fl i), (fl i d) and (fl i d w) all print 1.0 here
(check "the three accepted fl arities still print"
       (and (equal? (emit '(fl 1)) "void main() { gl_Position = 1.0; } ")
            (equal? (emit '(fl 1 0)) "void main() { gl_Position = 1.0; } ")
            (equal? (emit '(fl 1 0 3)) "void main() { gl_Position = 1.0; } ")))
(display (= failed 0))
