;; expect: #t
;; What this cell is the only evidence for: (gam window) reports the
;; slice of an active interval a step passed THROUGH, not merely the
;; one it landed in, and marks each thing once until it is reset.
;;
;; The distinction in the first sentence is the whole reason the
;; library exists.  A caller that asks window-live? once per frame
;; misses an interval entirely whenever the frame is longer than the
;; interval -- which is what a dropped frame is -- and the symptom is
;; an action that silently does nothing, at random, under load.
(import (rnrs) (gam window))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))
(define (raises? thunk)
  (guard (e ((error? e) #t) (else #f)) (begin (thunk) #f)))

;; A step that jumps clean over the live interval still reports it.
;; Here the window is live from 0.4 to 0.6 of a one-second action and
;; the whole second passes in one step: the clock ends past the
;; interval, so window-live? is false, and window-span must not be.
(let ((w (make-window 1.0 0.4 0.6)))
  (window-step! w 1.0)
  (want 'a-step-over-the-whole-window-is-not-live (window-live? w) #f)
  (want 'but-the-step-passed-through-it (window-span w) (cons 0.4 0.6)))

;; The span is the step's own interval intersected with the live one,
;; so a step that ends inside reports up to where it got, and the next
;; step continues from there rather than repeating what was covered.
(let ((w (make-window 1.0 0.4 0.6)))
  (window-step! w 0.5)
  (want 'entering-reports-from-the-opening (window-span w) (cons 0.4 0.5))
  (window-step! w 0.3)
  (want 'leaving-reports-up-to-the-closing (window-span w) (cons 0.5 0.6))
  (want 'and-then-nothing (begin (window-step! w 0.1) (window-span w)) #f))

;; A step entirely before or after the interval touches nothing.
(let ((w (make-window 1.0 0.4 0.6)))
  (window-step! w 0.2)
  (want 'before-the-window-is-no-span (window-span w) #f))

;; An interval of a single instant is a thing a caller may describe,
;; and the step that crosses it reports the empty slice rather than
;; losing it.  This is the case a from<to precondition would delete.
(let ((w (make-window 1.0 0.5 0.5)))
  (window-step! w 1.0)
  (want 'an-instant-window-is-reported (window-span w) (cons 0.5 0.5)))

;; Time stops at the duration instead of running past it.
(let ((w (make-window 2.0 0.0 1.0)))
  (window-step! w 5.0)
  (want 'the-clock-stops-at-the-duration (window-time w) 2.0)
  (want 'and-says-so (window-done? w) #t)
  (window-step! w 5.0)
  (want 'stepping-a-finished-window-does-not-grow-it (window-time w) 2.0))

;; Marking answers #t once per thing, and equal? is the identity: two
;; separately built keys naming the same target count as one target.
(let ((w (make-window 1.0 0.0 1.0)))
  (want 'first-mark-is-true (window-mark! w 'goblin) #t)
  (want 'second-mark-is-false (window-mark! w 'goblin) #f)
  (want 'a-different-thing-marks (window-mark! w 'orc) #t)
  (want 'equal-keys-are-one-thing (window-mark! w (list 1 2)) #t)
  (want 'even-when-built-separately (window-mark! w (list 1 2)) #f)
  (want 'marked-reports-without-marking (window-marked? w 'goblin) #t)
  (want 'and-does-not-invent (window-marked? w 'troll) #f)
  (want 'the-ledger-holds-three (length (window-marks w)) 3))

;; Resetting is how the same description is used again, so it clears
;; the ledger as well as the clock.  A second use that remembered the
;; first one's targets would pass straight through them, which on
;; screen is indistinguishable from a missed hit.
(let ((w (make-window 1.0 0.0 1.0)))
  (window-step! w 0.5)
  (window-mark! w 'goblin)
  (window-reset! w)
  (want 'reset-clears-the-clock (window-time w) 0.0)
  (want 'reset-clears-the-ledger (window-marks w) '())
  (want 'so-the-same-target-marks-again (window-mark! w 'goblin) #t)
  (want 'and-the-window-is-live-again (window-done? w) #f))

;; Refusals: a duration must be positive, and the fractions must be
;; ordered and within the action.
(want 'zero-duration-refused (raises? (lambda () (make-window 0 0.0 1.0))) #t)
(want 'negative-duration-refused (raises? (lambda () (make-window -1.0 0.0 1.0))) #t)
(want 'to-before-from-refused (raises? (lambda () (make-window 1.0 0.6 0.4))) #t)
(want 'from-past-one-refused (raises? (lambda () (make-window 1.0 1.5 1.5))) #t)
(want 'negative-step-refused
      (raises? (lambda () (window-step! (make-window 1.0 0.0 1.0) -0.1))) #t)
(want 'not-a-window-refused (raises? (lambda () (window-time (vector 'gam-window)))) #t)

(display (if (null? fails) #t (reverse fails)))
