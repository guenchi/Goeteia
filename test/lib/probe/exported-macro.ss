;; A fixture, not a test: a library whose exported name is produced by
;; a macro rather than written out.  See
;; test/defect-exported-macro-definition.ss.
(library (probe exported-macro)
  (export made-by-macro written-out)
  (import (rnrs))
  (define-syntax define-adder
    (syntax-rules ()
      ((_ name k) (define (name y) (+ y k)))))
  (define-adder made-by-macro 1)
  (define (written-out y) (+ y 2)))
