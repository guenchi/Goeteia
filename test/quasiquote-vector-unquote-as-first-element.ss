;; expect: #(unquote (+ 1 1))
;; A vector whose first element is the SYMBOL unquote is not an unquote
;; form -- only a list (unquote x) is.  R6RS processes the vector's
;; elements, and neither `unquote' nor (+ 1 1) is an element-level
;; unquote, so both stay literal.  The vector->list delegation gets this
;; wrong: vector->list turns it into the list (unquote (+ 1 1)), which
;; the list expander reads AS an unquote form and evaluates, then
;; list->vector chokes -- a compile error on valid input.  Chez: the
;; vector unchanged.
(import (rnrs))
(display `#(unquote (+ 1 1)))
