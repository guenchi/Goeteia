;; expect: #t
;; RED ON PURPOSE: the same defect as
;; test/defect-macro-toplevel-var-mark.ss, on a definition whose
;; initialiser is a constant.
;;
;; Two files because each fails at compile time, and a compile error
;; takes the whole file's verdict with it -- one file would report one
;; symptom and say nothing about the other.
;;
;; The message differs, and the difference is worth keeping: a constant
;; initialiser is pure, so the definition is eligible for dead-code
;; elimination, and what comes back names the marked variable as simply
;; absent rather than as assigned-to.
;;
;;   unbound variable: #{mc <mark>}
;;
;; See the other file for the shape this cell must NOT return to.
;; Demanding that a user-written `mc` see this definition is demanding
;; that hygiene be broken.
(import (rnrs))
(define-syntax m
  (syntax-rules ()
    ((_) (begin (define mc 1)
                (display (= 1 mc))))))
(m)
