;; expect: (a 1 2 b)
;; R6RS (unquote e1 e2 ...) in element position splices its evaluated
;; operands, like ,@(list e1 e2 ...).  Pre-existing defect in the LIST
;; expander: it handles only single-operand (unquote e), so this comes
;; back holding the literal (unquote 1 2).  Red on HEAD, no vector
;; involved; the sequence walker the vector fix needs is where this
;; belongs, so fixing vectors correctly fixes this too -- a cell so it
;; is not fixed-and-unwatched.  Chez: (a 1 2 b).
(import (rnrs))
(display `(a (unquote 1 2) b))
