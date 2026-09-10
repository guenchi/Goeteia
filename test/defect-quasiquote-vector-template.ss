;; expect: #(1 2)
;; RED ON PURPOSE: a vector quasiquote template is not processed.  R6RS
;; says `#(1 ,x) is a vector whose second element is the value of x;
;; here the template comes out holding the literal (unquote (+ 1 1)).
;; No program definition is involved; found while writing the capture
;; cells for quasiquote.  Chez answers #(1 2).
(import (rnrs))
(display `#(1 ,(+ 1 1)))
