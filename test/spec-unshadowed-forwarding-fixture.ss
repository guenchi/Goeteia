;; expect: 5.0
;; Fixture for test/spec-product-unshadowed-forwarding.mjs.  A recursive
;; function that forwards both of its f64 parameters with NO shadowing
;; anywhere: a is passed on bare, b is passed on inside an fl+.  Both
;; must stay f64.  Its printed value is pinned too, so the fixture is a
;; cell in its own right, but the value is not what it guards -- a lost
;; specialisation leaves the value correct and only the compiler product
;; changes, which is why the .mjs reads *fn-specs* directly.
(import (rnrs))
(define (zq a b) (if (fl<? b 0.0) (zq a (fl+ b 1.0)) a))
(display (zq 5.0 -1.0))
