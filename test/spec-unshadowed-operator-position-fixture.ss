;; expect: 5.0
;; Fixture for test/spec-product-unshadowed-operator-position.mjs.  The
;; positive twin of defect-spec-shadowed-primitive-in-operator-position:
;; here fl+ in operator position is NOT shadowed, so it is the primitive
;; and both recursive arguments are genuine flonum expressions.  Both
;; parameters must stay f64.  A fix for the shadowed case that declines
;; every primitive head, not only lexically bound ones, would demote
;; them; the printed value stays 5.0 either way, which is why the .mjs
;; reads the compiler product and not the output.
(import (rnrs))
(define (zq a b) (if (fl<? b 0.0) (zq (fl+ a 0.0) (fl+ b 1.0)) a))
(display (zq 5.0 -1.0))
