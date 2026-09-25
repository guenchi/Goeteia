;; expect: #t
;; A sum of accepted inputs that enters a (gam ...) library's state is
;; finite as a flonum, or the call that would store it is refused with
;; the state untouched.
;;
;; Every entry guard in these libraries asks that its input be finite
;; as a flonum.  Two inputs that each pass can add up to something that
;; does not: 1e308 and 1e308 make +inf.0.  Until 2026-09-25 nothing
;; looked at the sum, so a second gain of 1e308 stored an infinite
;; experience total, a second tick of 1e308 stored an infinite clock,
;; and a deadline made from an infinite clock was never due.  From
;; there every comparison is false and the library answers wrongly
;; without saying so.
;;
;; THE RULE.  Compute the sum, refuse unless (= 0 (- y y)) for its
;; inexact value y, and only then store; on refusal nothing has
;; changed, and the refusal names the current value and the input.
;; It covers the quantities these libraries hold as flonum-domain
;; values: an experience total, a clock, a deadline, a field's
;; settlement accumulator.  It does not cover counts -- items held,
;; levels reached -- which are exact integers of any size by design.
;;
;; UNTOUCHED MEANS THE WHOLE OBJECT.  A refused tick leaves the queue
;; as it was, deadlines included, and a refused schedule leaves the
;; clock; so the timeline rows fill the queue first and read it back
;; after each refusal by ticking to what was queued.
;;
;; THE FIELD ROW needs a construction, because the accumulator is
;; bounded by the field's life and the step is clamped to it.  With
;; M = 1.7976931348623157e308 and A = 2^969, (- M A) rounds back to M
;; and (+ (* 3 A) M) overflows (both measured 2026-09-25 on the wasm
;; target).  Three steps of A leave the life at M and 3A accumulated
;; below a period of 4A; a step of M then adds M to 3A.  Before the
;; rule that made the accumulator +inf.0 and, the life having reached
;; zero, settled an infinite amount.  The accumulator has no reader, so
;; that it was left at 3A is read through the settlement threshold:
;; with delta = 2^918, the flonum spacing at 3A, a step of A - delta
;; reaches 4A - delta and settles nothing, and a step of delta reaches
;; 4A and settles exactly 4A.  An accumulator reset to zero would not
;; settle on the second step; one left larger would settle on the
;; first.
(import (rnrs) (gam stats) (gam timeline) (gam fields))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))

;; powers of two by multiplication, not by shifting (see the note in
;; defect-stats-gain-xp-loops-on-an-absorbed-cost.ss)
(define (two^ n) (let loop ((i 0) (x 1)) (if (= i n) x (loop (+ i 1) (* x 2)))))
(define (finite? x) (let ((y (inexact x))) (= 0 (- y y))))

(define (try thunk)
  (guard (e (#t (list 'raised (condition-who e) (condition-irritants e))))
    (list 'returned (thunk))))
(define (outcome r) (if (eq? (car r) 'raised) (list 'raised (cadr r)) r))
(define (irritant-present? r v)
  (and (eq? (car r) 'raised)
       (let any ((l (caddr r)))
         (and (pair? l) (or (and (real? (car l)) (= (car l) v)) (any (cdr l)))))))

;; ---- experience total ----
;; The curve answers +inf.0 -- a cap, which no total can buy -- and
;; counts its calls so that a loop which does not stop is read as an
;; error from the curve rather than as a stall.  Before the rule the
;; second gain stored +inf.0; (< +inf.0 +inf.0) is false, so the cap
;; was bought, the total became NaN, and the loop went on.
(define (capped-curve)
  (let ((asked 0))
    (lambda (level)
      (set! asked (+ asked 1))
      (when (> asked 64) (error 'curve-asked-too-often "the level loop did not stop" asked))
      +inf.0)))
(let ((s (make-stats '((hp 10 0)) (capped-curve))))
  (want "a first gain of 1e308 is accepted" (try (lambda () (stats-gain-xp! s 1e308))) '(returned 0))
  (let ((r (try (lambda () (stats-gain-xp! s 1e308)))))
    (want "a second gain of 1e308 is refused before anything is stored" (outcome r) '(raised stats-gain-xp!))
    (want "naming the total and the gain" (irritant-present? r 1e308) #t))
  (want "the total is still 1e308" (stats-xp s) 1e308)
  (want "and no level was bought" (stats-level s) 1)
  (want "a gain that keeps the total finite is then accepted"
        (try (lambda () (stats-gain-xp! s 1e307))) '(returned 0))
  (want "and the total moved" (stats-xp s) 1.1e308))
;; The same with no curve at all: the sum is guarded before the curve
;; is consulted, not as part of the level loop.
(let ((s (make-stats '((hp 10 0)))))
  (stats-gain-xp! s 1e308)
  (want "without a curve, a second gain of 1e308 is refused"
        (outcome (try (lambda () (stats-gain-xp! s 1e308)))) '(raised stats-gain-xp!))
  (want "and the total is still 1e308" (stats-xp s) 1e308))

;; ---- clock and deadlines ----
(let ((t (make-timeline)))
  (want "a first tick of 1e308 is accepted" (timeline-tick! t 1e308) '())
  (timeline-schedule! t 1e307 'early)
  (want "something is queued before the refusals" (timeline-empty? t) #f)
  (let ((r (try (lambda () (timeline-tick! t 1e308)))))
    (want "a second tick of 1e308 is refused" (outcome r) '(raised timeline-tick!))
    (want "naming the clock and the elapsed time" (irritant-present? r 1e308) #t))
  (want "the clock still reads 1e308" (timeline-time t) 1e308)
  (want "and the queue was not touched by the refused tick" (timeline-empty? t) #f)
  (let ((r (try (lambda () (timeline-schedule! t 1e308 'never)))))
    (want "a delay whose deadline would be infinite is refused" (outcome r) '(raised timeline-schedule!))
    (want "naming the clock and the delay" (irritant-present? r 1e308) #t))
  (want "the clock still reads 1e308 after the refused schedule" (timeline-time t) 1e308)
  (want "a delay with a finite deadline is accepted"
        (car (try (lambda () (timeline-schedule! t 1e307 'soon)))) 'returned)
  (want "and the queue holds what was queued before the refusals and after, in order, and nothing else"
        (timeline-tick! t 1e307) '(early soon))
  (want "leaving the queue empty" (timeline-empty? t) #t))

;; ---- a field's settlement accumulator ----
(define M 1.7976931348623157e308)
(define A (two^ 969))
(define delta (two^ 918))
(want "the construction holds here: M - A rounds back to M" (= (- M A) M) #t)
(want "the construction holds here: 3A + M is not finite" (finite? (+ (* 3 A) M)) #f)
(let* ((settled '())
       (settle (lambda (f owed) (set! settled (cons owed settled))))
       (f (make-field 'pillar 0.0 0.0 1.0 0.0 0.0 M 1 (* 4 A))))
  (field-step! f A settle) (field-step! f A settle) (field-step! f A settle)
  (want "three steps of A settle nothing" settled '())
  (want "and leave the life at M" (field-life f) M)
  (let ((r (try (lambda () (field-step! f M settle)))))
    (want "a step that would overflow the accumulator is refused" (outcome r) '(raised field-step!))
    (want "naming the elapsed time" (irritant-present? r M) #t))
  (want "nothing was settled by the refused step" settled '())
  (want "and the life is untouched" (field-life f) M)
  (field-step! f (- A delta) settle)
  (want "a step to 4A - delta settles nothing: the accumulator was left at 3A, not more" settled '())
  (field-step! f delta settle)
  (want "a step of delta settles exactly 4A: the accumulator was left at 3A, not less"
        (and (= (length settled) 1) (= (car settled) (* 4 A))) #t))

;; CONTROL an ordinary field, unchanged: a step past the period settles
;; the accumulated time times the rate.
(let* ((settled '())
       (f (make-field 'pillar 0.0 0.0 1.0 0.0 0.0 1.0 2.0 0.25)))
  (field-step! f 0.3 (lambda (f owed) (set! settled (cons owed settled))))
  (want "CONTROL 0.3 of life at rate 2 settles 0.6" settled '(0.6)))

(display (if (null? fails) #t (reverse fails)))
