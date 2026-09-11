;; expect: user(1 user)
;; REGRESSION GUARD. Written as a red witness at 0f70663, when except
;; was advisory and the program's definition was refused as a duplicate
;; at the flat top level. Pins both halves at once: the program's own
;; calls reach its append, and the append quasiquote's expansion
;; introduces still reaches the prelude's, since the compiler wrote that
;; reference. Chez answers user then (1 user). Its sibling c02-excluded-
;; list-to-vector-and-quasiquote guards the same property for the
;; list->vector the vector walker introduces. A reviewer's fixture for
;; the import-discipline slice (design section 27).
(import (except (rnrs) append))
(define (append . xs) (quote user))
(display (append (quote (1)) (quote (2))))
(display `(,@(quote (1)) ,(append (quote (2)) (quote (3)))))
