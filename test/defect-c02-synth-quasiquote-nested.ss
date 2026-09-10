;; expect: (1 `(2 ,(3 4)))
;; RED ON PURPOSE: a nested quasiquote rebuilds the inner template with a
;; bare cons at every level; see defect-c02-synth-quasiquote-cons.  Chez
;; answers (1 `(2 ,(3 4))).
(import (rnrs))
(define (cons a b) (quote mine))
(display `(1 `(2 ,(3 ,(+ 1 3)))))
