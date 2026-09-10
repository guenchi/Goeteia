;; expect: #t
;; RED ON PURPOSE: the eye is damped toward its goal and the look
;; target is written straight through, so the direction between them --
;; which is what the view matrix is built from -- moves in the steps of
;; whichever clock writes the target.
;;
;; camera-follow! damps the eye's three components.  camera-target!
;; assigns.  A simulation running at a fixed tick writes the target in
;; discrete jumps while the eye slides continuously between them, so on
;; a display that does not share that tick the heading changes by a
;; step on the frames a tick landed and by almost nothing on the rest.
;;
;; Measured on this tree, 60 Hz display against a 30 Hz simulation,
;; straight line at constant speed, ground perfectly level -- no terrain
;; variation participates at all:
;;
;;     raw target        worst per-frame change in heading   0.0273
;;     target damped     the same, at the same rate          0.0059
;;
;; The discriminating case is a CONSTANT heading.  Moving in a straight
;; line at constant speed over flat ground, the vector from the eye to
;; the target is the same vector on every frame; anything else is the
;; defect and nothing else can produce it.  That is why the bound is
;; 1e-6 rather than something that means "looks smooth": there is no
;; legitimate wobble to leave room for.
;;
;; The display intervals are irregular and include frames on which no
;; tick lands, because a display that happened to share the simulation's
;; rhythm would hide this entirely.
;;
;; The controls are what a fix must not spend: a zero-length frame must
;; not move the camera or poison the next frame's history, and an
;; intentional shake must still displace the eye.
(import (rnrs) (gfx camera) (gfx mat))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))

(define (dir c)
  (let* ((e (camera-eye c)) (t (camera-target c)))
    (v3 (- (v3-x t) (v3-x e)) (- (v3-y t) (v3-y e)) (- (v3-z t) (v3-z e)))))
(define (dir-drift c reference)
  (let ((d (dir c)))
    (max (abs (- (v3-x d) (v3-x reference)))
         (abs (- (v3-y d) (v3-y reference)))
         (abs (- (v3-z d) (v3-z reference))))))

(define c (make-orbit-camera))
(camera-limits! c 0.08 1.12 4.0 15.0)
(camera-target! c (v3 0.0 1.55 0.0))
(camera-follow! c 0.016)
(define reference (dir c))

;; a 60 Hz simulation sampled at irregular display intervals
(define peak 0.0)
(let loop ((frame 0) (t 0.0))
  (when (< frame 240)
    (let* ((dt (list-ref '(0.008 0.013 0.028 0.017) (mod frame 4)))
           (next (+ t dt))
           (x (* 9.0 (/ (floor (* next 60.0)) 60.0))))
      (camera-target! c (v3 x 1.55 0.0))
      (camera-follow! c dt)
      (let ((d (dir-drift c reference)))
        (when (> d peak) (set! peak d)))
      (loop (+ frame 1) next))))

(want 'heading-holds-while-ticks-differ (< peak 0.000001) #t)

;; A zero-length frame must advance nothing.  This is a second red, not
;; a control, and the difference matters: today camera-target! assigns,
;; so of course the target has moved by the time it is read, and the
;; cell can only hold once setting the target means naming a goal.  It
;; was written as a control first, and that was wrong -- a control has
;; to be green before the change as well as after, and this one cannot
;; be.
;;
;; The eye half of it IS a control: the eye is already damped, and
;; damping over zero seconds already moves nothing.
(let ((before (camera-eye c)) (t0 (camera-target c)))
  (camera-target! c (v3 100.0 30.0 0.0))
  (camera-follow! c 0.0)
  (want 'CONTROL-zero-frame-does-not-move-eye (camera-eye c) before)
  (want 'zero-frame-does-not-move-target (camera-target c) t0))

;; ---- controls ----

(let ((quiet (v3-x (camera-eye c))))
  (camera-shake! c 1.0 0.0 1.0 1.0)
  (camera-follow! c 0.02)
  (want 'CONTROL-shake-still-displaces (> (abs (- (v3-x (camera-eye c)) quiet)) 0.0) #t))

(if (null? fails) (display #t) (begin (display fails) (newline)))
