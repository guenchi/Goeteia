;; expect: (a #(2) b)
;; A vector quasiquote as an element of a list quasiquote.  The list
;; walker reaches the vector element and delegates.  Red on the unfixed
;; expander, where the vector element keeps its literal unquote.
(import (rnrs))
(display `(a #(,(+ 1 1)) b))
