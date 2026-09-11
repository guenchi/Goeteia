;; expect: #(1 2)
;; The vector form of multi-operand unquote: the vector's sequence walker
;; must splice (unquote 1 2)'s operands.  Red on the unfixed expander,
;; which keeps the literal (unquote 1 2).  Chez: #(1 2).
(import (rnrs))
(display `#((unquote 1 2)))
