;; expect: 14.75
;; The fixture test/c02-product-fn-specs.mjs reads compiler products
;; from.  run's accumulator must be classified f64 and its counter must
;; not; norm is called with non-literal arguments from a loop so it
;; survives inlining and DCE.  Its own printed value is also pinned, so
;; the fixture is a cell in its own right.
(import (rnrs))
(define (norm x y) (fl+ (fl* x x) (fl* y y)))
(define (run n acc)
  (if (= n 0) acc (run (- n 1) (fl+ acc (norm (fixnum->flonum n) 0.5)))))
(display (run 3 0.0))
