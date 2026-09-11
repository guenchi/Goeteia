;; expect: (1 2 3 4)
;; REGRESSION GUARD. Written as a red witness at 8514ae1, when the
;; expansion of unquote-splicing built with a bare cons around an append
;; that was already protected. Same property as defect-c02-synth-
;; quasiquote-cons, on the splicing path. Chez answers (1 2 3 4).
(import (except (rnrs) cons))
(define (cons a b) (quote mine))
(display `(1 ,@(list 2 3) 4))
