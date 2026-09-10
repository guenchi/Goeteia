;; expect: #t
;; What this cell is the only evidence for: (gam fields) pays for the
;; time a field actually lived -- no more, and none of it dropped --
;; and its shape has round ends rather than square ones.
;;
;; The two halves are separate defects with the same symptom.  A field
;; that credits the whole of an oversized step pays for time after it
;; expired; a field that drops its final short period pays for less
;; than it lived.  Both read on screen as "the numbers are a bit off".
(import (rnrs) (gam fields))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))
(define (raises? thunk)
  (guard (e ((error? e) #t) (else #f)) (begin (thunk) #f)))

;; A collector that records every settlement, so a cell can talk about
;; how many there were as well as what they came to.
(define (collector)
  (let ((seen '()))
    (lambda msg
      (if (null? msg)
          (reverse seen)
          (set! seen (cons (cadr msg) seen))))))

;; Every quantity below is a sum of halves and quarters, which binary
;; floating point holds exactly.  A conservation claim stated in
;; tenths would be a claim about rounding instead.

;; One step longer than the whole life pays for the life, not the step.
;; Without the clamp this is 100 times too much, and the field has
;; already expired for the whole of the overshoot.
(let ((f (make-field 'fire 0.0 0.0 1.0 0.0 0.0 1.0 10.0 0.5))
      (c (collector)))
  (field-step! f 100.0 c)
  (want 'an-oversized-step-pays-for-the-life-only (apply + (c)) 10.0)
  (want 'and-the-field-is-spent (field-life f) 0.0))

;; The tail of a life is settled however short it is.  Three quarters
;; of a second of life on a half-second period: one full period, then a
;; quarter that is not a period at all and must still be paid.
(let ((f (make-field 'fire 0.0 0.0 1.0 0.0 0.0 0.75 4.0 0.5))
      (c (collector)))
  (field-step! f 0.5 c)
  (want 'the-first-full-period-settles (c) '(2.0))
  (field-step! f 0.5 c)
  (want 'the-short-tail-is-not-dropped (c) '(2.0 1.0))
  (want 'and-it-adds-up-to-the-life (apply + (c)) 3.0))

;; Stated as the conservation it is: however the caller chops up the
;; time, the total paid is the life times the rate.  Three different
;; step patterns over the same field.
(define (total-paid steps)
  (let ((f (make-field 'fire 0.0 0.0 1.0 0.0 0.0 1.0 8.0 0.25))
        (c (collector)))
    (for-each (lambda (dt) (field-step! f dt c)) steps)
    (apply + (c))))
(want 'one-big-step (total-paid '(4.0)) 8.0)
(want 'four-quarters (total-paid '(0.25 0.25 0.25 0.25)) 8.0)
(want 'ragged-steps (total-paid '(0.125 0.5 0.125 0.25 2.0)) 8.0)

;; Settling happens when a period has accumulated, not on every step.
(let ((f (make-field 'fire 0.0 0.0 1.0 0.0 0.0 4.0 1.0 1.0))
      (c (collector)))
  (field-step! f 0.5 c)
  (want 'half-a-period-settles-nothing (c) '())
  (field-step! f 0.5 c)
  (want 'the-second-half-completes-it (c) '(1.0)))

;; A spent field is quiet rather than an error, because the caller is
;; stepping a list it has not pruned yet.
(let ((f (make-field 'fire 0.0 0.0 1.0 0.0 0.0 1.0 1.0 1.0))
      (c (collector)))
  (field-step! f 2.0 c)
  (field-step! f 2.0 c)
  (want 'a-spent-field-settles-once-and-stays-quiet (length (c)) 1))

;; Shape.  A capsule of half-length 2 along the x axis, radius 1.
(define cap (make-field 'burn 0.0 0.0 1.0 2.0 0.0 1.0 1.0 1.0))
(want 'the-centre-is-inside (field-contains? cap 0.0 0.0) #t)
(want 'along-the-axis-within-the-half-length (field-contains? cap 2.0 0.0) #t)
(want 'the-end-cap-reaches-one-further (field-contains? cap 3.0 0.0) #t)
(want 'and-no-further (field-contains? cap 3.5 0.0) #f)
(want 'the-side-is-one-wide (field-contains? cap 0.0 1.0) #t)
(want 'and-no-wider (field-contains? cap 0.0 1.5) #f)
;; The corner is the case that tells a capsule from a box: the end cap
;; is round, so a point one unit out and one unit sideways from the end
;; of the axis is OUTSIDE, though a box of the same extents holds it.
(want 'the-ends-are-round-not-square (field-contains? cap 3.0 1.0) #f)

;; Half-length zero is a circle, and it is the same test with the
;; capsule's length removed rather than a separate path.
(define disc (make-field 'burn 0.0 0.0 2.0 0.0 0.0 1.0 1.0 1.0))
(want 'a-disc-holds-its-radius (field-contains? disc 2.0 0.0) #t)
(want 'and-not-beyond (field-contains? disc 2.5 0.0) #f)
(want 'a-disc-is-the-same-in-every-direction (field-contains? disc 0.0 2.0) #t)

;; Yaw turns the capsule.  The quarter turn is written as a literal
;; rather than computed: this compiler has no atan, and a cell that
;; needed one would be testing the prelude instead of this library.
;; At a quarter turn the long axis lies along
;; z, so the points that were inside along x are outside and the ones
;; that were outside along z are inside.  Stated as memberships rather
;; than distances, because the quarter turn is not exact in binary.
(define turned (make-field 'burn 0.0 0.0 1.0 2.0 1.5707963267948966 1.0 1.0 1.0))
(want 'the-long-axis-turned-with-it (field-contains? turned 0.0 2.5) #t)
(want 'and-the-short-one-turned-too (field-contains? turned 2.5 0.0) #f)

;; The field is placed, not always at the origin.
(define moved (make-field 'burn 10.0 -4.0 1.0 0.0 0.0 1.0 1.0 1.0))
(want 'containment-is-relative-to-the-field
      (list (field-contains? moved 10.0 -4.0) (field-contains? moved 0.0 0.0))
      '(#t #f))

;; Refusals.
(want 'zero-radius-refused
      (raises? (lambda () (make-field 'x 0.0 0.0 0.0 0.0 0.0 1.0 1.0 1.0))) #t)
(want 'negative-half-length-refused
      (raises? (lambda () (make-field 'x 0.0 0.0 1.0 -1.0 0.0 1.0 1.0 1.0))) #t)
(want 'zero-duration-refused
      (raises? (lambda () (make-field 'x 0.0 0.0 1.0 0.0 0.0 0.0 1.0 1.0))) #t)
(want 'negative-elapsed-refused
      (raises? (lambda () (field-step! disc -1.0 (lambda (f a) a)))) #t)
(want 'a-non-procedure-settler-refused
      (raises? (lambda () (field-step! disc 1.0 'not-a-procedure))) #t)

;; ONE MUTANT IS LEFT ALIVE, AND THE REASON IS NOT THIS LIBRARY.
;; Widening the containment test from `radius^2 >= d^2' to `d^2 <
;; radius^2' -- excluding the boundary instead of including it --
;; survives every cell above, and it is not for want of a cell aimed at
;; it.  The boundary is not reachable.  field-contains? turns the point
;; into the field's frame with cos and sin, and this prelude's cos is a
;; truncated series: cos(0) is 0.999999999993, not 1.0.  So a point
;; placed exactly on the rim measures a hair inside it, and no argument
;; either comparison would treat differently can be constructed from
;; the outside.
;;
;; docs/limits.md already carries this under `Trigonometric accuracy',
;; with the 1e-9 bound and the way it degrades with amplitude.  The
;; measured residual at the peaks is 6.02e-12, well inside that.  So
;; the prelude is behaving as documented and the survivor is a fact
;; about what this cell can observe, not a defect hiding from it.
;;
;; The mutants that ARE killed here: the clamp on an oversized step,
;; expiry settling the tail, the round end cap, the yaw, and the
;; field's placement.

(display (if (null? fails) #t (reverse fails)))
