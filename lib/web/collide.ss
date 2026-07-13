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
;;   (capsule-sphere? p q cr c r)       -- capsule = segment p..q + cr
;;   (capsule-capsule? p1 q1 r1 p2 q2 r2)
;;   (capsule-aabb? p q cr bmin bmax)
;;   (sweep-sphere-aabb c r motion bmin bmax)
;;                                      -> (t . normal) | #f: the first
;;                                         contact along c + t*motion,
;;                                         t in [0,1] (tunnel-proof)
;;   (move-and-slide pos r motion boxes)-> new pos: advance to contact,
;;                                         drop the normal component,
;;                                         continue -- walls slide,
;;                                         corners stop
;;
;; Ray directions must be unit vectors (v3-normalize) so distances
;; come back in world units.  Triangles hit from either side.
;; The sweep inflates the box by r (Minkowski), so corners are a
;; whisker square instead of round -- invisible at game radii.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web collide)
  (export sphere-sphere? aabb-aabb? sphere-aabb?
          capsule-sphere? capsule-capsule? capsule-aabb?
          ray-sphere ray-aabb ray-plane ray-triangle ray-mesh
          sphere-aabb-push sweep-sphere-aabb move-and-slide)
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
              (fl* bz (fl+ best-d r))))))))

  ;; ---- capsules: a segment p..q wearing a radius ----
  (define ($col-on-seg p q x)           ; closest point of p..q to x
    (let* ((d (v3-sub q p))
           (l2 (v3-dot d d)))
      (if (fl<? l2 $col-eps)
          p
          (let ((t ($col-clamp (fl/ (v3-dot (v3-sub x p) d) l2) 0.0 1.0)))
            (v3-add p (v3-scale d t))))))

  (define (capsule-sphere? p q cr c r)
    (let* ((n (v3-sub c ($col-on-seg p q c)))
           (rr (fl+ ($col-fl cr) ($col-fl r))))
      (fl<? (v3-dot n n) (fl* rr rr))))

  ;; squared distance between two segments (Ericson 5.1.9)
  (define ($col-seg-seg-d2 p1 q1 p2 q2)
    (let* ((d1 (v3-sub q1 p1)) (d2 (v3-sub q2 p2)) (rv (v3-sub p1 p2))
           (a (v3-dot d1 d1)) (e (v3-dot d2 d2)) (f (v3-dot d2 rv)))
      (let-values
          (((s t)
            (cond
             ((and (fl<? a $col-eps) (fl<? e $col-eps)) (values 0.0 0.0))
             ((fl<? a $col-eps) (values 0.0 ($col-clamp (fl/ f e) 0.0 1.0)))
             (else
              (let ((c (v3-dot d1 rv)))
                (if (fl<? e $col-eps)
                    (values ($col-clamp (fl/ (fl- 0.0 c) a) 0.0 1.0) 0.0)
                    (let* ((b (v3-dot d1 d2))
                           (den (fl- (fl* a e) (fl* b b)))
                           (s (if (fl<? $col-eps den)
                                  ($col-clamp (fl/ (fl- (fl* b f) (fl* c e))
                                                   den)
                                              0.0 1.0)
                                  0.0))
                           (t (fl/ (fl+ (fl* b s) f) e)))
                      (cond
                       ((fl<? t 0.0)
                        (values ($col-clamp (fl/ (fl- 0.0 c) a) 0.0 1.0) 0.0))
                       ((fl<? 1.0 t)
                        (values ($col-clamp (fl/ (fl- b c) a) 0.0 1.0) 1.0))
                       (else (values s t))))))))))
        (let ((w (v3-sub (v3-add p1 (v3-scale d1 s))
                         (v3-add p2 (v3-scale d2 t)))))
          (v3-dot w w)))))

  (define (capsule-capsule? p1 q1 r1 p2 q2 r2)
    (let ((rr (fl+ ($col-fl r1) ($col-fl r2))))
      (fl<? ($col-seg-seg-d2 p1 q1 p2 q2) (fl* rr rr))))

  (define ($col-pt-aabb-d2 x bmin bmax)
    (let ((d (v3-sub x ($col-closest x bmin bmax))))
      (v3-dot d d)))

  ;; a segment point's distance to the box is convex in the segment
  ;; parameter, so a ternary search nails the minimum
  (define (capsule-aabb? p q cr bmin bmax)
    (let ((d (v3-sub q p))
          (cr ($col-fl cr)))
      (define (d2-at t)
        ($col-pt-aabb-d2 (v3-add p (v3-scale d t)) bmin bmax))
      (let loop ((lo 0.0) (hi 1.0) (k 0))
        (if (= k 48)
            (fl<? (d2-at (fl* 0.5 (fl+ lo hi))) (fl* cr cr))
            (let ((m1 (fl+ lo (fl* (fl- hi lo) 0.333333)))
                  (m2 (fl- hi (fl* (fl- hi lo) 0.333333))))
              (if (fl<? (d2-at m1) (d2-at m2))
                  (loop lo m2 (+ k 1))
                  (loop m1 hi (+ k 1))))))))

  ;; ---- the sweep: where along c + t*motion does the sphere first
  ;; touch the box?  Minkowski: inflate the box by r and walk the
  ;; slabs, remembering which axis closed the entry -- that face's
  ;; normal is the contact normal.  Returns (t . normal) or #f.
  ;; Already touching returns t = 0 with the shortest way out, so a
  ;; caller can always slide on the result.
  (define (sweep-sphere-aabb c r motion bmin bmax)
    (let ((r ($col-fl r)))
      (if (sphere-aabb? c r bmin bmax)
          (let ((push (sphere-aabb-push c r bmin bmax)))
            (cons 0.0 (if push (v3-normalize push) (v3 0.0 1.0 0.0))))
          (let ((os (vector (v3-x c) (v3-y c) (v3-z c)))
                (ds (vector (v3-x motion) (v3-y motion) (v3-z motion)))
                (los (vector (fl- (v3-x bmin) r) (fl- (v3-y bmin) r)
                             (fl- (v3-z bmin) r)))
                (his (vector (fl+ (v3-x bmax) r) (fl+ (v3-y bmax) r)
                             (fl+ (v3-z bmax) r))))
            (let loop ((i 0) (tmin -1000000000.0) (tmax 1000000000.0)
                       (axis 0) (sign 0.0))
              (if (= i 3)
                  (and (fl<? tmin tmax) (fl<? 0.0 tmax) (fl<? tmin 1.0)
                       (if (fl<? tmin 0.0)
                           ;; inside the inflated corner shell only:
                           ;; touching for the sweep's purposes
                           (cons 0.0 (v3-normalize
                                      (v3-sub c ($col-closest c bmin bmax))))
                           (cons tmin
                                 (v3 (if (= axis 0) sign 0.0)
                                     (if (= axis 1) sign 0.0)
                                     (if (= axis 2) sign 0.0)))))
                  (let ((o (vector-ref os i)) (d (vector-ref ds i))
                        (lo (vector-ref los i)) (hi (vector-ref his i)))
                    (if (fl<? ($col-abs d) $col-eps)
                        (and (fl<? lo o) (fl<? o hi)
                             (loop (+ i 1) tmin tmax axis sign))
                        (let* ((t1 (fl/ (fl- lo o) d))
                               (t2 (fl/ (fl- hi o) d))
                               (ta ($col-min t1 t2))
                               (tb ($col-max t1 t2)))
                          (if (fl<? tmin ta)
                              (loop (+ i 1) ta ($col-min tmax tb)
                                    i (if (fl<? 0.0 d) -1.0 1.0))
                              (loop (+ i 1) tmin ($col-min tmax tb)
                                    axis sign)))))))))))

  ;; ---- the character controller loop, packaged ----
  ;; boxes is a list of (bmin . bmax) pairs.  Advance to the first
  ;; contact, keep a skin's breadth off the face, shed the motion's
  ;; into-the-wall component, and continue with what remains: walls
  ;; slide, corners stop.  Three passes bound the worst corner.
  (define $col-skin 0.001)
  (define (move-and-slide pos r motion boxes)
    (let go ((pos pos) (m motion) (k 0))
      (if (or (= k 3) (fl<? (v3-dot m m) $col-eps))
          pos
          (let scan ((bs boxes) (best #f))
            (cond
             ((pair? bs)
              (let ((hit (sweep-sphere-aabb pos r m
                                            (car (car bs)) (cdr (car bs)))))
                (scan (cdr bs)
                      (if (and hit (or (not best) (fl<? (car hit) (car best))))
                          hit
                          best))))
             ((not best) (v3-add pos m))
             (else
              (let* ((t (car best))
                     (n (cdr best))
                     (at (v3-add (v3-add pos (v3-scale m t))
                                 (v3-scale n $col-skin)))
                     (rem (v3-scale m (fl- 1.0 t)))
                     (slide (v3-sub rem (v3-scale n (v3-dot rem n)))))
                (go at slide (+ k 1))))))))))

