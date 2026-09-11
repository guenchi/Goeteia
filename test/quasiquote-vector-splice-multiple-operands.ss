;; expect: #(1 2 3 5)
;; The vector form of multi-operand unquote-splicing: each operand's
;; list is spliced into the vector's element sequence.  Red on the
;; unfixed expander, which leaves the whole splice form literal.
;; Chez: #(1 2 3 5).
(import (rnrs))
(display `#(1 (unquote-splicing (list 2) (list 3)) 5))
