;; expect: (1 2)
;; The fixture test/c02-product-trampoline.mjs reads the trampoline
;; classification from.  prim-tail's tail is a primitive application,
;; so it is not bouncy and its callers skip the TR wrapper; proc-tail's
;; tail calls a procedure parameter, so it is.  Both are recursive so
;; neither is inlined away at -O2 -- without that, the reading is of
;; nothing, and the first version of this fixture read exactly that.
(import (rnrs))
(define (prim-tail x n) (if (= n 0) (car x) (prim-tail x (- n 1))))
(define (proc-tail f x n) (if (= n 0) (f x) (proc-tail f x (- n 1))))
(display (list (prim-tail '(1) 3) (proc-tail (lambda (v) (car v)) '(2) 3)))
