;; expect: 5
;; The third shape in the shadowed-primitive family, and the one that
;; survived the first two fixes: a primitive shadowed by a PARAMETER of
;; a NON-CANDIDATE function.  g is variadic, so it is not a
;; specialisation candidate; an earlier fix recorded the enclosing
;; function's name only for candidates, which left its parameters out of
;; the scope the operator-position check consults, so fl+ -- g's own
;; parameter -- was read as the primitive again for every non-candidate.
;; zq's parameter a then specialised to f64 and took the exact 5: an
;; illegal cast.  Measured on the committed tree before this fix; the
;; fix records the name unconditionally, and the candidate lookup still
;; answers empty f64names for a non-candidate, so only the scope is
;; recovered.
;;
;; A value cell, not a product cell, because a wrong answer is a
;; miscompile; the sibling defect-spec-shadowed-primitive-by-parameter
;; covers the candidate case and passed while this one still failed,
;; which is why this shape needed its own cell.  Chez answers 5.
(import (rnrs))
(define (zq a b) (if (fl<? b 0.0) (zq (fl+ a 0.0) (fl+ b 1.0)) a))
(define (g fl+ . rest) (zq (fl+ (car rest) (car rest)) 0.0))
(display (g (lambda (p q) 5) 1.0))
