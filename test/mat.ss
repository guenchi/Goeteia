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
 ;; a quaternion for 90 degrees about y matches m4-rotate-y
 (let ((s (flsin (fl/ pi 4.0))) (c (flcos (fl/ pi 4.0))))
   (m4~ (m4-from-quat 0.0 s 0.0 c) (m4-rotate-y (fl/ pi 2.0))))
 (m4~ (m4-from-quat 0.0 0.0 0.0 1.0) (m4-identity))
 ;; look-at from +z: axis-aligned view, eye distance in m14
 (let ((v (m4-look-at (v3 0 0 5) (v3 0 0 0) (v3 0 1 0))))
   (and (near? (vector-ref v 0) 1.0)
        (near? (vector-ref v 5) 1.0)
        (near? (vector-ref v 10) 1.0)
        (near? (vector-ref v 14) -5.0)
        ;; a point at the origin lands 5 in front of the camera
        (v3~ (m4-transform v (v3 0 0 0)) 0.0 0.0 -5.0))))
