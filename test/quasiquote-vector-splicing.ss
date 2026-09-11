;; expect: #(1 2 3 4)
;; Vector quasiquote with unquote-splicing.  The vector->list delegation
;; gets splicing for free from the list machinery's append.  Red on the
;; unfixed expander, where the template comes back holding the literal
;; (unquote-splicing (list 2 3)).
(import (rnrs))
(display `#(1 ,@(list 2 3) 4))
