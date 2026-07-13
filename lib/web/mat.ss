;; 3D math for raw-GL scenes: vec3 and column-major mat4 over plain
;; flonum vectors.  Pure -- no host, verifies headlessly -- and the
;; trig is our own (range-reduced polynomials in flonum arithmetic),
;; so both compiler hosts emit identical bytes, the same reasoning
;; that computes IEEE bits for flonum literals in pure Scheme.
;;
;;   (define proj (m4-perspective 0.9 (/ 800.0 600.0) 0.1 100.0))
;;   (define view (m4-look-at (v3 0 0 6) (v3 0 0 0) (v3 0 1 0)))
;;   (fx-uniform! p 'u_mvp (m4-mul proj (m4-mul view (m4-rotate-y t))))
;;
;; A mat4 is a 16-element vector, column-major (what uniformMatrix4fv
;; expects; fx-uniform!'s mat4 case feeds it through the command
;; buffer).  Constructors coerce their arguments; the operations
;; assume flonums -- they are the per-frame hot path.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web mat)
  (export flsin flcos fltan
          v3 v3-x v3-y v3-z
          v3-add v3-sub v3-scale v3-dot v3-cross v3-normalize
          m4-identity m4-mul m4-transform
          m4-translate m4-scale m4-rotate-x m4-rotate-y m4-rotate-z
          m4-from-quat m4-perspective m4-look-at)
  (import (rnrs))

  (define ($mat-fl v) (if (flonum? v) v (exact->inexact v)))

  ;; ---- trig: reduce to [-pi/2, pi/2], one odd polynomial ----
  (define $mat-pi 3.141592653589793)
  (define $mat-2pi 6.283185307179586)
  (define $mat-pi/2 1.5707963267948966)

  (define ($mat-sin-poly x)             ; |x| <= pi/2, error < 1e-9
    (let ((x2 (fl* x x)))
      (fl* x
           (fl- 1.0 (fl* (fl/ x2 6.0)
                (fl- 1.0 (fl* (fl/ x2 20.0)
                     (fl- 1.0 (fl* (fl/ x2 42.0)
                          (fl- 1.0 (fl* (fl/ x2 72.0)
                               (fl- 1.0 (fl* (fl/ x2 110.0)
                                    (fl- 1.0 (fl* (fl/ x2 156.0)
                                         (fl- 1.0 (fl/ x2 210.0)))))))))))))))))

  (define (flsin x)
    (let* ((k (flfloor (fl+ (fl/ x $mat-2pi) 0.5)))
           (r (fl- x (fl* k $mat-2pi))))    ; r in [-pi, pi]
      ($mat-sin-poly
       (cond ((fl<? $mat-pi/2 r) (fl- $mat-pi r))
             ((fl<? r (fl- 0.0 $mat-pi/2)) (fl- (fl- 0.0 $mat-pi) r))
             (else r)))))
  (define (flcos x) (flsin (fl+ x $mat-pi/2)))
  (define (fltan x) (fl/ (flsin x) (flcos x)))

  ;; ---- vec3 ----
  (define (v3 x y z) (vector ($mat-fl x) ($mat-fl y) ($mat-fl z)))
  (define (v3-x v) (vector-ref v 0))
  (define (v3-y v) (vector-ref v 1))
  (define (v3-z v) (vector-ref v 2))
  (define (v3-add a b)
    (vector (fl+ (v3-x a) (v3-x b)) (fl+ (v3-y a) (v3-y b))
            (fl+ (v3-z a) (v3-z b))))
  (define (v3-sub a b)
    (vector (fl- (v3-x a) (v3-x b)) (fl- (v3-y a) (v3-y b))
            (fl- (v3-z a) (v3-z b))))
  (define (v3-scale a s)
    (let ((s ($mat-fl s)))
      (vector (fl* (v3-x a) s) (fl* (v3-y a) s) (fl* (v3-z a) s))))
  (define (v3-dot a b)
    (fl+ (fl+ (fl* (v3-x a) (v3-x b)) (fl* (v3-y a) (v3-y b)))
         (fl* (v3-z a) (v3-z b))))
  (define (v3-cross a b)
    (vector (fl- (fl* (v3-y a) (v3-z b)) (fl* (v3-z a) (v3-y b)))
            (fl- (fl* (v3-z a) (v3-x b)) (fl* (v3-x a) (v3-z b)))
            (fl- (fl* (v3-x a) (v3-y b)) (fl* (v3-y a) (v3-x b)))))
  (define (v3-normalize a)
    (let ((n (flsqrt (v3-dot a a))))
      (vector (fl/ (v3-x a) n) (fl/ (v3-y a) n) (fl/ (v3-z a) n))))

  ;; ---- mat4, column-major: m[col*4 + row] ----
  (define (m4-identity)
    (vector 1.0 0.0 0.0 0.0  0.0 1.0 0.0 0.0
            0.0 0.0 1.0 0.0  0.0 0.0 0.0 1.0))

  (define (m4-mul a b)                  ; (m4-mul a b) transforms as a after b
    (let ((m (make-vector 16 0.0)))
      (let col ((c 0))
        (when (< c 4)
          (let row ((r 0))
            (when (< r 4)
              (let sum ((k 0) (s 0.0))
                (if (= k 4)
                    (vector-set! m (+ (* c 4) r) s)
                    (sum (+ k 1)
                         (fl+ s (fl* (vector-ref a (+ (* k 4) r))
                                     (vector-ref b (+ (* c 4) k)))))))
              (row (+ r 1))))
          (col (+ c 1))))
      m))

  (define (m4-transform m v)            ; point transform, w-divided
    (let ((x (v3-x v)) (y (v3-y v)) (z (v3-z v)))
      (define (row r)
        (fl+ (fl+ (fl* (vector-ref m r) x)
                  (fl* (vector-ref m (+ r 4)) y))
             (fl+ (fl* (vector-ref m (+ r 8)) z)
                  (vector-ref m (+ r 12)))))
      (let ((w (row 3)))
        (vector (fl/ (row 0) w) (fl/ (row 1) w) (fl/ (row 2) w)))))

  (define (m4-translate x y z)
    (vector 1.0 0.0 0.0 0.0  0.0 1.0 0.0 0.0  0.0 0.0 1.0 0.0
            ($mat-fl x) ($mat-fl y) ($mat-fl z) 1.0))
  (define (m4-scale x y z)
    (vector ($mat-fl x) 0.0 0.0 0.0  0.0 ($mat-fl y) 0.0 0.0
            0.0 0.0 ($mat-fl z) 0.0  0.0 0.0 0.0 1.0))

  (define (m4-rotate-x t)
    (let* ((t ($mat-fl t)) (c (flcos t)) (s (flsin t)))
      (vector 1.0 0.0 0.0 0.0
              0.0 c s 0.0
              0.0 (fl- 0.0 s) c 0.0
              0.0 0.0 0.0 1.0)))
  (define (m4-rotate-y t)
    (let* ((t ($mat-fl t)) (c (flcos t)) (s (flsin t)))
      (vector c 0.0 (fl- 0.0 s) 0.0
              0.0 1.0 0.0 0.0
              s 0.0 c 0.0
              0.0 0.0 0.0 1.0)))
  (define (m4-rotate-z t)
    (let* ((t ($mat-fl t)) (c (flcos t)) (s (flsin t)))
      (vector c s 0.0 0.0
              (fl- 0.0 s) c 0.0 0.0
              0.0 0.0 1.0 0.0
              0.0 0.0 0.0 1.0)))

  (define (m4-from-quat x y z w)        ; a unit quaternion's rotation
    (let* ((x ($mat-fl x)) (y ($mat-fl y)) (z ($mat-fl z)) (w ($mat-fl w))
           (xx (fl* x x)) (yy (fl* y y)) (zz (fl* z z))
           (xy (fl* x y)) (xz (fl* x z)) (yz (fl* y z))
           (wx (fl* w x)) (wy (fl* w y)) (wz (fl* w z)))
      (vector (fl- 1.0 (fl* 2.0 (fl+ yy zz)))
              (fl* 2.0 (fl+ xy wz))
              (fl* 2.0 (fl- xz wy))
              0.0
              (fl* 2.0 (fl- xy wz))
              (fl- 1.0 (fl* 2.0 (fl+ xx zz)))
              (fl* 2.0 (fl+ yz wx))
              0.0
              (fl* 2.0 (fl+ xz wy))
              (fl* 2.0 (fl- yz wx))
              (fl- 1.0 (fl* 2.0 (fl+ xx yy)))
              0.0
              0.0 0.0 0.0 1.0)))

  (define (m4-perspective fovy aspect near far)
    (let* ((f (fl/ 1.0 (fltan (fl/ ($mat-fl fovy) 2.0))))
           (near ($mat-fl near)) (far ($mat-fl far))
           (nf (fl/ 1.0 (fl- near far))))
      (vector (fl/ f ($mat-fl aspect)) 0.0 0.0 0.0
              0.0 f 0.0 0.0
              0.0 0.0 (fl* (fl+ far near) nf) -1.0
              0.0 0.0 (fl* 2.0 (fl* (fl* far near) nf)) 0.0)))

  (define (m4-look-at eye center up)
    (let* ((z (v3-normalize (v3-sub eye center)))
           (x (v3-normalize (v3-cross up z)))
           (y (v3-cross z x)))
      (vector (v3-x x) (v3-x y) (v3-x z) 0.0
              (v3-y x) (v3-y y) (v3-y z) 0.0
              (v3-z x) (v3-z y) (v3-z z) 0.0
              (fl- 0.0 (v3-dot x eye))
              (fl- 0.0 (v3-dot y eye))
              (fl- 0.0 (v3-dot z eye)) 1.0))))
