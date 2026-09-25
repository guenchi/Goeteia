;; expect: #t
;; stats-gain-xp! stops when a level's cost can no longer be taken from
;; the experience total.
;;
;; THE DEFECT.  The level-up loop pays for each level with (- xp need)
;; and relies on xp going down.  Once the total is large enough that
;; the cost is below its flonum resolution, the subtraction is
;; absorbed: (- 1e308 1000) is 1e308, measured 2026-09-25.  The loop
;; then buys a level, calls the hook, and comes round to the same
;; total, forever.  It was found with (stats-gain-xp! s 1e308) against
;; a curve costing 1000 at every level: the call did not return.  A
;; gain of 1e308 passes the entry guard, which asks only that the
;; amount be finite as a flonum.
;;
;; THE RULE.  Before buying a level, the total after paying must be
;; smaller than the total before: (= (- xp need) xp) refuses, naming
;; the level, the total and the cost.  In exact arithmetic that is
;; never true, so an exact total paying an exact cost is never refused
;; by it; in flonum arithmetic it is exactly the absorbed case; with
;; one operand a flonum the prelude works in flonums, whichever side
;; it is on, and the same test applies.  What the rule promises is
;; that every purchase it admits leaves a smaller stored total.  It may
;; refuse a mixed-arithmetic purchase whose mathematical result would
;; have been smaller but whose stored result is not (an exact 2^54 + 1
;; paying 1.0), which is the honest reading of what the store can hold.
;;
;; WHAT IS COMMITTED WHEN IT REFUSES.  The gain has been added to the
;; total, and every level bought before the refused one was paid for
;; and had its hook called; the refused level is not bought and its
;; hook is not called.  Nothing is rolled back: the total is real, the
;; curve just has no next step on it.
;;
;; WHAT THE RULE DOES NOT DO.  It does not bound the number of levels a
;; call buys.  An exact total of 2^1023 against a cost of 1000 is
;; admitted, is never absorbed, and buys 2^1023 / 1000 levels one at a
;; time, calling the hook for each -- work proportional to what was
;; asked for, as the documentation says.  The row marked CONTROL pins
;; that decision as far as a finite run can: it lets the loop run 4096
;; purchases, which rules out the caps someone would reach for, and no
;; finite run rules out every cap.
;;
;; HOW A HANG IS READ WITHOUT HANGING.  The curve counts how often it
;; is asked and raises its own error past a limit.  On the tree with
;; the defect the loop reaches that error; on the tree with the rule
;; the refusal comes from stats-gain-xp!.  The two are told apart by
;; the condition's who, so the cell is red on the defect rather than
;; stalled until the harness's timeout.
(import (rnrs) (gam stats))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))

;; expt is not bound here; powers of two by multiplication.  NOT by
;; bitwise-arithmetic-shift-left, which wraps silently past the fixnum
;; range on the wasm target (2^32 read as 1, measured 2026-09-25).
(define (two^ n) (let loop ((i 0) (x 1)) (if (= i n) x (loop (+ i 1) (* x 2)))))

;; What a call did: (returned v), or (raised who irritants).
(define (try thunk)
  (guard (e (#t (list 'raised (condition-who e) (condition-irritants e))))
    (list 'returned (thunk))))
(define (outcome r) (if (eq? (car r) 'raised) (list 'raised (cadr r)) r))
(define (irritant-present? r v)
  (and (eq? (car r) 'raised)
       (let any ((l (caddr r)))
         (and (pair? l) (or (and (real? (car l)) (= (car l) v)) (any (cdr l)))))))

;; A curve that answers cost-of at every level and refuses to be asked
;; more than limit times.
(define (counting-curve-limited cost-of limit)
  (let ((asked 0))
    (lambda (level)
      (set! asked (+ asked 1))
      (when (> asked limit)
        (error 'curve-asked-too-often "the level loop did not stop" asked))
      (cost-of level))))
(define (counting-curve cost) (counting-curve-limited (lambda (level) cost) 64))

(define (stats-with cost) (make-stats '((hp 10 0)) (counting-curve cost)))

;; 1e308 against a cost of 1000: the absorbed case.
(let* ((s (stats-with 1000))
       (r (try (lambda () (stats-gain-xp! s 1e308)))))
  (want "a gain whose total absorbs the cost is refused by stats-gain-xp!"
        (outcome r) '(raised stats-gain-xp!))
  (want "and the refusal names the cost" (irritant-present? r 1000) #t)
  (want "and the level" (irritant-present? r 1) #t)
  (want "and the total" (irritant-present? r 1e308) #t)
  (want "the gain itself is committed: the total is stored" (stats-xp s) 1e308)
  (want "and no level was bought" (stats-level s) 1))

;; Mixed operands, the flonum on either side.  (- 2^54 1.0) rounds
;; back to 2^54, measured 2026-09-25.
(let* ((s (stats-with 1))
       (r (try (lambda () (stats-gain-xp! s 18014398509481984.0)))))
  (want "a flonum total whose resolution is coarser than an exact cost is refused"
        (outcome r) '(raised stats-gain-xp!)))
(let* ((s (stats-with 1.0))
       (r (try (lambda () (stats-gain-xp! s (two^ 54))))))
  (want "an exact total paying a flonum cost is subtracted in flonums, and refused when absorbed"
        (outcome r) '(raised stats-gain-xp!)))

;; An exact total is never absorbed: 2^-1100 paying exactly 2^-1100
;; buys one level and stops with nothing left.  (The rule must not be
;; written as a comparison of inexact projections, which would see 0.0
;; on both sides here and refuse.)
(let* ((tiny (/ 1 (two^ 1100)))
       (s (stats-with tiny)))
  (want "an exact total pays an exact cost of the same size and buys one level"
        (try (lambda () (stats-gain-xp! s tiny))) '(returned 1))
  (want "leaving nothing" (stats-xp s) 0))

;; Refused after an earlier purchase: level 1 costs 1e300, which the
;; total can pay (1e308 - 1e300 is smaller than 1e308), level 2 costs
;; 1000, which is absorbed.  The first purchase stands, its hook was
;; called, the second is refused by name and its hook is not called.
(let* ((hooked '())
       (s (make-stats '((hp 10 0))
                      (counting-curve-limited (lambda (level) (if (= level 1) 1e300 1000)) 64)
                      (lambda (s level) (set! hooked (cons level hooked)))))
       (r (try (lambda () (stats-gain-xp! s 1e308)))))
  (want "a purchase refused after an earlier one is refused by stats-gain-xp!"
        (outcome r) '(raised stats-gain-xp!))
  (want "naming the level it could not buy" (irritant-present? r 2) #t)
  (want "the earlier purchase stands, paid for"
        (list (stats-level s) (= (stats-xp s) (- 1e308 1e300))) '(2 #t))
  (want "and the hook ran for the bought level only" hooked '(2)))

;; CONTROL, pinning the decision not to bound the loop: an exact 2^1023
;; against a cost of 1000 is admitted and keeps buying levels; here the
;; counting curve is what stops it, after 4096 purchases, on both trees.
(let* ((s (make-stats '((hp 10 0)) (counting-curve-limited (lambda (level) 1000) 4096)))
       (r (try (lambda () (stats-gain-xp! s (two^ 1023))))))
  (want "CONTROL an exact total beyond flonum resolution is admitted and the loop runs"
        (outcome r) '(raised curve-asked-too-often))
  (want "CONTROL it ran 4096 purchases" (stats-level s) 4097)
  (want "CONTROL and every level it bought was paid for"
        (= (stats-xp s) (- (two^ 1023) (* 1000 4096))) #t))

;; CONTROL: an ordinary gain, unchanged by the rule.  500 buys nothing
;; at 1000; 600 more buys one level, calls the hook once, leaves 100.
(let* ((hooked '())
       (s (make-stats '((hp 10 0)) (lambda (level) 1000)
                      (lambda (s level) (set! hooked (cons level hooked))))))
  (want "CONTROL 500 against 1000 buys nothing" (stats-gain-xp! s 500) 0)
  (want "CONTROL 600 more buys one level" (stats-gain-xp! s 600) 1)
  (want "CONTROL the hook saw level 2 once" hooked '(2))
  (want "CONTROL 100 is left" (stats-xp s) 100))

(display (if (null? fails) #t (reverse fails)))
