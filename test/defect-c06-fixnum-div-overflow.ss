;; expect: #t
;; C06 (2026-09-06 review, still live 2026-09-09): the most negative
;; fixnum divided by -1 does not become a bignum.
;;
;; RED ON PURPOSE.  Today every target answers #f.  The quotient of
;; -536870912 and -1 is 536870912, which is one past the top of the
;; fixnum range, and the fast path wraps it back around instead of
;; promoting.
;;
;; Written as an equality rather than by printing the value: a
;; bignum's printed form is a second thing that could be wrong, and a
;; cell that compared text would fail for two possible reasons at once.
;;
;; Reported location: src/compiler.ss:2337,2615, src/js-backend.ss:1236.
(import (rnrs))
(display (= (quotient -536870912 -1) 536870912))
