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
      -0.35 0.0 0.0))
