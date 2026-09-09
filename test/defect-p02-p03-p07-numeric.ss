;; expect: #t
;; RED ON PURPOSE: three numeric predicates and procedures that answer
;; differently from the language they implement.  Each expectation was
;; taken from Chez on this machine, not from the review's wording --
;; ⚠️ a report describes the broken half; the correct half has to come
;; from somewhere outside this tree.
;;
;;   P02  memv / assv compare with eq?, so equal numbers that are not
;;        the same object are not found.  eqv? on two flonums is a
;;        comparison of value, and memv is defined in terms of eqv?.
;;   P03  floor and truncate hand a ratnum straight back.  They are
;;        supposed to return an integer.
;;   P07  integer? and rational? answer #t for infinities.  An infinity
;;        is not a rational number and is not an integer.
;;
;; ⭐ Every red has a green control beside it that a lazy fix would
;; break, and the controls are chosen to be the ones that CAN break:
;;
;;   P02  a symbol and a char must still be found -- a "fix" that
;;        replaced eq? with = would stop finding anything that is not a
;;        number, and = would also raise on them rather than answer #f.
;;   P03  ⭐ the NEGATIVE cases, where floor and truncate disagree:
;;        (floor -7/2) is -4 and (truncate -7/2) is -3.  A fix that
;;        rounds toward zero for both passes every positive case and
;;        fails here, which is why the positive cases alone would not
;;        be a test.
;;   P07  2.0 is an integer and 2.5 is rational; a fix that answered #f
;;        for every flonum would satisfy the reds above.
(import (rnrs))
(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))

;; ---- P02 ----
(want 'p02-memv-flonum   (if (memv 2.0 (list 1.0 2.0 3.0)) #t #f) #t)
(want 'p02-memv-ratnum   (if (memv 1/3 (list 1/2 1/3)) #t #f) #t)
;; ⚠️ Compared whole, NOT (cdr (assv ...)).  assv answers #f when the
;; defect is present, and (cdr #f) is an illegal cast -- a wasm trap,
;; which `guard` cannot catch and which takes the whole file's stdout
;; with it.  ⭐ A cell that dereferences its result crashes exactly when
;; the thing it tests is broken, and then reports nothing at all: the
;; first draft of this file printed "illegal cast" and no verdicts,
;; from a defect none of these cells actually trips on its own.
(want 'p02-assv-flonum   (assv 2.0 (list (cons 1.0 'n) (cons 2.0 'y))) (cons 2.0 'y))
(want 'p02-CONTROL-sym   (if (memv 'b (list 'a 'b)) #t #f) #t)
(want 'p02-CONTROL-char  (if (memv #\b (list #\a #\b)) #t #f) #t)
(want 'p02-CONTROL-absent (memv 9.0 (list 1.0 2.0)) #f)

;; ---- P03 ----
(want 'p03-floor-pos     (floor 7/2) 3)
(want 'p03-truncate-pos  (truncate 7/2) 3)
(want 'p03-floor-NEG     (floor -7/2) -4)
(want 'p03-truncate-NEG  (truncate -7/2) -3)
(want 'p03-CONTROL-int   (list (floor 3) (truncate 3)) (list 3 3))
(want 'p03-CONTROL-flo   (list (floor -3.5) (truncate -3.5)) (list -4.0 -3.0))

;; ---- P07 ----
(want 'p07-integer-inf   (integer? (/ 1.0 0.0)) #f)
(want 'p07-rational-inf  (rational? (/ 1.0 0.0)) #f)
(want 'p07-integer-ninf  (integer? (/ -1.0 0.0)) #f)
(want 'p07-integer-nan   (integer? (/ 0.0 0.0)) #f)
(want 'p07-rational-nan  (rational? (/ 0.0 0.0)) #f)
(want 'p07-CONTROL-2.0   (integer? 2.0) #t)
(want 'p07-CONTROL-2.5   (list (integer? 2.5) (rational? 2.5)) (list #f #t))

(if (null? fails) (display #t) (begin (display fails) (newline)))
