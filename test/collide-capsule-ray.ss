;; expect: #t
;; What this cell is the only evidence for: the four procedures
;; (gfx collide) gained tonight -- segment-segment-closest,
;; capsule-capsule-contact, ray-heightfield and screen-ray.
;;
;; They were exported, documented, and called by nothing.  Removing
;; them from the library left test/collide.ss and
;; test/collide-circle2d.ss both answering #t, which is what an unused
;; export looks like from the suite: not a failure, an absence.
;;
;; The numbers below are chosen so that the right answer is one a
;; reader can work out on paper -- axis-aligned segments at whole
;; coordinates, a flat ground, an identity-like projection -- because
;; an expectation copied from a run of the code under test is not an
;; expectation.
(import (rnrs) (gfx collide) (gfx mat))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))
(define (raises? thunk)
  (guard (e ((error? e) #t) (else #f)) (begin (thunk) #f)))
;; Comparisons are made here, on whole values, and only the answer is
;; printed: this tree's printer shows twelve places after the point, so
;; a row reporting two flonums can report a difference it cannot show.
(define (near? a b)
  (let ((d (fl- a b)))
    (fl<? (if (fl<? d 0.0) (fl- 0.0 d) d) 1e-9)))
(define (v-near? u v)
  (and (near? (v3-x u) (v3-x v))
       (near? (v3-y u) (v3-y v))
       (near? (v3-z u) (v3-z v))))

;; ---- segment-segment-closest -------------------------------------
;; Two segments crossing at right angles, offset in y.  The closest
;; points are directly above and below the crossing.
(let-values (((a b) (segment-segment-closest
                     (v3 -1.0 0.0 0.0) (v3 1.0 0.0 0.0)
                     (v3 0.0 2.0 -1.0) (v3 0.0 2.0 1.0))))
  (want 'crossing-segments-meet-over-the-crossing
        (list (v-near? a (v3 0.0 0.0 0.0)) (v-near? b (v3 0.0 2.0 0.0)))
        '(#t #t)))

;; Parallel segments: any pair at the same offset is closest, so the
;; claim that can be made is about the distance and the alignment, not
;; about which pair was chosen.
(let-values (((a b) (segment-segment-closest
                     (v3 0.0 0.0 0.0) (v3 4.0 0.0 0.0)
                     (v3 0.0 3.0 0.0) (v3 4.0 3.0 0.0))))
  (want 'parallel-segments-are-three-apart
        (near? (flsqrt (v3-dot (v3-sub a b) (v3-sub a b))) 3.0) #t)
  (want 'and-the-pair-is-vertical
        (list (near? (v3-x a) (v3-x b)) (near? (v3-z a) (v3-z b)))
        '(#t #t)))

;; Segments whose nearest approach is at an endpoint rather than in
;; the interior -- the case a formula that only solves the interior
;; gets wrong.
(let-values (((a b) (segment-segment-closest
                     (v3 0.0 0.0 0.0) (v3 1.0 0.0 0.0)
                     (v3 5.0 0.0 0.0) (v3 6.0 0.0 0.0))))
  (want 'disjoint-collinear-segments-meet-at-their-ends
        (list (v-near? a (v3 1.0 0.0 0.0)) (v-near? b (v3 5.0 0.0 0.0)))
        '(#t #t)))

;; ---- capsule-capsule-contact -------------------------------------
;; Two crossing capsules, radius 1 each, axes 2 apart: the surfaces
;; touch exactly, so the separation is zero and the contact points
;; coincide.
(let-values (((on1 on2 sep) (capsule-capsule-contact
                             (v3 -2.0 0.0 0.0) (v3 2.0 0.0 0.0) 1.0
                             (v3 0.0 2.0 -2.0) (v3 0.0 2.0 2.0) 1.0)))
  (want 'capsules-just-touching-are-zero-apart (near? sep 0.0) #t)
  (want 'and-their-contact-points-coincide (v-near? on1 on2) #t)
  (want 'at-the-midpoint-between-the-axes
        (v-near? on1 (v3 0.0 1.0 0.0)) #t))

;; Overlapping: the separation is negative by how far they interpenetrate.
(let-values (((on1 on2 sep) (capsule-capsule-contact
                             (v3 -2.0 0.0 0.0) (v3 2.0 0.0 0.0) 1.0
                             (v3 0.0 1.5 -2.0) (v3 0.0 1.5 2.0) 1.0)))
  (want 'overlap-is-a-negative-separation (near? sep -0.5) #t))

;; Apart: positive, and it is the gap between the surfaces rather than
;; between the axes.
(let-values (((on1 on2 sep) (capsule-capsule-contact
                             (v3 -2.0 0.0 0.0) (v3 2.0 0.0 0.0) 1.0
                             (v3 0.0 5.0 -2.0) (v3 0.0 5.0 2.0) 1.0)))
  (want 'separation-is-surface-to-surface-not-axis-to-axis
        (near? sep 3.0) #t))

;; ---- ray-heightfield ---------------------------------------------
;; Flat ground at y = 0.  A ray from height 10 going straight down
;; meets it at t = 10.
(define (flat x z) 0.0)
(want 'straight-down-onto-flat-ground
      (near? (ray-heightfield (v3 0.0 10.0 0.0) (v3 0.0 -1.0 0.0)
                              flat 100.0 0.5 30)
             10.0)
      #t)

;; A ray that starts BELOW the ground is already underground, and the
;; answer is zero rather than a march forward.
;;
;; EXACTLY zero, not nearly.  A version that marches anyway bisects
;; between 0 and the first step, and with thirty refinements that
;; converges to about 5e-10 -- inside the tolerance every other row
;; here uses, and this row read as passing while the early return had
;; been removed.  The library returns the literal, so the cell can ask
;; for the literal, and the distinction between "answered immediately"
;; and "searched and found almost the same place" is the whole content
;; of the row.
(want 'starting-underground-answers-zero
      (ray-heightfield (v3 0.0 -1.0 0.0) (v3 0.0 -1.0 0.0)
                       flat 100.0 0.5 30)
      0.0)

;; A ray that never comes down answers #f rather than a distance.
(want 'a-ray-that-never-lands-answers-false
      (ray-heightfield (v3 0.0 10.0 0.0) (v3 0.0 1.0 0.0)
                       flat 100.0 0.5 30)
      #f)

;; And one that would land past the range answers #f: the range is a
;; limit on the search, not a suggestion.
(want 'beyond-the-range-is-not-found
      (ray-heightfield (v3 0.0 100.0 0.0) (v3 0.0 -1.0 0.0)
                       flat 10.0 0.5 30)
      #f)

;; Sloping ground, so the answer is not the same for a formula that
;; ignores the height function's arguments.  The ground is y = x, and
;; a ray straight down from (4, 10) meets it at t = 6.
(define (slope x z) x)
(want 'the-ground-is-sampled-at-the-ray-position
      (near? (ray-heightfield (v3 4.0 10.0 0.0) (v3 0.0 -1.0 0.0)
                              slope 100.0 0.25 40)
             6.0)
      #t)

;; Refinement is what makes the answer better than the march step.  A
;; coarse step with no refinement lands on a step boundary; the same
;; march refined lands on the surface.
(let ((coarse (ray-heightfield (v3 0.0 10.0 0.0) (v3 0.0 -1.0 0.0)
                               flat 100.0 4.0 0))
      (fine (ray-heightfield (v3 0.0 10.0 0.0) (v3 0.0 -1.0 0.0)
                             flat 100.0 4.0 40)))
  (want 'without-refinement-the-answer-is-a-step-boundary
        (near? coarse 12.0) #t)
  (want 'refinement-brings-it-to-the-surface (near? fine 10.0) #t))

;; Refusals: the ground is a procedure, and the step and range are
;; positive.
(want 'a-non-procedure-ground-refused
      (raises? (lambda () (ray-heightfield (v3 0.0 1.0 0.0) (v3 0.0 -1.0 0.0)
                                           0.0 10.0 0.5 4))) #t)
(want 'a-zero-step-refused
      (raises? (lambda () (ray-heightfield (v3 0.0 1.0 0.0) (v3 0.0 -1.0 0.0)
                                           flat 10.0 0.0 4))) #t)
(want 'a-negative-refinement-refused
      (raises? (lambda () (ray-heightfield (v3 0.0 1.0 0.0) (v3 0.0 -1.0 0.0)
                                           flat 10.0 0.5 -1))) #t)

(display (if (null? fails) #t (reverse fails)))
