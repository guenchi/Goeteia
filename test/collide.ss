;; expect: #t
;; (gfx collide): overlaps, raycasts, and the sliding push, all pure
;; and checked against hand-computed distances.
(import (rnrs) (gfx mat) (gfx mesh) (gfx collide))

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
 (v3~ (move-and-slide (v3 0 0 0) 0.5 (v3 1.0 2.0 3.0) '()) 1.0 2.0 3.0)
 ;; the caller's motion vector survives the slide untouched, and a
 ;; second identical call answers identically (scratch stays inside)
 (let ((box (list (cons (v3 2.0 -1.0 -1.0) (v3 3.0 1.0 1.0))))
       (m (v3 4.0 0.0 0.1)))
   (let ((p1 (move-and-slide (v3 0 0 0) 0.5 m box))
         (p2 (move-and-slide (v3 0 0 0) 0.5 m box)))
     (and (v3~ m 4.0 0.0 0.1)
          (v3~ p2 (v3-x p1) (v3-y p1) (v3-z p1))
          (fl<? (v3-x p1) 1.51))))

 ;; ---- the character: fall, land, walk, wall, jump ----
 (let* ((ground (cons (v3 -20.0 -1.0 -20.0) (v3 20.0 0.0 20.0)))
        (wall (cons (v3 3.0 0.0 -20.0) (v3 4.0 6.0 20.0)))
        (world (list ground wall))
        (ch (make-character (v3 0.0 3.0 0.0) 0.5))
        (step! (lambda (n vx)
                 (let go ((k 0))
                   (when (< k n)
                     (character-move! ch vx 0.0 0.016666 world)
                     (go (+ k 1)))))))
   (and (not (character-grounded? ch))
        ;; two simulated seconds: fallen and resting on the slab
        (begin (step! 120 0.0)
               (and (character-grounded? ch)
                    (fl<? 0.49 (v3-y (character-pos ch)))
                    (fl<? (v3-y (character-pos ch)) 0.52)))
        ;; walk east one second: about two units, still grounded
        (begin (step! 60 2.0)
               (and (character-grounded? ch)
                    (fl<? 1.8 (v3-x (character-pos ch)))
                    (fl<? (v3-x (character-pos ch)) 2.1)))
        ;; charge the wall: the slide stops the sphere a skin short
        (begin (step! 90 5.0)
               (and (fl<? 2.4 (v3-x (character-pos ch)))
                    (fl<? (v3-x (character-pos ch)) 2.51)
                    (character-grounded? ch)))
        ;; jump: airborne at once, higher shortly after, down again
        (begin (character-jump! ch 7.0)
               (and (not (character-grounded? ch))
                    (begin (step! 12 0.0)
                           (fl<? 1.0 (v3-y (character-pos ch))))
                    (begin (step! 120 0.0)
                           (and (character-grounded? ch)
                                (fl<? (v3-y (character-pos ch)) 0.52))))))
   )

 ;; ---- the broadphase grid ----
 (let* ((near-box (cons (v3 -1.0 0.0 -1.0) (v3 1.0 1.0 1.0)))
        (far-box (cons (v3 40.0 0.0 40.0) (v3 42.0 1.0 42.0)))
        (wide-box (cons (v3 -9.0 0.0 6.0) (v3 9.0 1.0 7.0)))
        (g (make-aabb-grid (list near-box far-box wide-box) 4.0)))
   (and ;; near the origin: the origin box, once, and not the far one
        (let ((hits (grid-near g (v3 0.0 0.5 0.0) 1.0)))
          (and (= (length hits) 1) (eq? (car hits) near-box)))
        ;; the wide box spans many cells but reports once
        (let ((hits (grid-near g (v3 0.0 0.5 6.5) 1.0)))
          (and (= (length hits) 1) (eq? (car hits) wide-box)))
        ;; by the far box: it alone
        (let ((hits (grid-near g (v3 41.0 0.5 41.0) 1.0)))
          (and (= (length hits) 1) (eq? (car hits) far-box)))
        ;; empty space: nothing
        (null? (grid-near g (v3 -30.0 0.5 -30.0) 1.0)))))
