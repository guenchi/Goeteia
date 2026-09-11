;; expect: (1 2 3 5)
;; R6RS (unquote-splicing e1 e2 ...) splices EACH operand's list.  The
;; quiet-data-loss case found in review: the old splicing arm read only
;; the first operand, (cadr (car t)), and dropped the rest -- not a
;; visible unexpanded form like the other defects, but silent loss, so
;; it needs a cell of its own.  On HEAD this is (1 2 5); the 3 vanishes.
;; Fully evaluated, so a printed oracle is safe.  Chez: (1 2 3 5).
(import (rnrs))
(display `(1 (unquote-splicing (list 2) (list 3)) 5))
