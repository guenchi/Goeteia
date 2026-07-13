;; Collision tests and raycasts for 3D games: spheres, axis-aligned
;; boxes, planes, triangles, and (web mesh) meshes, over (web mat)'s
;; v3.  Pure arithmetic -- no host, verifies headlessly -- and enough
;; for the classic game loop: "did I hit a wall" (sphere-aabb-push
;; slides the player out), "what did I shoot / click" (ray-mesh),
;; "how high is the ground here" (ray-plane).
;;
;;   (ray-sphere origin dir center r)   -> distance | #f
;;   (ray-aabb origin dir bmin bmax)    -> distance | #f (0.0 inside)
;;   (ray-plane origin dir point normal)-> distance | #f
;;   (ray-triangle origin dir a b c)    -> distance | #f
;;   (ray-mesh origin dir mesh)         -> distance | #f
;;   (sphere-sphere? c1 r1 c2 r2)       (aabb-aabb? min1 max1 min2 max2)
;;   (sphere-aabb? c r bmin bmax)       -- exact touching is not overlap
;;   (sphere-aabb-push c r bmin bmax)   -> v3 to move the sphere out,
;;                                         or #f when not overlapping
;;
;; Ray directions must be unit vectors (v3-normalize) so distances
;; come back in world units.  Triangles hit from either side.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web collide)
  (export sphere-sphere? aabb-aabb? sphere-aabb?
          ray-sphere ray-aabb ray-plane ray-triangle ray-mesh
          sphere-aabb-push)
  (import (rnrs) (web mat) (web mesh))

  (define $col-eps 0.000000001)

  (define ($col-abs x) (if (fl<? x 0.0) (fl- 0.0 x) x))
  (define ($col-min a b) (if (fl<? a b) a b))
  (define ($col-max a b) (if (fl<? a b) b a))
  (define ($col-clamp v lo hi)
    (if (fl<? v lo) lo (if (fl<? hi v) hi v)))
  ;; radii may arrive as fixnums from user code
  (define ($col-fl v) (if (flonum? v) v (exact->inexact v)))

  ;; ---- overlap tests ----
  (define (sphere-sphere? c1 r1 c2 r2)
    (let* ((d (v3-sub c1 c2))
           (rr (fl+ ($col-fl r1) ($col-fl r2))))
      (fl<? (v3-dot d d) (fl* rr rr))))

  (define (aabb-aabb? min1 max1 min2 max2)
    (and (fl<? (v3-x min1) (v3-x max2)) (fl<? (v3-x min2) (v3-x max1))
         (fl<? (v3-y min1) (v3-y max2)) (fl<? (v3-y min2) (v3-y max1))
         (fl<? (v3-z min1) (v3-z max2)) (fl<? (v3-z min2) (v3-z max1))))

  (define ($col-closest c bmin bmax)    ; nearest point of the box to c
    (v3 ($col-clamp (v3-x c) (v3-x bmin) (v3-x bmax))
        ($col-clamp (v3-y c) (v3-y bmin) (v3-y bmax))
        ($col-clamp (v3-z c) (v3-z bmin) (v3-z bmax))))

  (define (sphere-aabb? c r bmin bmax)
    (let* ((d (v3-sub c ($col-closest c bmin bmax)))
           (r ($col-fl r)))
      (fl<? (v3-dot d d) (fl* r r))))

  ;; ---- raycasts: dir is a unit vector, results are distances ----
  (define (ray-sphere o d c r)
    (let* ((oc (v3-sub o c))
           (b (v3-dot oc d))
           (r ($col-fl r))
           (disc (fl- (fl* b b) (fl- (v3-dot oc oc) (fl* r r)))))
      (if (fl<? disc 0.0)
          #f
          (let* ((s (flsqrt disc))
                 (t (fl- (fl- 0.0 b) s)))
            (cond
             ((fl<? 0.0 t) t)
             ((fl<? 0.0 (fl+ (fl- 0.0 b) s)) (fl+ (fl- 0.0 b) s))
             (else #f))))))

  ;; one slab of the box; #f = the ray misses it outright
  (define ($col-slab o d lo hi span)    ; span = (tmin . tmax) so far
    (if (fl<? ($col-abs d) $col-eps)
        (if (or (fl<? o lo) (fl<? hi o)) #f span)
        (let* ((t1 (fl/ (fl- lo o) d))
               (t2 (fl/ (fl- hi o) d))
               (ta ($col-min t1 t2))
               (tb ($col-max t1 t2)))
          (cons ($col-max (car span) ta)
                ($col-min (cdr span) tb)))))

  (define (ray-aabb o d bmin bmax)
    (let* ((s (cons -1000000000.0 1000000000.0))
           (s (and s ($col-slab (v3-x o) (v3-x d) (v3-x bmin) (v3-x bmax) s)))
           (s (and s ($col-slab (v3-y o) (v3-y d) (v3-y bmin) (v3-y bmax) s)))
           (s (and s ($col-slab (v3-z o) (v3-z d) (v3-z bmin) (v3-z bmax) s))))
      (and s
           (let ((tmin (car s)) (tmax (cdr s)))
             (cond
              ((fl<? tmax tmin) #f)     ; slabs never overlap
              ((fl<? tmax 0.0) #f)      ; the box is behind the ray
              ((fl<? tmin 0.0) 0.0)     ; the ray starts inside
              (else tmin))))))

  (define (ray-plane o d p n)
    (let ((denom (v3-dot n d)))
      (if (fl<? ($col-abs denom) $col-eps)
          #f
          (let ((t (fl/ (v3-dot n (v3-sub p o)) denom)))
            (and (fl<? 0.0 t) t)))))

  ;; Moller-Trumbore, hits from either side
  (define (ray-triangle o d a b c)
    (let* ((e1 (v3-sub b a))
           (e2 (v3-sub c a))
           (pv (v3-cross d e2))
           (det (v3-dot e1 pv)))
      (if (fl<? ($col-abs det) $col-eps)
          #f
          (let* ((inv (fl/ 1.0 det))
                 (tv (v3-sub o a))
                 (u (fl* (v3-dot tv pv) inv)))
            (if (or (fl<? u 0.0) (fl<? 1.0 u))
                #f
                (let* ((qv (v3-cross tv e1))
                       (v (fl* (v3-dot d qv) inv)))
                  (if (or (fl<? v 0.0) (fl<? 1.0 (fl+ u v)))
                      #f
                      (let ((t (fl* (v3-dot e2 qv) inv)))
                        (and (fl<? $col-eps t) t)))))))))

  ;; nearest triangle of a (web mesh) mesh; brute force -- picking
  ;; and shot tests over generated geometry, not broadphase physics
  (define (ray-mesh o d m)
    (let ((vs (mesh-verts m))
          (ix (mesh-indices m)))
      (define (vert k)                  ; position of vertex k
        (let ((b (* k 6)))
          (v3 (vector-ref vs b)
              (vector-ref vs (+ b 1))
              (vector-ref vs (+ b 2)))))
      (let loop ((i 0) (best #f))
        (if (>= i (vector-length ix))
            best
            (let ((t (ray-triangle o d
                                   (vert (vector-ref ix i))
                                   (vert (vector-ref ix (+ i 1)))
                                   (vert (vector-ref ix (+ i 2))))))
              (loop (+ i 3)
                    (if (and t (or (not best) (fl<? t best))) t best)))))))

  ;; how to move a sphere out of a box: the shortest push, as a v3.
  ;; The everyday use is sliding movement -- add the push to the
  ;; player's position and motion along the wall survives.
  (define (sphere-aabb-push c r bmin bmax)
    (let* ((r ($col-fl r))
           (closest ($col-closest c bmin bmax))
           (delta (v3-sub c closest))
           (d2 (v3-dot delta delta)))
      (cond
       ((fl<? (fl* r r) d2) #f)         ; clear of the box
       ((fl<? 0.0 d2)                   ; centre outside: push along delta
        (let ((dist (flsqrt d2)))
          (v3-scale delta (fl/ (fl- r dist) dist))))
       (else                            ; centre inside: cheapest face out
        (let ((best-d 1000000000.0) (bx 0.0) (by 0.0) (bz 0.0))
          (define (face! d x y z)
            (when (fl<? d best-d)
              (set! best-d d) (set! bx x) (set! by y) (set! bz z)))
          (face! (fl- (v3-x c) (v3-x bmin)) -1.0 0.0 0.0)
          (face! (fl- (v3-x bmax) (v3-x c)) 1.0 0.0 0.0)
          (face! (fl- (v3-y c) (v3-y bmin)) 0.0 -1.0 0.0)
          (face! (fl- (v3-y bmax) (v3-y c)) 0.0 1.0 0.0)
          (face! (fl- (v3-z c) (v3-z bmin)) 0.0 0.0 -1.0)
          (face! (fl- (v3-z bmax) (v3-z c)) 0.0 0.0 1.0)
          (v3 (fl* bx (fl+ best-d r))
              (fl* by (fl+ best-d r))
              (fl* bz (fl+ best-d r)))))))))

