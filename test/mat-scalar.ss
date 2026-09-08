;; expect: #t
;; The scalar arithmetic every simulation writes on its first day.
;;
;; (gfx mat) had vectors and matrices and nothing below them, so a
;; consumer wrote clamp, lerp, a frame-rate-independent damp, an angle
;; that takes the short way round, and a smoothstep -- five functions
;; that are the same in every application and wrong in a different way
;; in each one that rewrites them.  The two that are easy to get wrong
;; are damp and turn, and both are pinned here for the reason they are
;; usually wrong rather than for their happy path.
(import (rnrs) (gfx mat))

(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))
(define (near? a b) (< (abs (- a b)) 0.0001))

;; ---- clamp ----
(check "clamp holds the ends and passes the middle"
       (and (near? (fl-clamp 5.0 0.0 1.0) 1.0)
            (near? (fl-clamp -5.0 0.0 1.0) 0.0)
            (near? (fl-clamp 0.25 0.0 1.0) 0.25)
            (near? (fl-clamp 0.0 0.0 1.0) 0.0)
            (near? (fl-clamp 1.0 0.0 1.0) 1.0)))
(check "clamp works with the ends the wrong way round only by refusing"
       (guard (e (#t (eq? (condition-who e) 'fl-clamp)))
         (fl-clamp 0.5 1.0 0.0) #f))

;; ---- lerp ----
(check "lerp hits both ends exactly"
       (and (near? (fl-lerp 2.0 6.0 0.0) 2.0)
            (near? (fl-lerp 2.0 6.0 1.0) 6.0)
            (near? (fl-lerp 2.0 6.0 0.5) 4.0)))
(check "lerp past the ends keeps going, it does not clamp"
       (and (near? (fl-lerp 0.0 10.0 2.0) 20.0)
            (near? (fl-lerp 0.0 10.0 -1.0) -10.0)))

;; ---- damp: the one that is wrong when the frame rate changes ----
;; A naive "move a fixed fraction each frame" converges twice as fast at
;; 120 fps as at 60.  Damping toward a target must depend on elapsed
;; time, not on how many times it was called: sixty steps of 1/60 and
;; six steps of 1/6 must land in the same place.
(check "damp does not depend on how the second was divided"
       (let ((a (let loop ((i 0) (x 0.0))
                  (if (= i 60) x (loop (+ i 1) (fl-damp x 1.0 3.0 (/ 1.0 60.0))))))
             (b (let loop ((i 0) (x 0.0))
                  (if (= i 6) x (loop (+ i 1) (fl-damp x 1.0 3.0 (/ 1.0 6.0)))))))
         (and (near? a b) (> a 0.9) (< a 1.0))))
(check "damp with no time passing does not move"
       (near? (fl-damp 0.25 1.0 3.0 0.0) 0.25))
(check "damp never overshoots its target"
       (let loop ((i 0) (x 0.0))
         (cond ((= i 200) (and (<= x 1.0) (> x 0.999)))
               (else (let ((y (fl-damp x 1.0 40.0 0.5)))
                       (and (<= y 1.0) (loop (+ i 1) y)))))))

;; ---- turn: the one that spins the long way round ----
;; Heading arithmetic that forgets to wrap turns 350 degrees left instead
;; of 10 degrees right.  The test is that it crosses the seam.
(define pi 3.141592653589793)
(define tau 6.283185307179586)
(check "turn takes the short way across the seam"
       (let ((from (- tau 0.1)) (to 0.1))
         (let ((next (fl-turn from to 10.0 0.016)))
           (and (> next from) (< next (+ from 0.2))))))
(check "turn takes the short way in the other direction too"
       (let ((next (fl-turn 0.1 (- tau 0.1) 10.0 0.016)))
         (< next 0.1)))
(check "turn arrives and stays"
       (let loop ((i 0) (a 0.0))
         (if (= i 500)
             (let ((d (abs (- a 2.0)))) (< (min d (- tau d)) 0.001))
             (loop (+ i 1) (fl-turn a 2.0 8.0 0.016)))))

;; ---- smoothstep ----
(check "smoothstep is flat outside its ends and smooth between"
       (and (near? (fl-smooth 0.0 1.0 -1.0) 0.0)
            (near? (fl-smooth 0.0 1.0 2.0) 1.0)
            (near? (fl-smooth 0.0 1.0 0.5) 0.5)
            (near? (fl-smooth 2.0 4.0 3.0) 0.5)
            (< (fl-smooth 0.0 1.0 0.25) 0.25)      ; eased in
            (> (fl-smooth 0.0 1.0 0.75) 0.75)))    ; eased out
(check "smoothstep with equal ends is refused rather than dividing by zero"
       (guard (e (#t (eq? (condition-who e) 'fl-smooth)))
         (fl-smooth 1.0 1.0 1.0) #f))

(display (= failed 0))
(newline)
