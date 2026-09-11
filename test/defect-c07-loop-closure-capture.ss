;; expect: 3
;; C07 (2026-09-06 review; written as a red witness at a52af3b, green
;; since): on the JS target, closures made inside a loop share the
;; loop's final parameter.
;;
;; REGRESSION GUARD, and red on ONE target only -- which is the sharpest
;; thing about it.  Saving `(lambda () i)` for i = 0, 1, 2 and summing
;; the results after the loop gives 3 on wasm and 9 on JS: on JS the
;; loop parameter is declared once outside the `for` and assigned each
;; time round, so all three closures read the last value.
;;
;; The two backends disagreeing about what a program means is the one
;; thing this tree says must never happen -- run-tests.sh compares their
;; emitted text byte for byte for exactly that reason.  A cell that ran
;; only on wasm would be green, and the green would mean nothing.
;;
;; Reported location: src/js-backend.ss:740-757.
(import (rnrs))
(define saved '())
(let loop ((i 0))
  (when (< i 3)
    (set! saved (cons (lambda () i) saved))
    (loop (+ i 1))))
(display (fold-left + 0 (map (lambda (f) (f)) saved)))
