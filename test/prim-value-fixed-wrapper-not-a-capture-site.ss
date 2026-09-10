;; expect: 7
;; GREEN, and kept as the reading it records: the wrapper for a
;; FIXED-arity primitive taken as a value is built with (cons name ps)
;; at the meta level, not as a written call, so a program's cons does
;; not reach it.  Chez and every host answer 7.  If this goes red the
;; fixed-arity wrapper acquired a written head.
(import (rnrs))
(define (cons a b) (quote mine))
(display ((lambda (f) (f (quote (7)))) car))
