;; expect: #t
;; R6RS names goeteia did not bind (ledger R20, batch R20d):
;; rationalize: the simplest rational within a distance of x, exact or
;; inexact as its arguments are.
;;
;; Each row is an expression and the answer Chez 10 gives for it in (rnrs),
;; compared as a value.  A row that raises here answers `raised'.  An
;; enum-set is compared through enum-set->list, whose order is the
;; universe's.
;;
;; ON THE TREE BEFORE THE CHANGE this file does not compile: the names are
;; unbound.
(import (rnrs))


(define fails '())
(define (want row got expect)
  (unless (equal? got expect)
    (set! fails (cons (list row 'got got 'want expect) fails))))

(want 1
      (guard (c (#t 'raised))
        (list (rationalize 3/10 1/10) (rationalize -3/10 1/10) (rationalize 1/4 1/12) (rationalize 1/3 0) (rationalize 3 1) (rationalize -3 1) (rationalize 5/2 1/2)))
      '(1/3 -1/3 1/3 1/3 2 -2 2))
(want 2
      (guard (c (#t 'raised))
        (list (rationalize 0 1) (rationalize 1/2 1/2) (rationalize 22/7 1/1000) (rationalize 355/113 1/10000000) (rationalize 7 0)))
      '(0 0 22/7 355/113 7))
(want 3
      (guard (c (#t 'raised))
        (list (rationalize .3 1/10) (rationalize 3/10 .1) (exact? (rationalize .3 1/10)) (exact? (rationalize 3/10 1/10))))
      '(0.3333333333333333 0.3333333333333333 #f #t))

(display (if (null? fails) #t (reverse fails)))
