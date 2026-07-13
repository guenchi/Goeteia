;; expect: #t
;; (web mat): pure 3D math, incl. our own trig. Fully verifiable.
(import (rnrs) (web mat))

(define (near? a b)
  (and (fl<? (fl- a b) 0.000001) (fl<? (fl- b a) 0.000001)))
(define (v3~ v x y z)
  (and (near? (v3-x v) x) (near? (v3-y v) y) (near? (v3-z v) z)))
(define (m4~ a b)
  (let loop ((i 0))
    (or (= i 16)
        (and (near? (vector-ref a i) (vector-ref b i))
             (loop (+ i 1))))))

(define pi 3.141592653589793)

(define main-ok
 (and
 ;; trig: knowns, quadrants, range reduction
 (near? (flsin 0.0) 0.0)
 (near? (flsin (fl/ pi 2.0)) 1.0)
 (near? (flsin pi) 0.0)
 (near? (flsin 1.0) 0.8414709848078965)
 (near? (flsin -1.0) -0.8414709848078965)
 (near? (flsin 10.0) -0.5440211108893698)   ; 10 wraps past pi
 (near? (flcos 0.0) 1.0)
 (near? (flcos pi) -1.0)
 (near? (flcos 2.0) -0.4161468365471424)
 (near? (fltan (fl/ pi 4.0)) 1.0)
 ;; vec3
 (v3~ (v3-cross (v3 1 0 0) (v3 0 1 0)) 0.0 0.0 1.0)
 (v3~ (v3-normalize (v3 3 0 4)) 0.6 0.0 0.8)
 (near? (v3-dot (v3 1 2 3) (v3 4 5 6)) 32.0)
 (v3~ (v3-add (v3 1 2 3) (v3 10 20 30)) 11.0 22.0 33.0)
 (v3~ (v3-scale (v3 1 -2 3) 2.0) 2.0 -4.0 6.0)
 ;; identity and multiplication
 (let ((r (m4-rotate-y 0.7)))
   (and (m4~ (m4-mul (m4-identity) r) r)
        (m4~ (m4-mul r (m4-identity)) r)))
 ;; translate moves points
 (v3~ (m4-transform (m4-translate 10 20 30) (v3 1 2 3)) 11.0 22.0 33.0)
 ;; rotate-y pi/2: +x goes to -z (right-handed)
 (v3~ (m4-transform (m4-rotate-y (fl/ pi 2.0)) (v3 1 0 0)) 0.0 0.0 -1.0)
 (v3~ (m4-transform (m4-rotate-x (fl/ pi 2.0)) (v3 0 1 0)) 0.0 0.0 1.0)
 (v3~ (m4-transform (m4-rotate-z (fl/ pi 2.0)) (v3 1 0 0)) 0.0 1.0 0.0)
 ;; composition: (mul a b) applied = a after b
 (let ((t (m4-translate 5 0 0))
       (r (m4-rotate-y (fl/ pi 2.0)))
       (v (v3 1 0 0)))
   (v3~ (m4-transform (m4-mul t r) v)
        (v3-x (v3-add (m4-transform t (v3 0 0 0)) (m4-transform r v)))
        0.0 -1.0))
 ;; scale
 (v3~ (m4-transform (m4-scale 2 3 4) (v3 1 1 1)) 2.0 3.0 4.0)
 ;; perspective: fovy pi/2 -> f = 1
 (let ((p (m4-perspective (fl/ pi 2.0) 2.0 1.0 101.0)))
   (and (near? (vector-ref p 0) 0.5)
        (near? (vector-ref p 5) 1.0)
        (near? (vector-ref p 10) -1.02)
        (near? (vector-ref p 11) -1.0)
        (near? (vector-ref p 14) -2.02)
        (near? (vector-ref p 15) 0.0)))
 ;; ortho: corners of the box land on the clip cube, z sign flips
 (let ((o (m4-ortho -10.0 10.0 -5.0 5.0 1.0 21.0)))
   (and (v3~ (m4-transform o (v3 10 5 -1)) 1.0 1.0 -1.0)
        (v3~ (m4-transform o (v3 -10 -5 -21)) -1.0 -1.0 1.0)
        (v3~ (m4-transform o (v3 0 0 -11)) 0.0 0.0 0.0)))
 ;; asymmetric ortho recenters
 (v3~ (m4-transform (m4-ortho 0.0 10.0 0.0 10.0 1.0 3.0) (v3 5 5 -2))
      0.0 0.0 0.0)
 ;; a quaternion for 90 degrees about y matches m4-rotate-y
 (let ((s (flsin (fl/ pi 4.0))) (c (flcos (fl/ pi 4.0))))
   (m4~ (m4-from-quat 0.0 s 0.0 c) (m4-rotate-y (fl/ pi 2.0))))
 (m4~ (m4-from-quat 0.0 0.0 0.0 1.0) (m4-identity))
 ;; inverse: m * m^-1 = identity, for the matrices games build
 (let* ((m (m4-mul (m4-perspective 0.9 1.5 0.1 100.0)
                   (m4-look-at (v3 3 4 5) (v3 0 1 0) (v3 0 1 0))))
        (inv (m4-inverse m)))
   (and inv (m4~ (m4-mul m inv) (m4-identity))
        (m4~ (m4-mul inv m) (m4-identity))))
 (let ((inv (m4-inverse (m4-mul (m4-translate 2 -3 7)
                                (m4-rotate-y 0.8)))))
   (and inv (v3~ (m4-transform inv (m4-transform
                                    (m4-mul (m4-translate 2 -3 7)
                                            (m4-rotate-y 0.8))
                                    (v3 1 2 3)))
                 1.0 2.0 3.0)))
 ;; singular matrices say so
 (not (m4-inverse (m4-scale 1 1 0)))
 ;; unproject inverts projection: a world point projected to NDC by
 ;; the VP comes back from m4-unproject at the same place
 (let* ((vp (m4-mul (m4-perspective 1.0 1.0 0.1 50.0)
                    (m4-look-at (v3 0 2 8) (v3 0 0 0) (v3 0 1 0))))
        (p (v3 1.5 0.5 -2.0))
        (ndc (m4-transform vp p))
        (back (m4-unproject (m4-inverse vp)
                            (v3-x ndc) (v3-y ndc) (v3-z ndc))))
   (v3~ back 1.5 0.5 -2.0))
 ;; frustum culling: a fov-1 camera at z=10 looking at the origin
 (let* ((vp (m4-mul (m4-perspective 1.0 1.0 0.1 100.0)
                    (m4-look-at (v3 0 0 10) (v3 0 0 0) (v3 0 1 0))))
        (ps (m4-frustum-planes vp)))
   (and (= (vector-length ps) 6)
        (sphere-in-frustum? ps (v3 0 0 0) 1.0)       ; dead center
        (sphere-in-frustum? ps (v3 0 0 9.0) 0.5)     ; near the eye
        (not (sphere-in-frustum? ps (v3 0 0 20) 1.0))    ; behind
        (not (sphere-in-frustum? ps (v3 0 0 -200) 1.0))  ; past far
        ;; at the origin plane the half-width is 10*tan(0.5) ~ 5.46
        (sphere-in-frustum? ps (v3 6 0 0) 2.0)       ; straddles right
        (not (sphere-in-frustum? ps (v3 8 0 0) 1.0)) ; fully outside
        (sphere-in-frustum? ps (v3 0 -6 0) 2.0)
        (not (sphere-in-frustum? ps (v3 0 -8 0) 1.0))))
 ;; look-at from +z: axis-aligned view, eye distance in m14
 (let ((v (m4-look-at (v3 0 0 5) (v3 0 0 0) (v3 0 1 0))))
   (and (near? (vector-ref v 0) 1.0)
        (near? (vector-ref v 5) 1.0)
        (near? (vector-ref v 10) 1.0)
        (near? (vector-ref v 14) -5.0)
        ;; a point at the origin lands 5 in front of the camera
        (v3~ (m4-transform v (v3 0 0 0)) 0.0 0.0 -5.0)))))

;; ---- the SIMD path agrees with the scalar one (to f32 lanes) ----
(define simd-ok
  (let* ((a (m4-mul (m4-perspective 0.9 1.5 0.1 100.0)
                    (m4-look-at (v3 3.0 4.0 5.0) (v3 0.0 1.0 0.0)
                                (v3 0.0 1.0 0.0))))
         (b (m4-mul (m4-translate 1.0 2.0 3.0) (m4-rotate-y 0.7)))
         (scalar (m4-mul a b)))
    (m4-scratch! 4096)                   ; SIMD on...
    (let ((wide (m4-mul a b)))
      (m4-scratch! #f)                   ; ...and off again
      (let lane ((i 0))
        (or (= i 16)
            (let* ((s (vector-ref scalar i))
                   (w (vector-ref wide i))
                   (d (if (fl<? s w) (fl- w s) (fl- s w)))
                   (m (if (fl<? s 0.0) (fl- 0.0 s) s)))
              (and (fl<? d (fl+ 0.0001 (fl* 0.00001 m)))
                   (lane (+ i 1)))))))))

(and main-ok simd-ok)
