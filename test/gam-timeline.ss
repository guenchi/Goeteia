;; expect: #t
;; What this cell is the only evidence for: (gam timeline) fires each
;; payload once, at the tick its deadline falls in, and orders equal
;; deadlines by when they were scheduled.
;;
;; Every reading below is a value this file computes; the expectation
;; comes from the rules written at the top of lib/gam/timeline.ss, not
;; from running the library and writing down what it said.
(import (rnrs) (gam timeline))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))

;; Equal deadlines come back in scheduling order.  A comparison written
;; one notch tighter in the insertion walk reverses this and nothing
;; else, which is why the payloads are distinguishable.
(let ((t (make-timeline)))
  (timeline-schedule! t 1.0 'first)
  (timeline-schedule! t 1.0 'second)
  (timeline-schedule! t 1.0 'third)
  (want 'equal-deadlines-keep-insertion-order
        (timeline-tick! t 1.0) '(first second third)))

;; A deadline reached by a different arithmetic path than the clock is
;; still due.  0.1 + 0.2 is not 0.3 in binary floating point, so this
;; payload's deadline is a few ulps past a clock that was advanced by a
;; single 0.3 -- without the absolute slack the library documents, it
;; would sit in the queue for a whole further tick.
(let ((t (make-timeline)))
  (timeline-schedule! t (+ 0.1 0.2) 'drifted)
  (want 'deadline-past-clock-by-one-ulp-is-due
        (timeline-tick! t 0.3) '(drifted))
  (want 'and-does-not-come-back
        (timeline-tick! t 10.0) '()))

;; Firing is once, and a tick that reaches nothing answers nothing
;; rather than the queue.
(let ((t (make-timeline)))
  (timeline-schedule! t 5.0 'later)
  (want 'not-yet (timeline-tick! t 1.0) '())
  (want 'still-queued (timeline-empty? t) #f)
  (want 'now (timeline-tick! t 4.0) '(later))
  (want 'queue-drained (timeline-empty? t) #t))

;; Order across unequal deadlines is by deadline, not by scheduling,
;; and one tick that passes several deadlines answers all of them in
;; deadline order.
(let ((t (make-timeline)))
  (timeline-schedule! t 3.0 'c)
  (timeline-schedule! t 1.0 'a)
  (timeline-schedule! t 2.0 'b)
  (want 'one-tick-past-three-deadlines
        (timeline-tick! t 3.0) '(a b c)))

;; A zero delay means the next tick, not this instant: scheduling does
;; not run anything, so the payload is still queued afterwards.
(let ((t (make-timeline)))
  (timeline-schedule! t 0 'immediate)
  (want 'zero-delay-is-queued-not-run (timeline-empty? t) #f)
  (want 'zero-delay-fires-on-the-next-tick
        (timeline-tick! t 0.0) '(immediate)))

;; Refusals.  A negative delay and a negative elapsed time are errors
;; rather than clamped values, so each of these must raise.
(define (raises? thunk)
  (guard (e ((error? e) #t) (else #f)) (begin (thunk) #f)))

(let ((t (make-timeline)))
  (want 'negative-delay-refused
        (raises? (lambda () (timeline-schedule! t -1.0 'x))) #t)
  (want 'negative-elapsed-refused
        (raises? (lambda () (timeline-tick! t -1.0))) #t)
  (want 'not-a-timeline-refused
        (raises? (lambda () (timeline-tick! (vector 'gam-timeline 0.0) 1.0))) #t))

;; timeline-clear! drops the queue without advancing the clock.
(let ((t (make-timeline)))
  (timeline-schedule! t 1.0 'doomed)
  (timeline-tick! t 0.5)
  (timeline-clear! t)
  (want 'cleared-queue-is-empty (timeline-empty? t) #t)
  (want 'cleared-payload-never-fires (timeline-tick! t 100.0) '())
  (want 'clear-does-not-move-the-clock (timeline-time t) 100.5))

;; ONE MUTANT IS LEFT ALIVE ON PURPOSE.  Widening the due test from
;; (< limit deadline) to (<= limit deadline) survives every cell here.
;; The two differ only on a deadline exactly one slack ahead of the
;; clock, so killing it means writing 1e-8 into this file -- and the
;; library documents that constant as the caller's to reconsider if it
;; counts time in other units.  A cell that pinned it would go red on a
;; legitimate change and say nothing about a wrong one.  The mutants
;; that ARE killed here: the insertion walk's comparison, the slack
;; itself set to zero, clear! touching the clock, the negative-delay
;; refusal, and tick answering its queue unreversed.

(display (if (null? fails) #t (reverse fails)))
