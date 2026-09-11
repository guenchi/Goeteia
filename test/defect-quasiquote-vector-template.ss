;; expect: #(1 2)
;; REGRESSION GUARD. Written as a red witness at 13beb41, when a vector
;; quasiquote template was not processed at all and the template came
;; out holding the literal (unquote (+ 1 1)). Fixed by ec42978, which
;; made both quasiquote expanders one walker; measured red on ec42978's
;; parent and green on ec42978. Pins R6RS's reading of `#(1 ,x): a
;; vector whose second element is the value of x. Chez answers #(1 2).
(import (rnrs))
(display `#(1 ,(+ 1 1)))
