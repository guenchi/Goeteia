;; expect: #t
;; (gfx mat) inverse trigonometry and quaternion slerp.
;;
;; Two independent oracles for the four inverse functions: the
;; identities they must satisfy (sin(asin x) = x, asin + acos =
;; pi/2, atan2 of a unit circle recovers its angle), and the host's
;; own Math, reached through (web js), on grids at 1e-7.  A
;; polynomial coefficient that drifts fails the second even when
;; the first still holds by symmetry.
;;
;; The clamp on |x| > 1 is asserted together with the host's NaN at
;; the same argument, so the deviation stays deliberate and visible.
;;
;; q-slerp is judged where it differs from the nlerp (gfx gltf)
;; samples animation with: at t = 1/4 and 3/4 the two disagree in
;; the third digit, and both agree at t = 1/2 -- a midpoint-only
;; test would pass an nlerp.  The shortest-path flip is judged on a
;; pair 270 degrees apart, and the exactly-antipodal pair (where
;; dropping the flip leaves a zero-length lerp to normalize) is
;; asserted non-NaN.
(import (rnrs) (web js) (gfx mat))

(define pi 3.141592653589793)
(define pi/2 1.5707963267948966)
(define pi/4 0.7853981633974483)
(define deg 0.017453292519943295)       ; radians per degree

;; the self-hosted compiler's reader has no exponent syntax, so the
;; tolerances below are spelled out and the extremes built by dividing
(define eps-3 0.001)
(define eps-7 0.0000001)
(define eps-8 0.00000001)
(define eps-9 0.000000001)
(define eps-11 0.00000000001)
(define eps-12 0.000000000001)
(define tiny 0.00000000000000000001)   ; 1e-20
(define huge (fl/ 1.0 tiny))            ; 1e20

(define (close? a b tol)
  (let ((d (fl- a b))) (fl<? (fl* d d) (fl* tol tol))))
(define (not-nan? x) (fl=? x x))        ; the only value unequal to itself

;; the host's transcendentals: the second, independent implementation.
;; js->number answers a fixnum for an integral JS number, and a fl
;; operation on one of those traps -- hence the exact->inexact
(define $math (js-get (js-global) "Math"))
(define (math1 name x)
  (exact->inexact (js->number (js-method $math name x))))
(define (math2 name x y)
  (exact->inexact (js->number (js-method $math name x y))))
;; every i in [0, n] must satisfy f
(define (all-i n f)
  (let loop ((i 0))
    (or (> i n) (and (f i) (loop (+ i 1))))))

;; x over [-1, 1] in steps of 1/200 -- built by dividing, so the
;; endpoints are exactly +/-1 and the scan never leaves the domain
(define (unit-grid i) (fl/ (exact->inexact (- i 200)) 200.0))

;; ---- identities ----
(define sin-asin-ok
  (all-i 400 (lambda (i)
               (let ((x (unit-grid i)))
                 (close? (flsin (flasin x)) x eps-8)))))

(define asin-acos-sum-ok
  (all-i 400 (lambda (i)
               (let ((x (unit-grid i)))
                 (close? (fl+ (flasin x) (flacos x)) pi/2 eps-12)))))

(define tan-atan-ok
  (all-i 400 (lambda (i)
               (let ((x (fl* 0.01 (exact->inexact (- i 200)))))  ; +/-2
                 (close? (fltan (flatan x)) x eps-7)))))

;; atan2 of a point on the unit circle recovers the angle it was
;; built from, over the whole open turn (-pi, pi)
(define atan2-roundtrip-ok
  (all-i 359
         (lambda (i)
           (let* ((th (fl+ (fl- 0.0 pi)
                           (fl* (fl+ (exact->inexact i) 0.5)
                                (fl/ (fl* 2.0 pi) 360.0))))
                  (a (flatan2 (flsin th) (flcos th))))
             (close? a th eps-8)))))

;; ---- the host as a second implementation ----
(define asin-host-ok
  (all-i 400 (lambda (i)
               (let ((x (unit-grid i)))
                 (and (close? (flasin x) (math1 "asin" x) eps-7)
                      (close? (flacos x) (math1 "acos" x) eps-7))))))

(define atan-host-ok
  (all-i 400 (lambda (i)
               (let ((x (fl* 0.37 (exact->inexact (- i 200)))))  ; +/-74
                 (close? (flatan x) (math1 "atan" x) eps-7)))))

;; a 21 x 21 grid of (y, x), zeros and both axes included: every
;; quadrant, every axis, against the host's own four-quadrant sign
;; convention
(define atan2-host-ok
  (all-i 20
         (lambda (i)
           (all-i 20
                  (lambda (j)
                    (let ((y (fl/ (exact->inexact (- i 10)) 3.0))
                          (x (fl/ (exact->inexact (- j 10)) 3.0)))
                      (close? (flatan2 y x) (math2 "atan2" y x) eps-7)))))))

;; ---- values that pin the constants down ----
(define known-ok
  (and (close? (flacos -1.0) pi eps-12)
       (fl=? (flacos 1.0) 0.0)
       (close? (flacos 0.0) pi/2 eps-12)
       (close? (flacos 0.5) (fl/ pi 3.0) eps-12)
       (fl=? (flasin 0.0) 0.0)
       (close? (flasin 1.0) pi/2 eps-12)
       (close? (flasin -1.0) (fl- 0.0 pi/2) eps-12)
       (close? (flasin 0.5) (fl/ pi 6.0) eps-12)
       (fl=? (flatan 0.0) 0.0)
       (close? (flatan 1.0) pi/4 eps-12)
       (close? (flatan -1.0) (fl- 0.0 pi/4) eps-12)
       ;; the reduction seam at tan(pi/8) is crossed from both sides
       (close? (flatan 0.41421356237309515) (fl/ pi 8.0) eps-12)
       (close? (flatan 0.4142135) (math1 "atan" 0.4142135) eps-12)
       (close? (flatan 0.4142136) (math1 "atan" 0.4142136) eps-12)
       ;; and the one at |x| = 1/2 in asin
       (close? (flasin 0.4999999) (math1 "asin" 0.4999999) eps-12)
       (close? (flasin 0.5000001) (math1 "asin" 0.5000001) eps-12)))

;; the four quadrants and the four axes, spelled out: a flipped sign
;; in any one branch of flatan2 shows here even if the host oracle
;; were unavailable
(define quadrant-ok
  (and (fl=? (flatan2 0.0 0.0) 0.0)      ; not a NaN, by decision
       (fl=? (flatan2 0.0 1.0) 0.0)
       (close? (flatan2 1.0 0.0) pi/2 eps-12)
       (close? (flatan2 -1.0 0.0) (fl- 0.0 pi/2) eps-12)
       (close? (flatan2 0.0 -1.0) pi eps-12)
       (close? (flatan2 1.0 1.0) pi/4 eps-12)
       (close? (flatan2 1.0 -1.0) (fl* 3.0 pi/4) eps-12)
       (close? (flatan2 -1.0 -1.0) (fl- 0.0 (fl* 3.0 pi/4)) eps-12)
       (close? (flatan2 -1.0 1.0) (fl- 0.0 pi/4) eps-12)
       ;; just off the negative x axis, either side
       (close? (flatan2 tiny -1.0) pi eps-7)
       (close? (flatan2 (fl- 0.0 tiny) -1.0) (fl- 0.0 pi) eps-7)))

;; a dot product of two unit vectors leaves [-1, 1] by an ulp as a
;; matter of course; the host answers NaN there and we clamp
(define clamp-ok
  (and (not-nan? (flasin 1.0000001))
       (not (not-nan? (math1 "asin" 1.0000001)))   ; the host's NaN
       (close? (flasin 1.0000001) pi/2 eps-12)
       (close? (flasin -1.0000001) (fl- 0.0 pi/2) eps-12)
       (close? (flasin 1.5) pi/2 eps-12)
       (close? (flasin -4.0) (fl- 0.0 pi/2) eps-12)
       (not-nan? (flacos 1.0000001))
       (fl=? (flacos 1.0000001) 0.0)
       (close? (flacos -1.0000001) pi eps-12)
       (close? (flacos 3.0) 0.0 eps-12)))

;; atan saturates rather than overflowing, all the way to infinity
(define saturate-ok
  (and (close? (flatan huge) pi/2 eps-12)
       (close? (flatan (fl- 0.0 huge)) (fl- 0.0 pi/2) eps-12)
       (close? (flatan (fl/ 1.0 0.0)) pi/2 eps-12)))

;; ---- quaternion slerp ----
;; quaternions are #(x y z w), the shape (gfx gltf) stores rotations
;; in.  qz normalizes on the way out because flcos 0 is 1 - 6e-12,
;; and an input that far off the unit sphere would mask exactly the
;; norm drift slerp-unit-ok looks for
(define (qz d)                          ; rotation of d degrees about z
  (let* ((h (fl* 0.5 (fl* d deg)))
         (z (flsin h)) (w (flcos h))
         (n (flsqrt (fl+ (fl* z z) (fl* w w)))))
    (vector 0.0 0.0 (fl/ z n) (fl/ w n))))
(define (qnorm q)
  (flsqrt (fl+ (fl+ (fl* (vector-ref q 0) (vector-ref q 0))
                    (fl* (vector-ref q 1) (vector-ref q 1)))
               (fl+ (fl* (vector-ref q 2) (vector-ref q 2))
                    (fl* (vector-ref q 3) (vector-ref q 3))))))
(define (qnear? q a b c d tol)
  (and (close? (vector-ref q 0) a tol) (close? (vector-ref q 1) b tol)
       (close? (vector-ref q 2) c tol) (close? (vector-ref q 3) d tol)))
(define (qzs? q d tol)                  ; q is the rotation of d degrees?
  (let ((r (qz d)))
    (qnear? q (vector-ref r 0) (vector-ref r 1)
            (vector-ref r 2) (vector-ref r 3) tol)))
(define (qfinite? q)
  (and (not-nan? (vector-ref q 0)) (not-nan? (vector-ref q 1))
       (not-nan? (vector-ref q 2)) (not-nan? (vector-ref q 3))))

;; 1e-9 is the tolerance on components throughout this section: both
;; sides of every comparison run through flsin/flcos, whose own error
;; is that size, so a tighter window would be measuring the forward
;; trig rather than the interpolation.  The norm, which no forward
;; trig error survives into once qz normalizes, is held to 1e-11
(define slerp-ends-ok
  (let ((a (qz 0.0)) (b (qz 80.0)))
    (and (qzs? (q-slerp a b 0.0) 0.0 eps-9)
         (qzs? (q-slerp a b 1.0) 80.0 eps-9))))

;; 270 degrees apart the short way round is -90, so the halfway
;; pose is -45 and NOT +135.  Both are asserted: the second keeps a
;; loosened tolerance from hiding the long way round
(define slerp-shortest-ok
  (let ((q (q-slerp (qz 0.0) (qz 270.0) 0.5)))
    (and (qzs? q -45.0 eps-9)
         (not (qzs? q 135.0 0.01)))))

;; the property that separates slerp from nlerp: the angle swept is
;; proportional to t everywhere, not just at the midpoint.  120
;; degrees apart, nlerp lands 1.2 degrees off at a quarter.
(define slerp-rate-ok
  (let ((a (qz 0.0)) (b (qz 120.0)))
    (and (qzs? (q-slerp a b 0.25) 30.0 eps-9)
         (qzs? (q-slerp a b 0.5) 60.0 eps-9)
         (qzs? (q-slerp a b 0.75) 90.0 eps-9))))

;; ... and that separation is real at the tolerance above: the
;; normalized lerp of the same pair, computed here, differs at a
;; quarter by far more than 1e-9 -- while agreeing at the midpoint
(define slerp-not-nlerp-ok
  (let* ((a (qz 0.0)) (b (qz 120.0))
         (nlerp (lambda (t)
                  (let* ((u (fl- 1.0 t))
                         (z (fl+ (fl* u (vector-ref a 2))
                                 (fl* t (vector-ref b 2))))
                         (w (fl+ (fl* u (vector-ref a 3))
                                 (fl* t (vector-ref b 3))))
                         (n (flsqrt (fl+ (fl* z z) (fl* w w)))))
                    (vector 0.0 0.0 (fl/ z n) (fl/ w n))))))
    (and (not (qnear? (q-slerp a b 0.25)
                      0.0 0.0 (vector-ref (nlerp 0.25) 2)
                      (vector-ref (nlerp 0.25) 3) eps-3))
         (qnear? (q-slerp a b 0.5)
                 0.0 0.0 (vector-ref (nlerp 0.5) 2)
                 (vector-ref (nlerp 0.5) 3) eps-9))))

;; the host's own sin/cos of the swept half-angle, over a sweep of t
(define slerp-host-ok
  (let ((a (qz 0.0)) (b (qz 140.0)))
    (all-i 20
           (lambda (i)
             (let* ((t (fl/ (exact->inexact i) 20.0))
                    (h (fl* t (fl* 70.0 deg)))
                    (q (q-slerp a b t)))
               (qnear? q 0.0 0.0 (math1 "sin" h) (math1 "cos" h) eps-9))))))

;; t is not clamped: the arc continues past both ends
(define slerp-extrapolate-ok
  (let ((a (qz 0.0)) (b (qz 60.0)))
    (and (qzs? (q-slerp a b 2.0) 120.0 eps-9)
         (qzs? (q-slerp a b -0.5) -30.0 eps-9))))

;; near-parallel and exactly-parallel inputs: sin of the angle is
;; the divisor in the general case, so both must take the lerp path
;; and come back finite
;;
;; The two off-axis midpoints are judged against HALF the far
;; quaternion's own z, to a part in a thousand of that z: at these
;; angles an absolute 1e-9 window would accept zero, and a slerp
;; that quietly returned an endpoint would pass it
(define slerp-degenerate-ok
  (let* ((a (qz 0.0))
         (tiny (qz 0.000001))               ; 8.7e-9 radians apart
         (near (qz 0.01))               ; 1 - 3.8e-9 dot: just outside
         (self (q-slerp a a 0.5))       ; the window, so the general
         (th (q-slerp a tiny 0.5))      ; case divides by its smallest
         (nh (q-slerp a near 0.5))      ; sine
         (halfway?
          (lambda (q far)
            (let ((z (vector-ref far 2)))
              (and (close? (vector-ref q 2) (fl* 0.5 z) (fl* 0.001 z))
                   (close? (vector-ref q 3) 1.0 eps-8)
                   (close? (qnorm q) 1.0 eps-11))))))
    (and (qfinite? self) (qzs? self 0.0 eps-9)
         (qfinite? th) (halfway? th tiny)
         (qfinite? nh) (halfway? nh near))))

;; a unit pair interpolates to unit quaternions at every t and every
;; separation -- including the small separations where sin(theta),
;; the divisor both weights share, is itself small.  A weight pair
;; scaled together leaves the direction right and the length wrong,
;; which is a rotation with a scale baked into it and nothing an
;; angle check would notice
(define slerp-unit-ok
  (all-i 8
         (lambda (j)
           (let ((b (qz (fl* 20.0 (exact->inexact (- j 4))))))  ; +/-80
             (all-i 20
                    (lambda (i)
                      (let ((t (fl/ (exact->inexact (- i 5)) 10.0)))  ; -.5 .. 1.5
                        (close? (qnorm (q-slerp (qz 0.0) b t))
                                1.0 eps-11))))))))

;; -q is q's own rotation, so the antipodal pair is a zero-length
;; arc after the flip.  Without the flip it is a lerp of q and -q,
;; whose norm is zero: the normalize divides by it
(define slerp-antipodal-ok
  (let* ((a (qz 0.0))
         (b (vector 0.0 0.0 0.0 -1.0))
         (q (q-slerp a b 0.5)))
    (and (qfinite? q) (qzs? q 0.0 eps-9))))

(and sin-asin-ok asin-acos-sum-ok tan-atan-ok atan2-roundtrip-ok
     asin-host-ok atan-host-ok atan2-host-ok
     known-ok quadrant-ok clamp-ok saturate-ok
     slerp-ends-ok slerp-shortest-ok slerp-rate-ok
     slerp-not-nlerp-ok slerp-host-ok slerp-extrapolate-ok
     slerp-degenerate-ok slerp-unit-ok slerp-antipodal-ok)
