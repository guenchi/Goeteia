;; expect: #t
;; (gfx collide): the 2D circle half -- a segment against a circle, and
;; a circle pushed out of circles while it moves.
;;
;; These are not conveniences over the 3D primitives.  ray-sphere
;; answers for an INFINITE ray, so a circle sitting past the end of a
;; swing is reported as hit; move-and-slide pushes out of axis-aligned
;; boxes, and a circle's push is along the line of centres.  The first
;; cell below is the one that says so: the same circle is a miss for the
;; segment and a hit for the ray.
;;
;; The pair of numbers is just a pair of numbers: the library does not
;; say which two world axes they are.  A top-down game passes (x, z).
(import (rnrs) (gfx mat) (gfx collide))

(define (near? a b)
  (and (fl<? (fl- a b) 0.00001) (fl<? (fl- b a) 0.00001)))
(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))
(define (moved x y dx dy r solids)      ; -> (x . y), so cells can compare both
  (call-with-values (lambda () (move-circle x y dx dy r solids)) cons))

;; ---- circle-circle? ----
(check "circles that overlap"      (circle-circle? 0.0 0.0 1.0 1.5 0.0 1.0))
(check "circles exactly touching do not count as overlapping"
       (not (circle-circle? 0.0 0.0 1.0 2.0 0.0 1.0)))
(check "circles apart"        (not (circle-circle? 0.0 0.0 1.0 3.0 0.0 1.0)))

;; ---- segment-circle? : the reason this batch exists ----
;; A circle at (10,0) lies on the ray from (0,0) towards +x, but well
;; past the end of a segment that stops at (1,0).
(check "a circle beyond the end of the segment is a miss"
       (not (segment-circle? 0.0 0.0 1.0 0.0 10.0 0.0 1.0)))
(check "the same circle IS on the infinite ray, which is why the ray test cannot answer this"
       (let ((d (ray-sphere (v3 0.0 0.0 0.0) (v3 1.0 0.0 0.0) (v3 10.0 0.0 0.0) 1.0)))
         (and d (fl<? 8.0 d))))
(check "a circle the segment reaches is a hit"
       (segment-circle? 0.0 0.0 10.0 0.0 5.0 0.0 1.0))
(check "a circle beside the segment, nearer than its radius, is a hit"
       (segment-circle? 0.0 0.0 10.0 0.0 5.0 0.9 1.0))
(check "a circle beside the segment, further than its radius, is a miss"
       (not (segment-circle? 0.0 0.0 10.0 0.0 5.0 1.1 1.0)))
;; a zero-length segment is a point, and must not divide by its length
(check "a degenerate segment is a point inside the circle"
       (segment-circle? 3.0 3.0 3.0 3.0 3.0 3.5 1.0))
(check "a degenerate segment outside the circle is a miss"
       (not (segment-circle? 3.0 3.0 3.0 3.0 3.0 5.0 1.0)))

;; ---- move-circle ----
(define none (vector))
(check "with nothing in the way the move is exact"
       (let ((p (moved 0.0 0.0 2.0 3.0 0.5 none)))
         (and (near? (car p) 2.0) (near? (cdr p) 3.0))))

;; a starting overlap is pushed out to exactly touching
(check "a starting overlap is pushed out to touching, not merely out"
       (let* ((p (moved 0.5 0.0 0.0 0.0 1.0 (vector (vector 0.0 0.0 1.0))))
              (d (flsqrt (fl+ (fl* (car p) (car p)) (fl* (cdr p) (cdr p))))))
         (near? d 2.0)))

;; coincident centres have no line of centres to push along; the answer
;; must still be a number, and the same number every time
(check "coincident centres are pushed a full radius apart, deterministically"
       (let* ((a (moved 0.0 0.0 0.0 0.0 1.0 (vector (vector 0.0 0.0 1.0))))
              (b (moved 0.0 0.0 0.0 0.0 1.0 (vector (vector 0.0 0.0 1.0))))
              (d (flsqrt (fl+ (fl* (car a) (car a)) (fl* (cdr a) (cdr a))))))
         (and (near? d 2.0) (near? (car a) (car b)) (near? (cdr a) (cdr b)))))

;; the guarantee, and only the guarantee: a move of six radii across a
;; solid ends outside it.  The substepping that buys this is bounded --
;; a move very much larger than a very small solid can still pass
;; through, which is written down rather than pretended away.
(check "a move of six radii does not pass through a solid on the way"
       (let* ((p (moved -3.0 0.0 6.0 0.0 0.5 (vector (vector 0.0 0.0 1.0))))
              (d (flsqrt (fl+ (fl* (car p) (car p)) (fl* (cdr p) (cdr p))))))
         (fl<? 1.49 d)))

;; sliding: driving straight at a solid off-centre leaves tangential motion
(check "a glancing move slides along the solid instead of stopping dead"
       (let ((p (moved -2.0 0.4 4.0 0.0 0.5 (vector (vector 0.0 0.0 1.0)))))
         (fl<? 0.4 (cdr p))))
(check "and it ends outside the solid"
       (let* ((p (moved -2.0 0.4 4.0 0.0 0.5 (vector (vector 0.0 0.0 1.0))))
              (d (flsqrt (fl+ (fl* (car p) (car p)) (fl* (cdr p) (cdr p))))))
         (fl<? 1.49 d)))

;; two overlapping solids: the order they are applied in decides the
;; exact landing point, so this asserts only what is promised -- that
;; the circle ends clear of both.
(check "clear of both of two overlapping solids"
       (let* ((s (vector (vector 0.0 0.0 1.0) (vector 0.7 0.0 1.0)))
              (p (moved 0.2 0.0 0.0 0.0 0.5 s))
              (d0 (flsqrt (fl+ (fl* (car p) (car p)) (fl* (cdr p) (cdr p)))))
              (d1 (flsqrt (fl+ (fl* (fl- (car p) 0.7) (fl- (car p) 0.7))
                               (fl* (cdr p) (cdr p))))))
         (and (fl<? 1.49 d0) (fl<? 1.49 d1))))
(display (= failed 0))
