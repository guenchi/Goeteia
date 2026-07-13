;; expect: #t
;; (web collide): overlaps, raycasts, and the sliding push, all pure
;; and checked against hand-computed distances.
(import (rnrs) (web mat) (web mesh) (web collide))

(define (near? a b)
  (and (fl<? (fl- a b) 0.00001) (fl<? (fl- b a) 0.00001)))
(define (v3~ v x y z)
  (and (near? (v3-x v) x) (near? (v3-y v) y) (near? (v3-z v) z)))

(define bmin (v3 -1.0 -1.0 -1.0))
(define bmax (v3 1.0 1.0 1.0))

(and
 ;; sphere-sphere: overlap, exact touch (no), apart
 (sphere-sphere? (v3 0 0 0) 1.0 (v3 1.5 0 0) 1.0)
 (not (sphere-sphere? (v3 0 0 0) 1.0 (v3 2.0 0 0) 1.0))
 (not (sphere-sphere? (v3 0 0 0) 1.0 (v3 3.0 0 0) 1.0))
 ;; aabb-aabb, exclusive at the faces
 (aabb-aabb? bmin bmax (v3 0.0 0.0 0.0) (v3 2.0 2.0 2.0))
 (not (aabb-aabb? bmin bmax (v3 1.0 -1.0 -1.0) (v3 3.0 1.0 1.0)))
 (not (aabb-aabb? bmin bmax (v3 2.0 2.0 2.0) (v3 3.0 3.0 3.0)))
 ;; sphere-aabb via the closest point (the corner matters)
 (sphere-aabb? (v3 1.5 0.0 0.0) 1.0 bmin bmax)
 (not (sphere-aabb? (v3 2.5 0.0 0.0) 1.0 bmin bmax))
 (not (sphere-aabb? (v3 1.9 1.9 0.0) 1.0 bmin bmax))  ; corner dist ~1.27
 ;; ray-sphere: hit, miss, from inside
 (near? (ray-sphere (v3 0 0 5) (v3 0 0 -1.0) (v3 0 0 0) 1.0) 4.0)
 (not (ray-sphere (v3 2 0 5) (v3 0 0 -1.0) (v3 0 0 0) 1.0))
 (near? (ray-sphere (v3 0 0 0) (v3 0 0 -1.0) (v3 0 0 0) 1.0) 1.0)
 ;; ray-aabb: hit, parallel miss, from inside
 (near? (ray-aabb (v3 0 0 5) (v3 0 0 -1.0) bmin bmax) 4.0)
 (not (ray-aabb (v3 2 0 5) (v3 0 0 -1.0) bmin bmax))
 (near? (ray-aabb (v3 0 0 0) (v3 0 0 -1.0) bmin bmax) 0.0)
 (not (ray-aabb (v3 0 0 5) (v3 0 0 1.0) bmin bmax))   ; behind
 ;; ray-plane: the ground query
 (near? (ray-plane (v3 0 5 0) (v3 0 -1.0 0) (v3 0 0 0) (v3 0 1.0 0)) 5.0)
 (not (ray-plane (v3 0 5 0) (v3 0 1.0 0) (v3 0 0 0) (v3 0 1.0 0)))
 (not (ray-plane (v3 0 5 0) (v3 1.0 0 0) (v3 0 0 0) (v3 0 1.0 0)))
 ;; ray-triangle: barycentric in, out, and the back side
 (near? (ray-triangle (v3 0.5 0.5 3.0) (v3 0 0 -1.0)
                      (v3 0 0 0) (v3 2.0 0 0) (v3 0 2.0 0))
        3.0)
 (not (ray-triangle (v3 1.5 1.5 3.0) (v3 0 0 -1.0)
                    (v3 0 0 0) (v3 2.0 0 0) (v3 0 2.0 0)))
 (near? (ray-triangle (v3 0.5 0.5 -3.0) (v3 0 0 1.0)
                      (v3 0 0 0) (v3 2.0 0 0) (v3 0 2.0 0))
        3.0)
 ;; ray-mesh: pick the front face of a generated cube
 (near? (ray-mesh (v3 0 0 5) (v3 0 0 -1.0) (mesh-box 2 2 2)) 4.0)
 (not (ray-mesh (v3 5 5 5) (v3 0 0 -1.0) (mesh-box 2 2 2)))
 ;; the sliding push: outside-overlap, clear, centre inside
 (v3~ (sphere-aabb-push (v3 1.5 0.0 0.0) 1.0 bmin bmax) 0.5 0.0 0.0)
 (not (sphere-aabb-push (v3 3.0 0.0 0.0) 1.0 bmin bmax))
 (v3~ (sphere-aabb-push (v3 0.5 0.0 0.0) 1.0 bmin bmax) 1.5 0.0 0.0)
 (v3~ (sphere-aabb-push (v3 0.0 0.0 0.8) 1.0 bmin bmax) 0.0 0.0 1.2)
 ;; a wall at x >= 2: the player slides, keeping y/z motion
 (v3~ (sphere-aabb-push (v3 1.6 0.0 0.0) 0.75
                        (v3 2.0 -5.0 -5.0) (v3 3.0 5.0 5.0))
      -0.35 0.0 0.0)

 ;; ---- capsules ----
 ;; a standing capsule vs a sphere overhead: reach is cr + r past q
 (capsule-sphere? (v3 0 0 0) (v3 0 2.0 0) 0.5 (v3 0 3.0 0) 0.6)
 (not (capsule-sphere? (v3 0 0 0) (v3 0 2.0 0) 0.5 (v3 0 3.0 0) 0.4))
 ;; beside the shaft: radial distance only
 (capsule-sphere? (v3 0 0 0) (v3 0 2.0 0) 0.5 (v3 1.0 1.0 0) 0.6)
 (not (capsule-sphere? (v3 0 0 0) (v3 0 2.0 0) 0.5 (v3 1.2 1.0 0) 0.6))
 ;; parallel capsules a unit apart; then crossed ones that touch at
 ;; their midpoints
 (capsule-capsule? (v3 0 0 0) (v3 0 2.0 0) 0.6 (v3 1.0 0 0) (v3 1.0 2.0 0) 0.6)
 (not (capsule-capsule? (v3 0 0 0) (v3 0 2.0 0) 0.4
                        (v3 1.0 0 0) (v3 1.0 2.0 0) 0.4))
 (capsule-capsule? (v3 -1.0 0 0) (v3 1.0 0 0) 0.3
                   (v3 0 -1.0 0.5) (v3 0 1.0 0.5) 0.3)
 (not (capsule-capsule? (v3 -1.0 0 0) (v3 1.0 0 0) 0.3
                        (v3 0 -1.0 0.7) (v3 0 1.0 0.7) 0.3))
 ;; capsule vs box: the shaft passes a face; then clears it
 (capsule-aabb? (v3 2.0 -1.0 0) (v3 2.0 1.0 0) 1.1 bmin bmax)
 (not (capsule-aabb? (v3 2.0 -1.0 0) (v3 2.0 1.0 0) 0.9 bmin bmax))
 ;; a diagonal capsule whose nearest point is mid-segment
 (capsule-aabb? (v3 -3.0 2.5 0) (v3 3.0 2.5 0) 1.6 bmin bmax)
 (not (capsule-aabb? (v3 -3.0 2.5 0) (v3 3.0 2.5 0) 1.4 bmin bmax))

 ;; ---- the sweep: first contact along the motion ----
 ;; head-on: the face sits at x = -1, the sphere skin at r = 1,
 ;; so contact is at x = -2 -- t = 3/10 of the (10,0,0) motion
 (let ((hit (sweep-sphere-aabb (v3 -5.0 0 0) 1.0 (v3 10.0 0 0) bmin bmax)))
   (and hit (near? (car hit) 0.3) (v3~ (cdr hit) -1.0 0.0 0.0)))
 ;; moving away, and stopping short: both miss
 (not (sweep-sphere-aabb (v3 -5.0 0 0) 1.0 (v3 -10.0 0 0) bmin bmax))
 (not (sweep-sphere-aabb (v3 -5.0 0 0) 1.0 (v3 2.0 0 0) bmin bmax))
 ;; a passing shot misses; tunnelling through in one step does not
 (not (sweep-sphere-aabb (v3 -5.0 3.0 0) 1.0 (v3 10.0 0 0) bmin bmax))
 (let ((hit (sweep-sphere-aabb (v3 -50.0 0 0) 1.0 (v3 100.0 0 0) bmin bmax)))
   (and hit (near? (car hit) 0.48)))
 ;; approaching the +z face gets that face's normal
 (let ((hit (sweep-sphere-aabb (v3 0 0 5.0) 1.0 (v3 0 0 -10.0) bmin bmax)))
   (and hit (near? (car hit) 0.3) (v3~ (cdr hit) 0.0 0.0 1.0)))
 ;; already touching: t = 0 and the shortest way out
 (let ((hit (sweep-sphere-aabb (v3 1.5 0 0) 1.0 (v3 -1.0 0 0) bmin bmax)))
   (and hit (near? (car hit) 0.0) (v3~ (cdr hit) 1.0 0.0 0.0)))

 ;; ---- move-and-slide ----
 ;; straight into a wall: stop a skin off the face
 (let* ((wall (cons (v3 -10.0 -10.0 -1.0) (v3 10.0 10.0 1.0)))
        (p (move-and-slide (v3 0 0 3.0) 0.5 (v3 0 0 -5.0) (list wall))))
   (and (fl<? 1.5 (v3-z p)) (fl<? (v3-z p) 1.51)
        (near? (v3-x p) 0.0) (near? (v3-y p) 0.0)))
 ;; diagonal motion keeps its along-the-wall component
 (let* ((wall (cons (v3 -10.0 -10.0 -1.0) (v3 10.0 10.0 1.0)))
        (p (move-and-slide (v3 0 0 3.0) 0.5 (v3 3.0 0 -5.0) (list wall))))
   (and (fl<? 1.5 (v3-z p)) (fl<? (v3-z p) 1.51)
        (fl<? 2.9 (v3-x p)) (fl<? (v3-x p) 3.01)))
 ;; an inside corner stops both components
 (let* ((wz (cons (v3 -10.0 -10.0 -1.0) (v3 10.0 10.0 1.0)))
        (wx (cons (v3 1.0 -10.0 -10.0) (v3 3.0 10.0 10.0)))
        (p (move-and-slide (v3 0 0 3.0) 0.5 (v3 5.0 0 -5.0) (list wz wx))))
   (and (fl<? 1.5 (v3-z p)) (fl<? (v3-z p) 1.51)
        (fl<? (v3-x p) 0.51)))
 ;; nothing in the way: the full step lands
 (v3~ (move-and-slide (v3 0 0 0) 0.5 (v3 1.0 2.0 3.0) '()) 1.0 2.0 3.0))
