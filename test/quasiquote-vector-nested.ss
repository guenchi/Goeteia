;; expect: #(0 #(1 2))
;; A vector quasiquote nested inside another.  Delegation recurses, so
;; the inner vector is processed too.  Red on the unfixed expander,
;; where the inner vector keeps its literal (unquote (+ 1 1)).
(import (rnrs))
(display `#(0 #(1 ,(+ 1 1))))
