;; expect: (a)
;; The zero-operand boundary of the same rule: (unquote) splices nothing.
;; Pre-existing list-expander defect; HEAD keeps the literal (unquote).
;; Chez: (a).
(import (rnrs))
(display `(a (unquote)))
