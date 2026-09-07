;; expect: 12
;; A macro whose expansion defines a helper at top level and calls it.
;; Each expansion introduces its own helper -- the name carries that
;; expansion's marks -- so using the macro twice is two helpers, not one
;; name defined twice, and neither expansion sees the other's.  This is
;; what hygiene means at the top level; it is pinned so that the
;; duplicate-definition check and dead-code elimination keep keying
;; introduced definitions by the same identity references resolve to.
;; (A later top-level form cannot name `helper' at all: the introduced
;; binding is not visible to user code, as R6RS says.)
(import (rnrs))
(define-syntax with-helper
  (syntax-rules ()
    ((_ v) (begin (define (helper) v) (display (helper))))))
(with-helper 1)
(with-helper 2)
(newline)
