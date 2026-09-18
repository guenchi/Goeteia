;; expect: #t
;; The two cells that arrived with (gfx obstacles) are good, and several
;; of their assertions carry names that claim more than the assertion
;; distinguishes.  This cell pins the difference rather than rewriting a
;; contribution.  Each row below names the delivered assertion it
;; strengthens and what that assertion would fail to notice.
;;
;; Every expectation here is DERIVED FROM THE GEOMETRY, not copied out
;; of a probe.  The panel is a full 0.2 wide at x = 0, so its left face
;; is x = -0.1; a query radius of 0.1 puts first contact at x = -0.2.
;; Over a segment of length L starting at x0 the fraction is
;; (-0.2 - x0) / L.  The same rule gives every number below.
(import (rnrs) (gfx mat) (gfx obstacles))
(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
(define (near? a b) (< (abs (- a b)) 0.00001))
(define (want-near name got expect)
  (unless (near? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))

(define wall (obstacle-box "panel" 'surface-a 0 1 0 0.2 2 2 0))
(define world (make-obstacle-index (list wall) 4))

;; STRENGTHENS "Contact reports the surface and outward normal", which
;; compares only component 0 of the point and of the normal.  Arbitrary
;; y and z in either vector pass it.  The sweep runs along y = 1, z = 0,
;; so the contact point is on that line and the outward normal of a face
;; whose plane is x = -0.1 is exactly -X.
(let* ((hit (obstacle-sweep world '#(-2 1 0) '#(2 1 0) 0.1))
       (point (vector-ref hit 1)) (normal (vector-ref hit 2)))
  (want-near "contact point y is on the swept line" (vector-ref point 1) 1.0)
  (want-near "contact point z is on the swept line" (vector-ref point 2) 0.0)
  (want-near "normal has no y component" (vector-ref normal 1) 0.0)
  (want-near "normal has no z component" (vector-ref normal 2) 0.0))

;; STRENGTHENS "The broadphase includes the segment middle", which
;; requires only a truthy result: a fabricated hit with the wrong
;; fraction, point or obstacle satisfies it.  From -30 to 30 the segment
;; is 60 long and first contact is still x = -0.2, so (-0.2 + 30) / 60.
(let ((hit (obstacle-sweep world '#(-30 1 0) '#(30 1 0) 0.1)))
  (want-near "a long segment reports the derived fraction" (vector-ref hit 0) (/ 29.8 60.0))
  (want "a long segment reports the obstacle itself" (vector-ref hit 3) wall))

;; ASSERTED NOWHERE: that the EARLIEST of two contacts wins.  Every index
;; in the delivered sweep cell holds exactly one obstacle, and the tie
;; case uses two boxes at one position, so "earliest" is never separated
;; from "any" or from "first in the list".  The far box is listed FIRST
;; here on purpose: list order cannot explain the answer.
(let* ((near-box (obstacle-box "near" 'surface-a -1 1 0 0.2 2 2 0))
       (far-box (obstacle-box "far" 'surface-b 1 1 0 0.2 2 2 0))
       (two (make-obstacle-index (list far-box near-box) 4))
       (hit (obstacle-sweep two '#(-3 1 0) '#(3 1 0) 0.1)))
  (want "the nearer of two obstacles wins" (obstacle-id (vector-ref hit 3)) "near")
  (want-near "and reports its own contact time" (vector-ref hit 0) (/ 1.8 6.0)))

;; STRENGTHENS "Segment subdivision preserves contact time".  That
;; assertion is (near full (* 0.5 half)), which two zeroes satisfy: a
;; function that always answered 0 would pass it.  Requiring a positive
;; time is what makes the scaling relation say something.
(let ((full (segment-capsule-entry '#(-2 1 0) '#(2 1 0) 0.4 0.3 3.7)))
  (want "subdivision compares a real contact, not two zeroes" (and (> full 0.0) #t) #t))

;; ASSERTED NOWHERE: the miss answer.  Every call in the delivered cells
;; hits.  A helper that returned 0 for a miss would pass all of them and
;; report a contact at the start of every clear segment.
(want "a clear segment answers #f" (segment-capsule-entry '#(-2 9 0) '#(2 9 0) 0.1 0.3 3.7) #f)

;; ASSERTED NOWHERE: any material other than 'surface-a.  Both delivered
;; cells only ever read the material of a surface-a object, so a constant
;; accessor passes them.
(want "material is the symbol the caller supplied, not a constant"
      (obstacle-material (obstacle-box "other" 'surface-b 0 1 0 1 1 1 0)) 'surface-b)
(want "identity is the string the caller supplied"
      (obstacle-id (obstacle-box "some/long-identity" 'surface-a 0 1 0 1 1 1 0)) "some/long-identity")

(display (if (null? fails) #t fails))
