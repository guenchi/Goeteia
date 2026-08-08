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
(library (gfx mat)
  (export flsin flcos fltan
          flasin flacos flatan flatan2
          q-mul q-conj q-neg q-dot q-normalize q-slerp
          v3 v3-x v3-y v3-z
          v3-add v3-sub v3-scale v3-dot v3-cross v3-normalize
          v3-set! v3-copy! v3-add! v3-sub! v3-scale! v3-cross!
          v3-normalize!
          m4-identity m4-mul m4-scratch! m4-transform
          m4s-write! m4s-read m4s-identity! m4s-mul! m4s-trs!
          m4s-tqs!
          m4-translate m4-scale m4-rotate-x m4-rotate-y m4-rotate-z
          m4-from-quat m4-perspective m4-ortho m4-look-at
          m4-inverse m4-unproject
          m4-frustum-planes sphere-in-frustum? sphere-in-frustum-xyz?)
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

  ;; ---- inverse trig: reduce to one small interval, one series ----
  ;; wasm has no inverse trigonometry either, so these are built the
  ;; same way as flsin: fold the argument into an interval where one
  ;; series converges fast, sum it, and put the answer back with an
  ;; identity.  Both series stop at the first term whose magnitude is
  ;; below 1e-18 -- compared squared, the prelude has no flabs -- so
  ;; what is left is the reductions' few ulps.  Swept against a
  ;; host's Math at 20001 points each, the worst gap was 1.4e-15
  ;; (acos) and under 1e-15 for the other three: the guarantee these
  ;; carry is 1e-7 over the whole domain, which is the accuracy
  ;; test/mat-invtrig.ss holds them to against that second
  ;; implementation.
  ;;
  ;; Arguments are flonums, as for flsin -- these sit in the same
  ;; per-frame paths.
  (define $mat-pi/4 0.7853981633974483)
  (define $mat-tan-pi/8 0.41421356237309515)  ; sqrt(2) - 1

  ;; asin on |x| <= 1/2 by its Maclaurin series x + x^3/6 + 3x^5/40
  ;; + ..., each term from the one before:
  ;;   t_n = t_{n-1} * x^2 * (2n-1)^2 / ((2n)(2n+1))
  ;; The ratio rises to x^2 <= 1/4, so the cutoff arrives within
  ;; ~30 terms at the interval's edge and at once at its center.
  ;; The term count is capped as well: no comparison against a NaN
  ;; is ever true, and a summation that only knows how to stop on
  ;; one would hang the frame instead of returning a NaN
  (define $mat-series-cap 64.0)
  ;; 1e-18, and its square: the reader of the self-hosted compiler
  ;; has no exponent syntax, so small constants are written out
  (define $mat-series-eps 0.000000000000000001)
  (define $mat-series-eps2 (fl* $mat-series-eps $mat-series-eps))
  (define ($mat-asin-poly x)            ; |x| <= 0.5
    (let ((x2 (fl* x x)))
      (let sum ((n 1.0) (term x) (acc x))
        (let* ((e (fl* 2.0 n))
               (o (fl- e 1.0))
               (term (fl/ (fl* term (fl* x2 (fl* o o)))
                          (fl* e (fl+ e 1.0)))))
          (if (or (fl<? (fl* term term) $mat-series-eps2)
                  (fl<? $mat-series-cap n))
              (fl+ acc term)
              (sum (fl+ n 1.0) term (fl+ acc term)))))))

  ;; atan on |t| <= tan(pi/8) by Gregory's series t - t^3/3 + t^5/5
  ;; - ...; the ratio is t^2 <= 0.172, so ~21 terms reach the cutoff
  (define ($mat-atan-poly t)            ; |t| <= tan(pi/8)
    (let ((t2 (fl* t t)))
      (let sum ((n 1.0) (p (fl* t t2)) (sgn -1.0) (acc t))
        (let ((term (fl* sgn (fl/ p (fl+ (fl* 2.0 n) 1.0)))))
          (if (or (fl<? (fl* term term) $mat-series-eps2)
                  (fl<? $mat-series-cap n))
              (fl+ acc term)
              (sum (fl+ n 1.0) (fl* p t2) (fl- 0.0 sgn)
                   (fl+ acc term)))))))

  ;; halve the argument once with asin x = pi/2 - 2 asin(sqrt((1-x)/2))
  ;; so that |x| > 1/2 lands back in the series' interval -- and so
  ;; that the answer near |x| = 1, where the series itself converges
  ;; arbitrarily slowly, comes out of a well-conditioned sqrt.
  ;;
  ;; |x| > 1 is CLAMPED, not rejected: a dot product of two unit
  ;; vectors leaves [-1, 1] by an ulp or two as a matter of course,
  ;; and an angle of NaN poisons everything downstream of it.
  (define ($mat-asin-unit x)            ; 0 <= x, clamped at 1
    (if (fl<? x 0.5)
        ($mat-asin-poly x)
        (fl- $mat-pi/2
             (fl* 2.0 ($mat-asin-poly
                       (flsqrt (fl* 0.5 (fl- 1.0 (if (fl<? 1.0 x) 1.0 x)))))))))

  (define (flasin x)
    (if (fl<? x 0.0)
        (fl- 0.0 ($mat-asin-unit (fl- 0.0 x)))
        ($mat-asin-unit x)))

  ;; acos runs the half-angle identity in its own right rather than
  ;; subtracting flasin from pi/2: near |x| = 1 the difference would
  ;; cancel away the small answer's leading digits
  (define (flacos x)
    (cond ((fl<? 1.0 x) 0.0)            ; clamped, as for flasin
          ((fl<? x -1.0) $mat-pi)
          ((fl<? 0.5 x)
           (fl* 2.0 ($mat-asin-poly (flsqrt (fl* 0.5 (fl- 1.0 x))))))
          ((fl<? x -0.5)
           (fl- $mat-pi
                (fl* 2.0 ($mat-asin-poly
                          (flsqrt (fl* 0.5 (fl+ 1.0 x)))))))
          (else (fl- $mat-pi/2 ($mat-asin-poly x)))))

  ;; atan by two reductions: x > 1 goes through atan x = pi/2 -
  ;; atan(1/x) (which also answers +inf), then the remainder of
  ;; [tan(pi/8), 1] through atan x = pi/4 + atan((x-1)/(x+1))
  (define ($mat-atan-nonneg x)          ; 0 <= x, +inf included
    (if (fl<? 1.0 x)
        (fl- $mat-pi/2 ($mat-atan-unit (fl/ 1.0 x)))
        ($mat-atan-unit x)))
  (define ($mat-atan-unit x)            ; 0 <= x <= 1
    (if (fl<? $mat-tan-pi/8 x)
        (fl+ $mat-pi/4 ($mat-atan-poly (fl/ (fl- x 1.0) (fl+ x 1.0))))
        ($mat-atan-poly x)))
  (define (flatan x)
    (if (fl<? x 0.0)
        (fl- 0.0 ($mat-atan-nonneg (fl- 0.0 x)))
        ($mat-atan-nonneg x)))

  ;; the four-quadrant angle of (x, y), in (-pi, pi], signed as the
  ;; host's Math.atan2 is: y > 0 above the axis, +pi on the negative
  ;; x axis, 0 at the origin (where an angle is meaningless but a
  ;; NaN is worse).  Negative zero is NOT distinguished -- a y of
  ;; -0.0 reads as +0.0, so the negative x axis answers +pi where
  ;; the host would answer -pi
  (define (flatan2 y x)
    (cond ((fl<? 0.0 x) (flatan (fl/ y x)))
          ((fl<? x 0.0)
           (if (fl<? y 0.0)
               (fl- (flatan (fl/ y x)) $mat-pi)
               (fl+ (flatan (fl/ y x)) $mat-pi)))
          ((fl<? 0.0 y) $mat-pi/2)
          ((fl<? y 0.0) (fl- 0.0 $mat-pi/2))
          ;; both zero -- and a NaN argument lands here too, since
          ;; no comparison against one is true
          (else 0.0)))

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

  ;; destructive variants for per-frame loops: same math, the result
  ;; lands in dst (which may alias an operand) and dst returns, so
  ;; chains read as before but a hot path allocates its vectors once.
  ;; Arguments are assumed flonums -- these are the inner loop
  (define (v3-set! dst x y z)
    (vector-set! dst 0 ($mat-fl x))
    (vector-set! dst 1 ($mat-fl y))
    (vector-set! dst 2 ($mat-fl z))
    dst)
  (define (v3-copy! dst a)
    (vector-set! dst 0 (v3-x a))
    (vector-set! dst 1 (v3-y a))
    (vector-set! dst 2 (v3-z a))
    dst)
  (define (v3-add! dst a b)
    (vector-set! dst 0 (fl+ (v3-x a) (v3-x b)))
    (vector-set! dst 1 (fl+ (v3-y a) (v3-y b)))
    (vector-set! dst 2 (fl+ (v3-z a) (v3-z b)))
    dst)
  (define (v3-sub! dst a b)
    (vector-set! dst 0 (fl- (v3-x a) (v3-x b)))
    (vector-set! dst 1 (fl- (v3-y a) (v3-y b)))
    (vector-set! dst 2 (fl- (v3-z a) (v3-z b)))
    dst)
  (define (v3-scale! dst a s)
    (let ((s ($mat-fl s)))
      (vector-set! dst 0 (fl* (v3-x a) s))
      (vector-set! dst 1 (fl* (v3-y a) s))
      (vector-set! dst 2 (fl* (v3-z a) s))
      dst))
  (define (v3-cross! dst a b)           ; dst must not alias a or b
    (let ((ax (v3-x a)) (ay (v3-y a)) (az (v3-z a))
          (bx (v3-x b)) (by (v3-y b)) (bz (v3-z b)))
      (vector-set! dst 0 (fl- (fl* ay bz) (fl* az by)))
      (vector-set! dst 1 (fl- (fl* az bx) (fl* ax bz)))
      (vector-set! dst 2 (fl- (fl* ax by) (fl* ay bx)))
      dst))
  (define (v3-normalize! dst a)
    (let ((n (flsqrt (v3-dot a a))))
      (vector-set! dst 0 (fl/ (v3-x a) n))
      (vector-set! dst 1 (fl/ (v3-y a) n))
      (vector-set! dst 2 (fl/ (v3-z a) n))
      dst))

  ;; ---- mat4, column-major: m[col*4 + row] ----
  (define (m4-identity)
    (vector 1.0 0.0 0.0 0.0  0.0 1.0 0.0 0.0
            0.0 0.0 1.0 0.0  0.0 0.0 0.0 1.0))

  ;; hand these kernels 128 bytes of staging memory and m4-mul goes
  ;; wide: each result column is one f32x4 scale and three axpys
  ;; instead of sixteen scalar multiply-adds over boxed reads.
  ;; fx-init! wires this up automatically; without it the scalar
  ;; path runs (headless math tests exercise both).  The lanes are
  ;; f32 -- matrices bound for the GPU lose nothing
  (define $mat-scratch #f)
  (define (m4-scratch! base) (set! $mat-scratch base))

  (define ($m4-mul-simd a b s)
    (let ((m (make-vector 16 0.0))
          (cbase (+ s 64)))
      (let in ((k 0))                   ; A's columns, once, as f32
        (when (< k 16)
          (%mem-f32-set! (+ s (* k 4)) (vector-ref a k))
          (in (+ k 1))))
      (let col ((c 0))                  ; C[:,c] = sum A[:,k] * b_kc
        (when (< c 4)
          (let ((dst (+ cbase (* c 16)))
                (bc (* c 4)))
            (%f32x4-scale! dst s (vector-ref b bc))
            (%f32x4-axpy! dst dst (+ s 16) (vector-ref b (+ bc 1)))
            (%f32x4-axpy! dst dst (+ s 32) (vector-ref b (+ bc 2)))
            (%f32x4-axpy! dst dst (+ s 48) (vector-ref b (+ bc 3))))
          (col (+ c 1))))
      (let out ((k 0))
        (when (< k 16)
          (vector-set! m k (%mem-f32-ref (+ cbase (* k 4))))
          (out (+ k 1))))
      m))

  ;; ---- staging-resident matrices: the copy tax refunded ----
  ;; An m4s is a byte address of sixteen f32 in the linear memory.
  ;; Chains multiply entirely in SIMD -- no boxed reads in, no boxed
  ;; vector out -- and consumers that live in staging anyway
  ;; (instance buffers, uniform uploads) read the bytes where they
  ;; already are.  Convert at the edges with m4s-write!/m4s-read.
  (define (m4s-write! at m)             ; vector -> staging
    (let put ((k 0))
      (when (< k 16)
        (%mem-f32-set! (+ at (* k 4)) (vector-ref m k))
        (put (+ k 1)))))

  (define (m4s-read at)                 ; staging -> vector
    (let ((m (make-vector 16 0.0)))
      (let get ((k 0))
        (when (< k 16)
          (vector-set! m k (%mem-f32-ref (+ at (* k 4))))
          (get (+ k 1))))
      m))

  (define (m4s-identity! at)
    (let put ((k 0))
      (when (< k 16)
        (%mem-f32-set! (+ at (* k 4))
                       (if (= 0 (remainder k 5)) 1.0 0.0))
        (put (+ k 1)))))

  ;; dst = a x b, pure SIMD: one scale and three axpys per column,
  ;; scalars loaded straight from staging through the f64 context.
  ;; dst must not alias a or b (the columns land as they compute)
  (define (m4s-mul! dst a b)
    (let col ((c 0))
      (when (< c 4)
        (let ((d (+ dst (* c 16)))
              (bc (+ b (* c 16))))
          (%f32x4-scale! d a (%mem-f32-ref bc))
          (%f32x4-axpy! d d (+ a 16) (%mem-f32-ref (+ bc 4)))
          (%f32x4-axpy! d d (+ a 32) (%mem-f32-ref (+ bc 8)))
          (%f32x4-axpy! d d (+ a 48) (%mem-f32-ref (+ bc 12))))
        (col (+ c 1)))))

  ;; the whole T x Ry x Rx x Rz x S(s) composite in closed form,
  ;; written straight into staging -- the per-object matrix every
  ;; scene rebuilds each frame, without four constructors and three
  ;; multiplies' worth of boxed intermediates
  (define (m4s-trs! at px py pz rx ry rz s)
    (let* ((s ($mat-fl s))
           (cx (flcos ($mat-fl rx))) (sx (flsin ($mat-fl rx)))
           (cy (flcos ($mat-fl ry))) (sy (flsin ($mat-fl ry)))
           (cz (flcos ($mat-fl rz))) (sz (flsin ($mat-fl rz))))
      (%mem-f32-set! at (fl* s (fl+ (fl* cy cz) (fl* sy (fl* sx sz)))))
      (%mem-f32-set! (+ at 4) (fl* s (fl* cx sz)))
      (%mem-f32-set! (+ at 8)
                     (fl* s (fl+ (fl- 0.0 (fl* sy cz))
                                 (fl* cy (fl* sx sz)))))
      (%mem-f32-set! (+ at 12) 0.0)
      (%mem-f32-set! (+ at 16)
                     (fl* s (fl+ (fl- 0.0 (fl* cy sz))
                                 (fl* sy (fl* sx cz)))))
      (%mem-f32-set! (+ at 20) (fl* s (fl* cx cz)))
      (%mem-f32-set! (+ at 24)
                     (fl* s (fl+ (fl* sy sz) (fl* cy (fl* sx cz)))))
      (%mem-f32-set! (+ at 28) 0.0)
      (%mem-f32-set! (+ at 32) (fl* s (fl* sy cx)))
      (%mem-f32-set! (+ at 36) (fl* s (fl- 0.0 sx)))
      (%mem-f32-set! (+ at 40) (fl* s (fl* cy cx)))
      (%mem-f32-set! (+ at 44) 0.0)
      (%mem-f32-set! (+ at 48) ($mat-fl px))
      (%mem-f32-set! (+ at 52) ($mat-fl py))
      (%mem-f32-set! (+ at 56) ($mat-fl pz))
      (%mem-f32-set! (+ at 60) 1.0)))

  ;; T x R(quat) x S in closed form, straight into staging: the local
  ;; matrix every skeleton node rebuilds each frame (glTF nodes carry
  ;; translation/rotation-quaternion/scale), without a constructor
  ;; chain's boxed intermediates.  The quaternion is assumed unit
  (define (m4s-tqs! at tx ty tz qx qy qz qw sx sy sz)
    (let* ((qx ($mat-fl qx)) (qy ($mat-fl qy))
           (qz ($mat-fl qz)) (qw ($mat-fl qw))
           (sx ($mat-fl sx)) (sy ($mat-fl sy)) (sz ($mat-fl sz))
           (xx (fl* qx qx)) (yy (fl* qy qy)) (zz (fl* qz qz))
           (xy (fl* qx qy)) (xz (fl* qx qz)) (yz (fl* qy qz))
           (wx (fl* qw qx)) (wy (fl* qw qy)) (wz (fl* qw qz)))
      (%mem-f32-set! at (fl* sx (fl- 1.0 (fl* 2.0 (fl+ yy zz)))))
      (%mem-f32-set! (+ at 4) (fl* sx (fl* 2.0 (fl+ xy wz))))
      (%mem-f32-set! (+ at 8) (fl* sx (fl* 2.0 (fl- xz wy))))
      (%mem-f32-set! (+ at 12) 0.0)
      (%mem-f32-set! (+ at 16) (fl* sy (fl* 2.0 (fl- xy wz))))
      (%mem-f32-set! (+ at 20) (fl* sy (fl- 1.0 (fl* 2.0 (fl+ xx zz)))))
      (%mem-f32-set! (+ at 24) (fl* sy (fl* 2.0 (fl+ yz wx))))
      (%mem-f32-set! (+ at 28) 0.0)
      (%mem-f32-set! (+ at 32) (fl* sz (fl* 2.0 (fl+ xz wy))))
      (%mem-f32-set! (+ at 36) (fl* sz (fl* 2.0 (fl- yz wx))))
      (%mem-f32-set! (+ at 40) (fl* sz (fl- 1.0 (fl* 2.0 (fl+ xx yy)))))
      (%mem-f32-set! (+ at 44) 0.0)
      (%mem-f32-set! (+ at 48) ($mat-fl tx))
      (%mem-f32-set! (+ at 52) ($mat-fl ty))
      (%mem-f32-set! (+ at 56) ($mat-fl tz))
      (%mem-f32-set! (+ at 60) 1.0)))

  (define (m4-mul a b)                  ; (m4-mul a b) transforms as a after b
    (if $mat-scratch
        ($m4-mul-simd a b $mat-scratch)
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
          m)))

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

  ;; ---- quaternion algebra ----
  ;; A quaternion is a 4-element vector #(x y z w), the shape
  ;; (gfx gltf) stores node rotations in and the shape q-slerp and
  ;; m4-from-quat already speak.  Like the rest of this file the
  ;; operations assume flonum components -- they are the per-frame
  ;; hot path, and a glTF rotation read out of the node table is
  ;; flonum in every lane.
  ;;
  ;; These were written three times over before they were written
  ;; once: a retarget kept its own norm/dot/negate, a fitting loop
  ;; its own Hamilton product.  The algebra is not application
  ;; knowledge and belongs here.

  (define (q-dot a b)
    (fl+ (fl+ (fl* (vector-ref a 0) (vector-ref b 0))
              (fl* (vector-ref a 1) (vector-ref b 1)))
         (fl+ (fl* (vector-ref a 2) (vector-ref b 2))
              (fl* (vector-ref a 3) (vector-ref b 3)))))

  ;; The Hamilton product, in the composition order rotation
  ;; matrices use: R(q-mul a b) = R(a) * R(b), so (q-mul q r) turns
  ;; q by r expressed in q's OWN frame -- which is what posing a
  ;; joint by a local twist means.  It is not commutative; swapping
  ;; the operands gives the other frame's answer.
  (define (q-mul a b)
    (let ((ax (vector-ref a 0)) (ay (vector-ref a 1))
          (az (vector-ref a 2)) (aw (vector-ref a 3))
          (bx (vector-ref b 0)) (by (vector-ref b 1))
          (bz (vector-ref b 2)) (bw (vector-ref b 3)))
      (vector (fl+ (fl+ (fl* aw bx) (fl* ax bw))
                   (fl- (fl* ay bz) (fl* az by)))
              (fl+ (fl+ (fl* aw by) (fl* ay bw))
                   (fl- (fl* az bx) (fl* ax bz)))
              (fl+ (fl+ (fl* aw bz) (fl* az bw))
                   (fl- (fl* ax by) (fl* ay bx)))
              (fl- (fl* aw bw)
                   (fl+ (fl+ (fl* ax bx) (fl* ay by)) (fl* az bz))))))

  ;; The conjugate: the vector part negated, the scalar part kept.
  ;; On a UNIT quaternion that is the inverse rotation, and
  ;; (q-mul q (q-conj q)) is the identity #(0 0 0 1).  On a
  ;; non-unit one it is not -- the product is the squared norm --
  ;; so normalize first if the input has been composed for a while.
  (define (q-conj q)
    (vector (fl- 0.0 (vector-ref q 0)) (fl- 0.0 (vector-ref q 1))
            (fl- 0.0 (vector-ref q 2)) (vector-ref q 3)))

  ;; Every component negated.  q and (q-neg q) are the SAME rotation
  ;; (the double cover), which is why a track that must not take the
  ;; long way round flips a key whose dot with the previous one is
  ;; negative.  Distinct from q-conj, which is a different rotation.
  (define (q-neg q)
    (vector (fl- 0.0 (vector-ref q 0)) (fl- 0.0 (vector-ref q 1))
            (fl- 0.0 (vector-ref q 2)) (fl- 0.0 (vector-ref q 3))))

  ;; Back onto the unit sphere.  A zero quaternion is not a rotation
  ;; and has no direction to keep, so it answers the identity rather
  ;; than NaNs: a chain of composed rotations that collapsed should
  ;; carry on posing something, and the caller who wants to know
  ;; asks q-dot of the input with itself.
  (define (q-normalize q)
    (let ((n (flsqrt (q-dot q q))))
      (if (fl<? 0.0 n)
          (vector (fl/ (vector-ref q 0) n) (fl/ (vector-ref q 1) n)
                  (fl/ (vector-ref q 2) n) (fl/ (vector-ref q 3) n))
          (vector 0.0 0.0 0.0 1.0))))

  ;; spherical linear interpolation between two unit quaternions
  ;; #(x y z w), the shape (gfx gltf) stores rotations in: the great
  ;; arc travelled at a CONSTANT angular rate, which is what an
  ;; nlerp of the same pair does not give (it takes the same path,
  ;; but eases in and out around the midpoint).  Antipodal inputs
  ;; name the same rotation, so a negative dot product flips b and
  ;; the short way round is always the one taken.
  ;;
  ;; t is not clamped: outside [0, 1] the arc continues past its
  ;; ends, which is what an extrapolating controller wants.  Within
  ;; a nine-digit dot product of parallel the two are lerped and
  ;; renormalized instead -- there the arc is shorter than the
  ;; rounding on sin of its angle, and dividing by that sine would
  ;; amplify it without bound.
  ;;
  ;; (gltf-animate! keeps its documented nlerp; this is for code
  ;; that wants the rate, e.g. an IK or camera solver.)
  (define (q-slerp a b t)
    (let* ((d (q-dot a b))
           (sgn (if (fl<? d 0.0) -1.0 1.0))
           (d (fl* sgn d))
           (blend
            (lambda (wa wb)              ; wa*a + wb*(sgn*b)
              (let ((wb (fl* wb sgn)))
                (vector (fl+ (fl* wa (vector-ref a 0))
                             (fl* wb (vector-ref b 0)))
                        (fl+ (fl* wa (vector-ref a 1))
                             (fl* wb (vector-ref b 1)))
                        (fl+ (fl* wa (vector-ref a 2))
                             (fl* wb (vector-ref b 2)))
                        (fl+ (fl* wa (vector-ref a 3))
                             (fl* wb (vector-ref b 3))))))))
      (if (fl<? 0.999999999 d)
          (q-normalize (blend (fl- 1.0 t) t))
          (let* ((th (flacos d))
                 ;; sin th, taken from th and not as sqrt(1 - d^2):
                 ;; at the near end of the range 1 - d^2 cancels to a
                 ;; few significant digits, and both weights would
                 ;; carry the same wrong scale -- a quaternion off
                 ;; the unit sphere, which is a rotation with a
                 ;; scale baked into it
                 (s (flsin th))
                 (wa (fl/ (flsin (fl* (fl- 1.0 t) th)) s))
                 (wb (fl/ (flsin (fl* t th)) s)))
            (blend wa wb)))))

  (define (m4-perspective fovy aspect near far)
    (let* ((f (fl/ 1.0 (fltan (fl/ ($mat-fl fovy) 2.0))))
           (near ($mat-fl near)) (far ($mat-fl far))
           (nf (fl/ 1.0 (fl- near far))))
      (vector (fl/ f ($mat-fl aspect)) 0.0 0.0 0.0
              0.0 f 0.0 0.0
              0.0 0.0 (fl* (fl+ far near) nf) -1.0
              0.0 0.0 (fl* 2.0 (fl* (fl* far near) nf)) 0.0)))

  (define (m4-ortho left right bottom top near far)
    (let* ((l ($mat-fl left)) (r ($mat-fl right))
           (b ($mat-fl bottom)) (t ($mat-fl top))
           (n ($mat-fl near)) (f ($mat-fl far)))
      (vector (fl/ 2.0 (fl- r l)) 0.0 0.0 0.0
              0.0 (fl/ 2.0 (fl- t b)) 0.0 0.0
              0.0 0.0 (fl/ -2.0 (fl- f n)) 0.0
              (fl/ (fl- 0.0 (fl+ r l)) (fl- r l))
              (fl/ (fl- 0.0 (fl+ t b)) (fl- t b))
              (fl/ (fl- 0.0 (fl+ f n)) (fl- f n)) 1.0)))

  ;; general 4x4 inverse by cofactor expansion; #f when singular.
  ;; the door to picking: invert the view-projection, unproject the
  ;; cursor, raycast with (gfx collide)
  (define (m4-inverse m)
    (define (a i) (vector-ref m i))
    (let* ((s0 (fl- (fl* (a 0) (a 5)) (fl* (a 4) (a 1))))
           (s1 (fl- (fl* (a 0) (a 9)) (fl* (a 8) (a 1))))
           (s2 (fl- (fl* (a 0) (a 13)) (fl* (a 12) (a 1))))
           (s3 (fl- (fl* (a 4) (a 9)) (fl* (a 8) (a 5))))
           (s4 (fl- (fl* (a 4) (a 13)) (fl* (a 12) (a 5))))
           (s5 (fl- (fl* (a 8) (a 13)) (fl* (a 12) (a 9))))
           (c5 (fl- (fl* (a 10) (a 15)) (fl* (a 14) (a 11))))
           (c4 (fl- (fl* (a 6) (a 15)) (fl* (a 14) (a 7))))
           (c3 (fl- (fl* (a 6) (a 11)) (fl* (a 10) (a 7))))
           (c2 (fl- (fl* (a 2) (a 15)) (fl* (a 14) (a 3))))
           (c1 (fl- (fl* (a 2) (a 11)) (fl* (a 10) (a 3))))
           (c0 (fl- (fl* (a 2) (a 7)) (fl* (a 6) (a 3))))
           (det (fl+ (fl- (fl+ (fl* s0 c5) (fl* s3 c2))
                          (fl+ (fl* s1 c4) (fl* s4 c1)))
                     (fl+ (fl* s2 c3) (fl* s5 c0)))))
      (if (and (fl<? det 0.000000000001)
               (fl<? -0.000000000001 det))
          #f
          (let ((r (fl/ 1.0 det)))
            (vector
             (fl* r (fl+ (fl- (fl* (a 5) c5) (fl* (a 9) c4))
                         (fl* (a 13) c3)))
             (fl* r (fl- (fl* (a 9) c2)
                         (fl+ (fl* (a 1) c5) (fl* (a 13) c1))))
             (fl* r (fl+ (fl- (fl* (a 1) c4) (fl* (a 5) c2))
                         (fl* (a 13) c0)))
             (fl* r (fl- (fl* (a 5) c1)
                         (fl+ (fl* (a 1) c3) (fl* (a 9) c0))))
             (fl* r (fl- (fl* (a 8) c4)
                         (fl+ (fl* (a 4) c5) (fl* (a 12) c3))))
             (fl* r (fl+ (fl- (fl* (a 0) c5) (fl* (a 8) c2))
                         (fl* (a 12) c1)))
             (fl* r (fl- (fl* (a 4) c2)
                         (fl+ (fl* (a 0) c4) (fl* (a 12) c0))))
             (fl* r (fl+ (fl- (fl* (a 0) c3) (fl* (a 4) c1))
                         (fl* (a 8) c0)))
             (fl* r (fl+ (fl- (fl* (a 7) s5) (fl* (a 11) s4))
                         (fl* (a 15) s3)))
             (fl* r (fl- (fl* (a 11) s2)
                         (fl+ (fl* (a 3) s5) (fl* (a 15) s1))))
             (fl* r (fl+ (fl- (fl* (a 3) s4) (fl* (a 7) s2))
                         (fl* (a 15) s0)))
             (fl* r (fl- (fl* (a 7) s1)
                         (fl+ (fl* (a 3) s3) (fl* (a 11) s0))))
             (fl* r (fl- (fl* (a 10) s4)
                         (fl+ (fl* (a 6) s5) (fl* (a 14) s3))))
             (fl* r (fl+ (fl- (fl* (a 2) s5) (fl* (a 10) s2))
                         (fl* (a 14) s1)))
             (fl* r (fl- (fl* (a 6) s2)
                         (fl+ (fl* (a 2) s4) (fl* (a 14) s0))))
             (fl* r (fl+ (fl- (fl* (a 2) s3) (fl* (a 6) s1))
                         (fl* (a 10) s0))))))))

  ;; NDC (x y in [-1,1], z in [-1,1]) back to world space through an
  ;; inverted view-projection: m4-transform already divides by w
  (define (m4-unproject inv-vp x y z)
    (m4-transform inv-vp (v3 x y z)))

  ;; the view frustum as six inward-facing planes #(nx ny nz d)
  ;; (Gribb-Hartmann rows of the view-projection), normalized so
  ;; nx*x + ny*y + nz*z + d is a true signed distance
  (define ($mat-plane m i sign)         ; row3 +/- row_i
    (define (r j) (vector-ref m (+ (* j 4) i)))
    (define (r3 j) (vector-ref m (+ (* j 4) 3)))
    (let* ((nx (fl+ (r3 0) (fl* sign (r 0))))
           (ny (fl+ (r3 1) (fl* sign (r 1))))
           (nz (fl+ (r3 2) (fl* sign (r 2))))
           (d (fl+ (r3 3) (fl* sign (r 3))))
           (len (flsqrt (fl+ (fl+ (fl* nx nx) (fl* ny ny))
                             (fl* nz nz)))))
      (vector (fl/ nx len) (fl/ ny len) (fl/ nz len) (fl/ d len))))

  (define (m4-frustum-planes vp)
    (vector ($mat-plane vp 0 1.0) ($mat-plane vp 0 -1.0)   ; left right
            ($mat-plane vp 1 1.0) ($mat-plane vp 1 -1.0)   ; bottom top
            ($mat-plane vp 2 1.0) ($mat-plane vp 2 -1.0))) ; near far

  ;; #f only when the sphere is entirely outside some plane, so a
  ;; #t is conservative -- exactly what a cull wants.  The -xyz
  ;; spelling takes the center unboxed -- per-frame culls compute
  ;; those scalars anyway and skip making a v3 of them
  (define (sphere-in-frustum-xyz? planes x y z r)
    (let ((r (fl- 0.0 ($mat-fl r))))
      (let each ((i 0))
        (or (= i 6)
            (let ((p (vector-ref planes i)))
              (let ((d (fl+ (fl+ (fl+ (fl* (vector-ref p 0) x)
                                       (fl* (vector-ref p 1) y))
                                  (fl* (vector-ref p 2) z))
                             (vector-ref p 3))))
                (and (not (fl<? d r))
                     (each (+ i 1)))))))))

  (define (sphere-in-frustum? planes c r)
    (sphere-in-frustum-xyz? planes (v3-x c) (v3-y c) (v3-z c) r))

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
