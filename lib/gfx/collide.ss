;; Copyright 2026 guenchi
;;
;; Licensed under the Apache License, Version 2.0 (the "License");
;; you may not use this file except in compliance with the License.
;; You may obtain a copy of the License at
;;
;;     http://www.apache.org/licenses/LICENSE-2.0
;;
;; Unless required by applicable law or agreed to in writing, software
;; distributed under the License is distributed on an "AS IS" BASIS,
;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;; See the License for the specific language governing permissions and
;; limitations under the License.

;; Collision tests and raycasts for 3D games: spheres, axis-aligned
;; boxes, planes, triangles, and (gfx mesh) meshes, over (gfx mat)'s
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
;;   (make-character pos r)             -- gravity, landing and jumping
;;   (character-move! ch vx vz dt boxes)   packaged over the slide;
;;   (character-jump! ch speed)            grounded only
;;   (character-pos ch) (character-grounded? ch)
;;   (make-aabb-grid boxes cell)        -- broadphase: hash static
;;   (grid-near grid pos r)                boxes into xz cells, query
;;                                         the handful near a sphere
;;
;; Ray directions must be unit vectors (v3-normalize) so distances
;; come back in world units.  Triangles hit from either side.
;; The sweep inflates the box by r (Minkowski), so corners are a
;; whisker square instead of round -- invisible at game radii.
;;
(library (gfx collide)
  (export sphere-sphere? aabb-aabb? sphere-aabb?
          capsule-sphere? capsule-capsule? capsule-aabb?
          ray-sphere ray-aabb ray-plane ray-triangle ray-mesh
          ray-heightfield screen-ray
          sphere-aabb-push sweep-sphere-aabb move-and-slide
          make-character character? character-pos character-grounded?
          character-move! character-jump!
          make-aabb-grid grid-near
          segment-segment-closest capsule-capsule-contact
          circle-circle? segment-circle? move-circle)
  (import (rnrs) (gfx mat) (gfx mesh))

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

  ;; nearest triangle of a (gfx mesh) mesh; brute force -- picking
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

  ;; ---- ground described by a function, not by geometry ----
  ;;
  ;; A world whose ground is a height function has no triangles to test,
  ;; so ray-mesh has nothing to work on and ray-plane is only right if
  ;; the ground is flat.  This walks the ray forward until it is under
  ;; the ground, then bisects the interval it crossed.
  ;;
  ;; BOTH NUMBERS ARE THE CALLER'S, and the step is the dangerous one.
  ;; The march only ever knows whether it is above the ground at the
  ;; points it samples, so a feature THINNER THAN THE STEP can sit
  ;; entirely between two samples: the ray passes over a wall, a fence
  ;; post, the edge of a mesa, and both neighbouring samples are above
  ;; the ground, so nothing is detected and the march continues to
  ;; whatever lies beyond, and the caller gets a confident answer at the
  ;; wrong place.  It is not a failure, it is a WRONG ANSWER, and
  ;; nothing here can notice it: from inside, a crossing that was
  ;; stepped over is indistinguishable from one that was never there.
  ;; A caller picks the step against the narrowest feature its ground
  ;; has, and pays for it in samples.
  ;;
  ;; The refinement count is the other one, and it is the safe one: too
  ;; few and the answer is imprecise by a knowable amount -- the step
  ;; halved that many times -- rather than wrong somewhere else.
  ;;
  ;; ANSWERS A DISTANCE, like every other ray- here, so the value can be
  ;; compared with what the other shapes answer without remembering
  ;; which of them is special.  The point is `o + d*t`, and its height
  ;; is on the surface only to within the refinement; a caller that
  ;; needs it exactly on the ground substitutes the height function's
  ;; own answer at that x and z, which costs one more call.
  (define (ray-heightfield o d height range step refine)
    (unless (procedure? height)
      (error 'ray-heightfield "the ground is a procedure of x and z" height))
    (let ((range ($col-fl range))
          (step ($col-fl step)))
      (unless (fl<? 0.0 step)
        (error 'ray-heightfield "the march step is a positive distance" step))
      (unless (fl<? 0.0 range)
        (error 'ray-heightfield "the range is a positive distance" range))
      (unless (and (integer? refine) (not (< refine 0)))
        (error 'ray-heightfield "the refinement count is a non-negative integer" refine))
      (let ()
        (define (above? t)
          (let ((x (fl+ (v3-x o) (fl* t (v3-x d))))
                (y (fl+ (v3-y o) (fl* t (v3-y d))))
                (z (fl+ (v3-z o) (fl* t (v3-z d)))))
            (fl<? ($col-fl (height x z)) y)))
        (if (not (above? 0.0))
            0.0
            (let march ((t step) (previous 0.0))
              (cond
               ((fl<? range t) #f)
               ((above? t) (march (fl+ t step) t))
               (else
                (let bisect ((lo previous) (hi t) (k refine))
                  (if (= k 0)
                      hi
                      (let ((mid (fl* 0.5 (fl+ lo hi))))
                        (if (above? mid)
                            (bisect mid hi (- k 1))
                            (bisect lo mid (- k 1))))))))))))) 

  ;; The ray under a point on the screen, as an origin on the near plane
  ;; and a unit direction.
  ;;
  ;; This exists so that nobody rebuilds it from a field of view.  The
  ;; obvious hand-written version takes the half-angle the projection
  ;; was built with, reconstructs the frustum from it, and aims a ray
  ;; through the pixel -- and the moment the projection changes, that
  ;; copy of the angle is stale and picking is quietly aimed somewhere
  ;; else.  The inverse view-projection cannot go stale that way: it IS
  ;; the projection, so a ray built from it is aimed wherever the
  ;; picture is actually looking.
  ;;
  ;; x and y are in normalised device coordinates, -1 to 1, with y UP --
  ;; a pointer position in pixels becomes that with
  ;; `(- (* 2 (/ px w)) 1)` and `(- 1 (* 2 (/ py h)))`, the second
  ;; flipped because pointer events count down from the top.
  (define (screen-ray inv-vp x y)
    (let* ((fx ($col-fl x))
           (fy ($col-fl y))
           (near (m4-unproject inv-vp fx fy -1.0))
           (far (m4-unproject inv-vp fx fy 1.0))
           (dir (v3-sub far near))
           (len (flsqrt (v3-dot dir dir))))
      (unless (and (fl=? len len) (fl<? len 1e30) (fl<? $col-eps len))
        (error 'screen-ray
               "the near and far points do not give a direction: the matrix is not an invertible view-projection"
               x y))
      (values near
              (v3 (fl/ (v3-x dir) len)
                  (fl/ (v3-y dir) len)
                  (fl/ (v3-z dir) len)))))

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

  ;; The closest point on each of two segments (Ericson 5.1.9).  Every
  ;; question this file answers about two segments is answered from
  ;; here: the squared distance below is these two points subtracted,
  ;; and capsule-capsule? is that distance against the summed radii.
  ;; Answering the points rather than the distance is what lets a caller
  ;; that needs to know WHERE two capsules meet get it from the same
  ;; arithmetic that decided THAT they meet, instead of running a second
  ;; copy of this and hoping the two agree at the boundary.
  (define ($col-seg-seg-pts p1 q1 p2 q2)
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
        (values (v3-add p1 (v3-scale d1 s))
                (v3-add p2 (v3-scale d2 t))))))

  (define ($col-seg-seg-d2 p1 q1 p2 q2)
    (let-values (((a b) ($col-seg-seg-pts p1 q1 p2 q2)))
      (let ((w (v3-sub a b)))
        (v3-dot w w))))

  ;; The closest point on each segment, in that order.  Two segments
  ;; that cross have one point each at the crossing; two that are
  ;; parallel have one of the many closest pairs, chosen the same way
  ;; every time rather than by whichever happened to round first.
  (define (segment-segment-closest p1 q1 p2 q2)
    ($col-seg-seg-pts p1 q1 p2 q2))

  (define (capsule-capsule? p1 q1 r1 p2 q2 r2)
    (let ((rr (fl+ ($col-fl r1) ($col-fl r2))))
      (fl<? ($col-seg-seg-d2 p1 q1 p2 q2) (fl* rr rr))))

  ;; Where two capsules meet, which way, and by how much: a point on the
  ;; surface of each, the unit normal from the second toward the first,
  ;; and the separation -- negative when they overlap, and then its size
  ;; is the penetration depth.
  ;;
  ;; capsule-capsule? REMAINS THE AUTHORITY on whether two capsules
  ;; meet.  It compares squared quantities; the separation here goes
  ;; through a square root, and the two can in principle part company in
  ;; the last bit for a pair sitting exactly on the boundary.  Measured
  ;; over 2400 radius pairs, 1600 of them within one percent of the
  ;; boundary, they never did -- but a caller that needs the two to
  ;; agree should ask the predicate rather than test this sign.
  ;;
  ;; This answers for capsules that are APART as well as for ones that
  ;; touch.  A caller that only wants to know whether they meet has
  ;; capsule-capsule?, which is cheaper; this one is for the caller that
  ;; is going to do something at the place they meet, and that caller
  ;; usually has to handle "nearly touching" the same way.
  ;;
  ;; WHEN THE AXES MEET there is no line between them to take a normal
  ;; from, so the normal is +x.  Arbitrary, but FIXED, for the reason
  ;; the circle push above gives: normalising a zero vector answers NaN,
  ;; and choosing by anything incidental -- an argument order, a
  ;; rounding -- makes a caller's result depend on something it cannot
  ;; see.  A caller that cares about this case can see it, because the
  ;; separation it gets back is exactly minus the summed radii.
  (define (capsule-capsule-contact p1 q1 r1 p2 q2 r2)
    (let-values (((a b) ($col-seg-seg-pts p1 q1 p2 q2)))
      (let* ((cr1 ($col-fl r1))
             (cr2 ($col-fl r2))
             (d (v3-sub a b))
             (d2 (v3-dot d d))
             (len (flsqrt d2))
             (n (if (fl<? len $col-eps)
                    (v3 1.0 0.0 0.0)
                    (v3 (fl/ (v3-x d) len) (fl/ (v3-y d) len) (fl/ (v3-z d) len))))
             (on1 (v3-sub a (v3-scale n cr1)))
             (on2 (v3-add b (v3-scale n cr2))))
        (values on1 on2 (fl- (fl- len cr1) cr2)))))

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
          ;; the slab walk, unrolled by axis: the per-box inner loop
          ;; of every character step, so no temporary vectors -- each
          ;; axis reads its scalars straight off the arguments
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
                (let ((o (vector-ref c i)) (d (vector-ref motion i))
                      (lo (fl- (vector-ref bmin i) r))
                      (hi (fl+ (vector-ref bmax i) r)))
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
                                  axis sign))))))))))

  ;; ---- the character controller loop, packaged ----
  ;; boxes is a list of (bmin . bmax) pairs.  Advance to the first
  ;; contact, keep a skin's breadth off the face, shed the motion's
  ;; into-the-wall component, and continue with what remains: walls
  ;; slide, corners stop.  Three passes bound the worst corner.
  (define $col-skin 0.001)
  ;; per-iteration scratch: the remaining motion lives here across
  ;; the (at most three) slide passes instead of three fresh vectors
  ;; a pass.  The caller's motion is never written; positions that
  ;; escape (the return, each pass's contact point) stay fresh
  (define $col-rem (v3 0.0 0.0 0.0))
  (define $col-tmp (v3 0.0 0.0 0.0))
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
                     (at (v3 (fl+ (fl+ (v3-x pos) (fl* (v3-x m) t))
                                  (fl* (v3-x n) $col-skin))
                             (fl+ (fl+ (v3-y pos) (fl* (v3-y m) t))
                                  (fl* (v3-y n) $col-skin))
                             (fl+ (fl+ (v3-z pos) (fl* (v3-z m) t))
                                  (fl* (v3-z n) $col-skin))))
                     (rem (v3-scale! $col-rem m (fl- 1.0 t)))
                     (slide (v3-sub! $col-rem rem
                                     (v3-scale! $col-tmp n
                                                (v3-dot rem n)))))
                (go at slide (+ k 1)))))))))

  ;; ---- the character, packaged: gravity, landing, jumping ----
  ;; The loop every walking player repeats over move-and-slide:
  ;; gravity accumulates in vy, the horizontal wish is yours, and a
  ;; short downward probe after the slide answers "standing?" --
  ;; which zeroes the fall and arms the jump.
  (define-record-type ($character $make-char character?)
    (fields (mutable pos character-pos $char-pos!)
            (immutable r $char-r)
            (mutable vy $char-vy $char-vy!)
            (mutable grounded $char-grounded $char-grounded!)))

  (define $char-gravity 22.0)

  (define (make-character pos r)
    ($make-char pos ($col-fl r) 0.0 #f))

  (define (character-grounded? ch) ($char-grounded ch))

  (define (character-jump! ch speed)
    (when ($char-grounded ch)
      ($char-vy! ch ($col-fl speed))
      ($char-grounded! ch #f)))

  ;; vx / vz are the wished horizontal velocity, world units per
  ;; second; dt and the box list as for move-and-slide.  Returns the
  ;; new position (also stored in the character).
  (define $col-motion (v3 0.0 0.0 0.0)) ; move-and-slide never keeps it
  (define $col-probe (v3 0.0 -0.08 0.0))
  (define (character-move! ch vx vz dt boxes)
    (let* ((dt ($col-fl dt))
           (vy (fl- ($char-vy ch) (fl* $char-gravity dt)))
           (motion (v3-set! $col-motion (fl* ($col-fl vx) dt)
                            (fl* vy dt)
                            (fl* ($col-fl vz) dt)))
           (pos (move-and-slide (character-pos ch) ($char-r ch)
                                motion boxes))
           (standing
            (let scan ((bs boxes))
              (cond ((null? bs) #f)
                    ((sweep-sphere-aabb pos ($char-r ch)
                                        $col-probe
                                        (car (car bs)) (cdr (car bs)))
                     #t)
                    (else (scan (cdr bs)))))))
      ($char-pos! ch pos)
      ($char-grounded! ch (and standing (not (fl<? 0.0 vy))))
      ($char-vy! ch (if (and standing (fl<? vy 0.0)) 0.0 vy))
      pos))

  ;; ---- broadphase: static boxes hashed into xz cells ----
  ;; Build once over the level's boxes; each frame ask for the
  ;; handful near the player instead of sweeping every wall.
  ;; Cells pack into one fixnum, so coordinates live within
  ;; +/- 8191 cells of the origin -- kilometers, at game scale.
  (define ($grid-key cx cz)
    (+ (* (+ cx 8192) 16384) (+ cz 8192)))

  (define ($grid-cell v cf) (%fl->fx (flfloor (fl/ v cf))))

  (define (make-aabb-grid boxes cell)
    (let ((cf ($col-fl cell))
          (ht (make-eq-hashtable)))
      (for-each
       (lambda (b)
         (let ((x0 ($grid-cell (v3-x (car b)) cf))
               (x1 ($grid-cell (v3-x (cdr b)) cf))
               (z0 ($grid-cell (v3-z (car b)) cf))
               (z1 ($grid-cell (v3-z (cdr b)) cf)))
           (let xloop ((x x0))
             (when (<= x x1)
               (let zloop ((z z0))
                 (when (<= z z1)
                   (let ((k ($grid-key x z)))
                     (hashtable-set! ht k
                                     (cons b (hashtable-ref ht k '()))))
                   (zloop (+ z 1))))
               (xloop (+ x 1))))))
       boxes)
      (cons cf ht)))

  ;; every box whose cells the sphere (pos, r) touches, each once
  (define (grid-near g pos r)
    (let* ((cf (car g)) (ht (cdr g)) (r ($col-fl r))
           (x0 ($grid-cell (fl- (v3-x pos) r) cf))
           (x1 ($grid-cell (fl+ (v3-x pos) r) cf))
           (z0 ($grid-cell (fl- (v3-z pos) r) cf))
           (z1 ($grid-cell (fl+ (v3-z pos) r) cf)))
      (let xloop ((x x0) (acc '()))
        (if (> x x1)
            acc
            (xloop (+ x 1)
                   (let zloop ((z z0) (acc acc))
                     (if (> z z1)
                         acc
                         (zloop (+ z 1)
                                (let dedup ((bs (hashtable-ref
                                                 ht ($grid-key x z) '()))
                                            (acc acc))
                                  (cond ((null? bs) acc)
                                        ((memq (car bs) acc)
                                         (dedup (cdr bs) acc))
                                        (else (dedup (cdr bs)
                                                     (cons (car bs)
                                                           acc)))))))))))))
  ;; ---- circles in a plane ----
  ;;
  ;; The arguments are a PAIR OF NUMBERS (x, y); this library does not
  ;; say which two world axes they are.  A top-down game passes (x, z).
  ;; They are not named x/z, because that would burn one convention
  ;; into the names and leave every other caller translating.
  ;;
  ;; These are not conveniences over the 3D pieces above.  Each answers
  ;; a question the 3D piece answers WRONGLY for this use:
  ;;   * ray-sphere reports a distance along an INFINITE ray, so a
  ;;     circle beyond the far end of a sweep still "hits";
  ;;   * move-and-slide resolves against an AABB, and a circle is
  ;;     pushed along the line of centres, not along an axis;
  ;;   * sphere-sphere? is three-dimensional, so using it here builds
  ;;     two v3s per pair per frame on a hot path.

  (define (circle-circle? x1 y1 r1 x2 y2 r2)
    (let* ((dx (fl- ($col-fl x2) ($col-fl x1)))
           (dy (fl- ($col-fl y2) ($col-fl y1)))
           (rr (fl+ ($col-fl r1) ($col-fl r2))))
      (fl<? (fl+ (fl* dx dx) (fl* dy dy)) (fl* rr rr))))

  ;; Does the SEGMENT a->b come within r of c?  The clamp on t is the
  ;; whole difference from a ray: without it this answers "does the
  ;; line through a and b pass near c", which is true for circles the
  ;; swing never reaches.  A degenerate segment (a = b) is a point, and
  ;; the answer is then whether that point lies inside the circle.
  (define (segment-circle? ax ay bx by cx cy r)
    (let* ((ax ($col-fl ax)) (ay ($col-fl ay))
           (bx ($col-fl bx)) (by ($col-fl by))
           (cx ($col-fl cx)) (cy ($col-fl cy)) (r ($col-fl r))
           (ex (fl- bx ax)) (ey (fl- by ay))
           (len2 (fl+ (fl* ex ex) (fl* ey ey)))
           (t (if (fl=? len2 0.0)
                  0.0
                  (let ((raw (fl/ (fl+ (fl* (fl- cx ax) ex)
                                       (fl* (fl- cy ay) ey))
                                  len2)))
                    (if (fl<? raw 0.0) 0.0 (if (fl<? 1.0 raw) 1.0 raw)))))
           (px (fl+ ax (fl* ex t)))
           (py (fl+ ay (fl* ey t)))
           (dx (fl- cx px)) (dy (fl- cy py)))
      (fl<? (fl+ (fl* dx dx) (fl* dy dy)) (fl* r r))))

  ;; Push one circle out of another, along the line of centres.  When
  ;; the centres coincide there is no such line, so the direction is +x:
  ;; arbitrary, but FIXED -- normalising a zero vector would answer NaN,
  ;; and choosing by iteration order would make the result depend on how
  ;; the solids happen to be listed.
  (define ($circle-push x y r sx sy sr)
    (let* ((dx (fl- x sx)) (dy (fl- y sy))
           (d2 (fl+ (fl* dx dx) (fl* dy dy)))
           (rr (fl+ r sr)))
      (if (fl<? d2 (fl* rr rr))
          (if (fl=? d2 0.0)
              (cons (fl+ sx rr) sy)
              (let* ((d (flsqrt d2))
                     (k (fl/ rr d)))
                (cons (fl+ sx (fl* dx k)) (fl+ sy (fl* dy k)))))
          (cons x y))))

  ;; Move a circle by (dx, dy), pushed out of every solid it would end
  ;; up inside; answers the new x and y as two values.  `solids' is a
  ;; vector of #(x y r).
  ;;
  ;; Sliding is what falls out of pushing rather than stopping: a
  ;; diagonal move into a wall keeps the component along the wall.
  ;;
  ;; WHAT IS GUARANTEED, AND WHERE IT STOPS.  The move is taken in
  ;; ceil(|d| / (r/2)) steps, each resolved against every solid, so a
  ;; call whose displacement is within an integer number of r/2 hops
  ;; cannot pass through a solid it should have hit.
  ;; !! This is NOT general continuous collision detection.  A
  ;; displacement far larger than a SMALL solid's radius can still step
  ;; over it: the step length is chosen from the MOVING circle's radius,
  ;; not from the radii of what it might hit.  A "cannot tunnel" with no
  ;; stated boundary is the next incident, so the boundary is stated.
  ;;
  ;; Solids are applied in order, so the final position depends on the
  ;; order of the vector.  That is a deliberate, recorded trade -- doing
  ;; better means solving the constraints jointly -- and it means a
  ;; caller (or a test) must not depend on where a circle lands between
  ;; two overlapping solids, only on it ending up outside both.
  (define (move-circle x y dx dy r solids)
    (let* ((x ($col-fl x)) (y ($col-fl y))
           (dx ($col-fl dx)) (dy ($col-fl dy)) (r ($col-fl r))
           (dist (flsqrt (fl+ (fl* dx dx) (fl* dy dy))))
           (step (if (fl<? 0.0 r) (fl/ r 2.0) r))
           (n (if (or (fl=? dist 0.0) (not (fl<? 0.0 step)))
                  1
                  (let loop ((k 1))
                    (if (fl<? dist (fl* step (fixnum->flonum k)))
                        k
                        (loop (+ k 1))))))
           (fx (fl/ dx (fixnum->flonum n)))
           (fy (fl/ dy (fixnum->flonum n)))
           (m (vector-length solids)))
      (let step-loop ((i 0) (px x) (py y))
        (if (= i n)
            (values px py)
            (let ((nx (fl+ px fx)) (ny (fl+ py fy)))
              (let solid-loop ((j 0) (cx nx) (cy ny))
                (if (= j m)
                    (step-loop (+ i 1) cx cy)
                    (let* ((s (vector-ref solids j))
                           (p ($circle-push cx cy r
                                            ($col-fl (vector-ref s 0))
                                            ($col-fl (vector-ref s 1))
                                            ($col-fl (vector-ref s 2)))))
                      (solid-loop (+ j 1) (car p) (cdr p))))))))))
)

