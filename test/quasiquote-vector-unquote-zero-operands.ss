;; expect: #()
;; The vector zero-operand boundary: (unquote) splices nothing, so the
;; single-element vector becomes empty.  Red on the unfixed expander.
;; Chez: #().
(import (rnrs))
(display `#((unquote)))
