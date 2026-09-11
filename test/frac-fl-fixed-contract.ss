;; expect: #t
;; The finite, in-range contract of fl->fixed, pinned to the oracle
;; (archive/goeteia-float-printer-oracle.ss).  Green now; the two
;; discriminators 2.675->"2.68" and 0.995->"1.00" are one flonum
;; rounding up from the exact-decimal value and must not be "fixed".
(import (rnrs) (web frac))
(define (ck x d want) (string=? (fl->fixed x d) want))
(display
 (and (ck 2.675 2 "2.68")  (ck 0.995 2 "1.00")
      (ck 9.996 2 "10.00") (ck 9.995 2 "9.99")
      (ck -0.001 2 "0.00") (ck 1.005 2 "1.00")
      (ck 0.5 0 "0")       (ck 1.5 0 "2")
      (ck 0.125 2 "0.12")  (ck -2.5 1 "-2.5")))
