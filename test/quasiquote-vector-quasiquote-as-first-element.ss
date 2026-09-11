;; expect: #(quasiquote 2)
;; A vector whose first element is the symbol quasiquote is not a nested
;; quasiquote form; its elements are processed at the current level, so
;; the ,(+ 1 1) second element is unquoted to 2 and the quasiquote
;; symbol stays literal.  The delegation reads vector->list as a nested
;; quasiquote, raises the level, and leaves the unquote unevaluated.
(import (rnrs))
(display `#(quasiquote ,(+ 1 1)))
