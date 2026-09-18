;; expect: #t
;; ray-circle completes the ray-* family at the one shape it was missing.
;; The 2D group had circle-circle?, segment-circle? and move-circle --
;; predicates and a mover, and no raycast -- while ray-sphere, ray-aabb,
;; ray-plane, ray-triangle, ray-mesh and ray-heightfield are all 3D.
;;
;; IT FOLLOWS ray-sphere, NOT ray-aabb, AND THAT IS A CHOICE.  The family
;; does not agree with itself about a ray that starts inside: measured on
;; this tree, ray-sphere from the centre of a unit sphere answers 1.0 --
;; the distance OUT -- while ray-aabb from inside a box answers 0.0.  A
;; circle is a sphere with one dimension removed, so this follows the
;; sphere.  The disagreement itself is left alone here; it is older than
;; this addition and changing it would be a separate decision.
;;
;; `dir' is a unit vector, as everywhere in this family, and the result
;; is a distance along it or #f.  The expectations below are geometry,
;; not recordings: a ray from (-3,0) along +x meets the unit circle at
;; the origin after 3 - 1 = 2.
(import (rnrs) (gfx mat) (gfx collide))
(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
(define (near? a b) (and (real? a) (< (abs (- a b)) 0.00001)))
(define (want-near name got expect)
  (unless (near? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))

;; unit circle at the origin
(want-near "a ray aimed at the circle answers the near distance"
           (ray-circle -3.0 0.0 1.0 0.0 0.0 0.0 1.0) 2.0)
(want-near "an offset centre moves the distance with it"
           (ray-circle 0.0 0.0 1.0 0.0 10.0 0.0 1.0) 9.0)
(want-near "the axis the ray travels does not matter"
           (ray-circle 0.0 -3.0 0.0 1.0 0.0 0.0 1.0) 2.0)

;; THE INSIDE CASE, pinned deliberately: ray-sphere's answer, not
;; ray-aabb's.  From the centre of a unit circle the way out is 1.
(want-near "a ray starting inside answers the way out"
           (ray-circle 0.0 0.0 1.0 0.0 0.0 0.0 1.0) 1.0)

;; A miss and a circle behind the ray are both #f, and they are
;; different situations -- the second is what the clamp on t is for in
;; segment-circle?, one shape up.
(want "a ray that passes by misses" (ray-circle -3.0 5.0 1.0 0.0 0.0 0.0 1.0) #f)
(want "a circle behind the ray is not hit" (ray-circle 3.0 0.0 1.0 0.0 0.0 0.0 1.0) #f)

;; Tangency counts, as it does for ray-sphere: measured there, a ray
;; grazing a unit sphere at distance 3 answers 3.0.
(want-near "a grazing ray still meets the circle"
           (ray-circle -3.0 1.0 1.0 0.0 0.0 0.0 1.0) 3.0)

;; A CONTROL AGAINST A PREDICATE IN DISGUISE.  The rows above already
;; demand distinct distances, so a constant could not pass them; what
;; this adds is the comparison stated as its own row, so a change that
;; made two different hits answer alike is named by the row that is
;; about exactly that, not by whichever distance row fails first.
(let ((near (ray-circle -2.0 0.0 1.0 0.0 0.0 0.0 1.0))
      (far  (ray-circle -9.0 0.0 1.0 0.0 0.0 0.0 1.0)))
  (want-near "the nearer ray answers 1" near 1.0)
  (want-near "the farther ray answers 8" far 8.0)
  (want "and they are not the same number" (equal? near far) #f))

;; A degenerate circle is a point: a ray through it meets it, one beside
;; it does not.
(want-near "a zero radius is a point on the ray"
           (ray-circle -4.0 0.0 1.0 0.0 0.0 0.0 0.0) 4.0)
(want "and is missed when the ray does not pass through it"
      (ray-circle -4.0 0.5 1.0 0.0 0.0 0.0 0.0) #f)

(display (if (null? fails) #t fails))
