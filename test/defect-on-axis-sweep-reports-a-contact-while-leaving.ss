;; expect: #t
;; EXPECTED FAIL against lib/gfx/obstacles.ss at 802e67d.  A sweep that
;; starts exactly on a capsule's axis and moves straight OUT is reported
;; as a blocking contact at fraction zero.
;;
;; The direction filter is meant to keep only contacts ENTERING along
;; the normal.  It computes that normal from the vector between the
;; contact point and the nearest point on the axis -- but a query
;; starting on the axis makes that vector zero, so $obs-narrow falls
;; back to the reverse of the motion.  The filter then asks whether the
;; motion opposes the normal, and the reverse of the motion always
;; does.  The fallback is not wrong to exist; it is wrong to let it
;; reach a test that assumes the normal came from the geometry.
;;
;; WHAT A CALLER SEES: a character standing exactly at a pillar's centre
;; cannot walk out of it.  Every step away reports a blocker at fraction
;; zero, so a controller that stops at the first contact stops forever.
;;
;; THE ROWS ARE A PAIR, AND BOTH MUST HOLD.  A repair that simply
;; refused the fallback would silence the first row and break the
;; second, because a sweep arriving from outside genuinely needs a
;; contact.  Neither row alone distinguishes a fix from a mute.
(import (rnrs) (gfx mat) (gfx obstacles))
(define pillar (obstacle-capsule "pillar" 'solid 0.0 0.0 1.0 0.0 2.0))
(define world (make-obstacle-index (list pillar) 4.0))
(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))

;; THE DEFECT: on the axis, moving out, must not be a blocker.
(want "leaving from exactly on the axis is not an entering contact"
      (obstacle-sweep world '#(0.0 1.0 0.0) '#(2.0 1.0 0.0) 0.1) #f)

;; CONTROL 1: the same motion started a hair off the axis already
;; answers #f, which is why this is a degenerate-input defect and not a
;; broken rule.  If this row ever goes red the rule itself has moved.
(want "leaving from just off the axis is already not a contact"
      (obstacle-sweep world '#(0.5 1.0 0.0) '#(2.0 1.0 0.0) 0.1) #f)

;; CONTROL 2: arriving from outside must still be a contact.  A repair
;; that refused every fallback normal would pass the first row by
;; silencing it and would break this one.
(let ((hit (obstacle-sweep world '#(-3.0 1.0 0.0) '#(3.0 1.0 0.0) 0.1)))
  (want "arriving from outside is still a contact" (and hit #t) #t))

(display (if (null? fails) #t fails))
