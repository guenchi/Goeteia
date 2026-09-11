;; expect: 256.0
;; The recursive companion to defect-spec-shadowed-parameter.  There the
;; shadow hides an EXACT local in an f64 slot and the wrong answer is an
;; illegal cast; here every value the shadowed local ever holds is a real
;; flonum, so the program is correct on every host -- what the shadow
;; costs is a specialisation, not a value.
;;
;; g is recursive so it survives inlining and is a real specialisation
;; candidate.  Both routes into g pass a BARE shadowed symbol: f calls it
;; as (g a 3) where a is the let's 2.0, and g's own tail calls it as
;; (g x ...) where x is the let's (fl* x x).  The demotion subtracts the
;; shadowed locals at each call, so it cannot see that either argument is
;; a flonum, and g's x is demoted from f64.  Measured with the compiler
;; product instrument (test/lib/c02-products.sc --specs g f): before the
;; subtraction fn-specs is ((g #t #f) (f #t)); after it, g is absent.
;;
;; That demotion is the accepted tradeoff -- demote-only is safe by
;; construction, and the alternative, reading the shadowing local's own
;; initialiser type to keep the specialisation, is more machinery for a
;; narrow case.  This cell pins the SAFETY half of it: whatever the
;; classification, the recursive shadowed program still answers 256.0.
;; Do not remove the subtraction to reclaim the lost spec; that reopens
;; the illegal cast defect-spec-shadowed-parameter guards.
(import (rnrs))
(define (g x n)
  (if (= n 0)
      x
      (let ((x (fl* x x)))
        (g x (- n 1)))))
(define (f a) (let ((a 2.0)) (g a 3)))
(display (f 5.0))
