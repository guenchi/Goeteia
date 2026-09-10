;; expect: (1 2 3 4)
;; RED ON PURPOSE: unquote-splicing's expansion builds with a bare cons
;; around the append slice 3 protected; see
;; defect-c02-synth-quasiquote-cons.  Chez answers (1 2 3 4); here an
;; illegal cast.
(import (rnrs))
(define (cons a b) (quote mine))
(display `(1 ,@(list 2 3) 4))
