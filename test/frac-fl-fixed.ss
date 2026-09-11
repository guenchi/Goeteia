;; expect: #t
;; fl->fixed(x,d) spells the double nearest x*10^d with exactly d
;; decimals, flonum/fixnum only, so a frame site can afford it.  The
;; expectations are pinned to archive/goeteia-float-printer-oracle.ss,
;; computed two ways there; the two rows that differ from the exact-
;; decimal rounding are the CONTRACT, not a bug:
;;   2.675 -> "2.68"  because the nearest double to 2.675*100 is
;;                    267.50000000000002842..., which rounds up;
;;   0.995 -> "1.00"  the same shape.  Anything that "fixes" these two
;;                    to "2.67"/"0.99" has changed the contract.
;; Half-to-even (no flround primitive; built from flfloor): 0.5 -> "0",
;; 1.5 -> "2", 0.125 -> "0.12".  A negative value whose digits round
;; away prints unsigned: -0.001 -> "0.00".
;;
;; Out of contract -- non-finite, or a scaled value past the fixnum
;; edge -- falls back to number->string (design 8.4): d decimals are
;; not then guaranteed, but it neither crashes nor lies.  Those rows are
;; red until the fallback lands; today fl->fixed of 1e300 traps.
(import (rnrs) (web frac))
(define (ck x d want) (string=? (fl->fixed x d) want))
(display
 (and (ck 2.675 2 "2.68")  (ck 0.995 2 "1.00")
      (ck 9.996 2 "10.00") (ck 9.995 2 "9.99")
      (ck -0.001 2 "0.00") (ck 1.005 2 "1.00")
      (ck 0.5 0 "0")       (ck 1.5 0 "2")
      (ck 0.125 2 "0.12")  (ck -2.5 1 "-2.5")
      ;; fallback: not finite, and past the fixnum edge -> number->string
      (string=? (fl->fixed +inf.0 2) (number->string +inf.0))
      (string=? (fl->fixed +nan.0 2) (number->string +nan.0))
      (string=? (fl->fixed 1e300 2) (number->string 1e300))))
