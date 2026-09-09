;; expect: #t
;; (gfx camera): an orbit camera that eases toward where it should be.
;;
;; The property worth pinning is the one a picture cannot show: the
;; easing is per unit of TIME, so the same elapsed time gives the same
;; place however many steps it is cut into.  A camera written with a
;; per-call lerp looks perfectly smooth and moves at a different speed on
;; every machine, and no screenshot says so.
;;
;; The other cells are the seams: limits at both ends, a floor applied
;; AFTER the easing rather than before it, and a shake that returns to
;; zero.  Sensitivities are not here at all -- deltas arrive already in
;; radians and world units, because how far a mouse moves belongs to the
;; input layer and not to a camera.
(import (rnrs) (gfx mat) (gfx camera))

(define (near? a b)
  (and (fl<? (fl- a b) 0.0001) (fl<? (fl- b a) 0.0001)))
(define (v3~ v x y z)
  (and (near? (v3-x v) x) (near? (v3-y v) y) (near? (v3-z v) z)))
(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))
(define (settle! c n dt)                ; n steps of dt
  (let loop ((i 0)) (when (< i n) (camera-follow! c dt) (loop (+ i 1)))))

(check "a fresh camera is one" (orbit-camera? (make-orbit-camera)))

;; ---- limits, at BOTH ends ----
(let ((c (make-orbit-camera)))
  (camera-limits! c 0.1 1.2 4.0 15.0)
  (camera-orbit! c 0.0 -99.0 0.0)
  (check "pitch clamps at the low end" (near? (camera-pitch c) 0.1))
  (camera-orbit! c 0.0 99.0 0.0)
  (check "pitch clamps at the high end" (near? (camera-pitch c) 1.2))
  (camera-orbit! c 0.0 0.0 -99.0)
  (check "distance clamps at the near end" (near? (camera-distance c) 4.0))
  (camera-orbit! c 0.0 0.0 99.0)
  (check "distance clamps at the far end" (near? (camera-distance c) 15.0))
  ;; yaw is an accumulating heading: three turns is not the same fact as
  ;; none, so it is neither clamped nor folded
  (camera-orbit! c 100.0 0.0 0.0)
  (check "yaw is not clamped or folded" (fl<? 99.0 (camera-yaw c))))

;; limits the wrong way round are a bug in whoever computed them
(check "reversed pitch limits are refused, naming the procedure"
       (guard (e ((error? e) #t) (else #f))
         (begin (camera-limits! (make-orbit-camera) 1.2 0.1 4.0 15.0) #f)))
(check "reversed distance limits are refused"
       (guard (e ((error? e) #t) (else #f))
         (begin (camera-limits! (make-orbit-camera) 0.1 1.2 15.0 4.0) #f)))

;; ---- the property a picture cannot show ----
;; The first follow places the eye rather than easing toward it, so the
;; target has to move once before there is any easing to compare.  Two
;; earlier drafts of this cell compared cameras that had either snapped
;; straight to the goal or fully converged within the elapsed second: in
;; both, a per-call lerp -- the exact defect this cell exists to catch --
;; passed it.  Hence the third assertion, which fails if the cameras
;; converge and the comparison goes vacuous again.
(check "the same elapsed time gives the same place, however many steps it is cut into"
       (let ((a (make-orbit-camera)) (b (make-orbit-camera)))
         (camera-target! a (v3 0.0 0.0 0.0))
         (camera-target! b (v3 0.0 0.0 0.0))
         (settle! a 1 (fl/ 1.0 60.0))
         (settle! b 1 (fl/ 1.0 60.0))
         (camera-target! a (v3 20.0 0.0 0.0))
         (camera-target! b (v3 20.0 0.0 0.0))
         (settle! a 6 (fl/ 1.0 60.0))     ; 0.1s in six steps
         (settle! b 1 (fl/ 1.0 10.0))     ; 0.1s in one
         (let ((ea (camera-eye a)) (eb (camera-eye b)))
           (and (near? (v3-x ea) (v3-x eb))
                (near? (v3-y ea) (v3-y eb))
                (near? (v3-z ea) (v3-z eb))
                ;; still in flight: at the goal this cell proves nothing
                (fl<? (v3-x ea) 19.0)
                (fl<? 1.0 (v3-x ea))))))

;; ---- the floor is applied after the easing, not before ----
(check "the eye is kept a clearance above the floor"
       (let ((c (make-orbit-camera)))
         (camera-floor! c (lambda (x z) 50.0) 2.0)
         (camera-target! c (v3 0.0 0.0 0.0))
         (settle! c 30 (fl/ 1.0 60.0))
         (fl<? 51.99 (v3-y (camera-eye c)))))
(check "with no floor the eye is free to sit low"
       (let ((c (make-orbit-camera)))
         (camera-floor! c #f 0.0)
         (camera-target! c (v3 0.0 0.0 0.0))
         (settle! c 30 (fl/ 1.0 60.0))
         (fl<? (v3-y (camera-eye c)) 50.0)))

;; ---- shake: bounded, and it returns to zero ----
(check "a shake displaces the eye"
       (let ((c (make-orbit-camera)))
         (camera-target! c (v3 0.0 0.0 0.0))
         (settle! c 60 (fl/ 1.0 60.0))
         (let ((quiet (camera-eye c)))
           (camera-shake! c 1.0 0.0 0.0 1.0)
           (not (v3~ (camera-eye c) (v3-x quiet) (v3-y quiet) (v3-z quiet))))))
(check "a shake decays back to nothing"
       (let ((c (make-orbit-camera)))
         (camera-target! c (v3 0.0 0.0 0.0))
         (settle! c 60 (fl/ 1.0 60.0))
         (let ((quiet (camera-eye c)))
           (camera-shake! c 1.0 0.0 0.0 1.0)
           (settle! c 600 (fl/ 1.0 60.0))
           (v3~ (camera-eye c) (v3-x quiet) (v3-y quiet) (v3-z quiet)))))
(check "a huge impulse is clamped rather than launching the camera"
       (let ((c (make-orbit-camera)))
         (camera-target! c (v3 0.0 0.0 0.0))
         (settle! c 60 (fl/ 1.0 60.0))
         (let ((quiet (v3-x (camera-eye c))))
           (camera-shake! c 1.0 0.0 0.0 1000.0)
           (fl<? (fl- (v3-x (camera-eye c)) quiet) 100.0))))

;; ---- the view matrix is not a second implementation ----
(check "camera-view is m4-look-at from the eye to the target"
       (let ((c (make-orbit-camera)))
         (camera-target! c (v3 1.0 2.0 3.0))
         (settle! c 20 (fl/ 1.0 60.0))
         (let ((want (m4-look-at (camera-eye c) (camera-target c) (v3 0.0 1.0 0.0)))
               (got (camera-view c)))
           (let loop ((i 0))
             (or (= i 16)
                 (and (near? (vector-ref got i) (vector-ref want i))
                      (loop (+ i 1))))))))
(display (= failed 0))
