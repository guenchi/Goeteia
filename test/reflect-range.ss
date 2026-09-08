;; expect: #t
;; (gfx reflect): how much of a reflection target actually needs drawing.
;; Clip the reflector's footprint against the main view, project what
;; survives with the mirrored view-projection, expand conservatively, and
;; answer #f (skip the pass), #t (the whole target) or a pixel rectangle.
;;
;; The failure mode this library exists to avoid is a SILENTLY MISSING
;; reflection: a rectangle one pixel too small reflects nothing there and
;; nothing reports it.  So every uncertain case answers #t, rounding is
;; outward only, and the polygons the caller passes must already enclose
;; the maximum displacement its shader applies -- a pixel pad cannot
;; recover geometry a wave pushes into view from a footprint that was
;; already clipped away.  pad covers what happens after projection:
;; distorted sampling and filter taps.
(import (rnrs) (gfx mat) (gfx reflect))

(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))
(define (near? a b) (< (abs (- a b)) 0.001))
(define (refused? who thunk)
  (guard (e (#t (and (error? e) (eq? (condition-who e) who)))) (thunk) #f))

(define W 800)
(define H 600)
(define proj (m4-perspective 0.9 (/ 800.0 600.0) 0.1 100.0))
(define view (m4-look-at (v3 0 4 10) (v3 0 0 0) (v3 0 1 0)))
(define vp (m4-mul proj view))
;; the mirrored camera: reflect the eye and the focus about y = 0
(define mirror (reflect-plane-matrix 0.0))
(define rvp (m4-mul proj (m4-look-at (v3 0 -4 10) (v3 0 0 0) (v3 0 -1 0))))
;; a mirrored camera aimed far to the side: the reflector is visible in the
;; main view, but its reflection lands outside the target
(define rvp-off-target (m4-mul proj (m4-look-at (v3 60 -4 10) (v3 60 0 0) (v3 0 -1 0))))

;; a footprint on the plane, given as one flat vector of world xyz
(define (quad x z hx hz)
  (vector (- x hx) 0.0 (- z hz)   (+ x hx) 0.0 (- z hz)
          (+ x hx) 0.0 (+ z hz)   (- x hx) 0.0 (+ z hz)))

;; where a world point lands, in pixels, computed here and not by the library
(define (project-px m x y z)
  (let ((p (m4-transform m (v3 x y z))))
    (cons (* (/ (+ (v3-x p) 1.0) 2.0) (exact->inexact W))
          (* (/ (+ (v3-y p) 1.0) 2.0) (exact->inexact H)))))

(define (covers? r poly m)
  (let ((x (vector-ref r 0)) (y (vector-ref r 1))
        (w (vector-ref r 2)) (h (vector-ref r 3)))
    (let loop ((i 0))
      (or (>= i (vector-length poly))
          (let ((p (project-px m (vector-ref poly i) (vector-ref poly (+ i 1))
                               (vector-ref poly (+ i 2)))))
            (and (>= (car p) (- x 0.5)) (<= (car p) (+ x w 0.5))
                 (>= (cdr p) (- y 0.5)) (<= (cdr p) (+ y h 0.5))
                 (loop (+ i 3))))))))

;; ---- the mirror matrix ----
(define plane-ok
  (let ((below (m4-transform mirror (v3 2 3 -4)))
        (on (m4-transform mirror (v3 2 0 -4))))
    (and (near? (v3-y below) -3.0) (near? (v3-x below) 2.0) (near? (v3-z below) -4.0)
         (near? (v3-y on) 0.0))))
(check "a point mirrors across the plane and a point on it stays" plane-ok)

;; ---- nothing visible ----
(check "a reflector behind the camera answers #f"
       (eq? #f (reflect-range vp rvp (list (quad 0.0 60.0 1.0 1.0)) 0 W H)))
(check "no reflectors at all answers #f"
       (eq? #f (reflect-range vp rvp '() 0 W H)))

;; ---- everything visible ----
(check "a reflector larger than the view answers #t"
       (eq? #t (reflect-range vp rvp (list (quad 0.0 0.0 400.0 400.0)) 0 W H)))

;; ---- a rectangle, and it covers what it claims ----
(define small (quad 1.0 0.0 0.6 0.6))
(define r (reflect-range vp rvp (list small) 0 W H))
(check "a small reflector answers a rectangle" (vector? r))
(when (vector? r)
  (check "the rectangle covers every projected corner" (covers? r small rvp))
  (check "the rectangle is inside the target"
         (and (>= (vector-ref r 0) 0) (>= (vector-ref r 1) 0)
              (<= (+ (vector-ref r 0) (vector-ref r 2)) W)
              (<= (+ (vector-ref r 1) (vector-ref r 3)) H)))
  (check "the rectangle is smaller than the whole target"
         (< (* (vector-ref r 2) (vector-ref r 3)) (* W H))))

;; ---- pad grows it by exactly that many pixels, then clamps ----
(define r8 (reflect-range vp rvp (list small) 8 W H))
(when (and (vector? r) (vector? r8))
  (check "pad grows each side by the pixels asked for"
         (and (= (vector-ref r8 0) (max 0 (- (vector-ref r 0) 8)))
              (= (vector-ref r8 1) (max 0 (- (vector-ref r 1) 8)))))
  (check "pad never pushes the rectangle outside the target"
         (and (<= (+ (vector-ref r8 0) (vector-ref r8 2)) W)
              (<= (+ (vector-ref r8 1) (vector-ref r8 3)) H))))

;; ---- what cannot be projected conservatively answers #t ----
(check "a footprint crossing the eye plane answers #t"
       (eq? #t (reflect-range vp rvp (list (quad 0.0 10.0 30.0 30.0)) 0 W H)))

;; ---- a rotated footprint is still covered ----
(define tilted (vector -1.0 0.0 0.0   0.0 0.0 -1.0   1.0 0.0 0.0   0.0 0.0 1.0))
(define rt (reflect-range vp rvp (list tilted) 0 W H))
(check "a rotated footprint is covered"
       (or (eq? #t rt) (and (vector? rt) (covers? rt tilted rvp))))

;; ---- several coplanar reflectors answer their union ----
(define a (quad -2.0 0.0 0.4 0.4))
(define b (quad 2.0 0.0 0.4 0.4))
(define ra (reflect-range vp rvp (list a) 0 W H))
(define rb (reflect-range vp rvp (list b) 0 W H))
(define rab (reflect-range vp rvp (list a b) 0 W H))
(when (and (vector? ra) (vector? rb) (vector? rab))
  (check "two reflectors answer the union, not one of them"
         (and (covers? rab a rvp) (covers? rab b rvp)
              (> (vector-ref rab 2) (vector-ref ra 2))
              (> (vector-ref rab 2) (vector-ref rb 2)))))

;; ---- the cropped projection maps the rectangle to the whole of NDC ----
(when (vector? r)
  (let* ((x (vector-ref r 0)) (y (vector-ref r 1))
         (w (vector-ref r 2)) (h (vector-ref r 3))
         (cropped (m4-crop-rect rvp x y w h W H))
         ;; a world point that lands at the centre of the rectangle
         (cx (+ (exact->inexact x) (/ (exact->inexact w) 2.0)))
         (cy (+ (exact->inexact y) (/ (exact->inexact h) 2.0))))
    (let loop ((i 0) (best #f) (bd 1e30))
      (if (>= i (vector-length small))
          (when best
            (let ((p (m4-transform cropped (v3 (vector-ref small best)
                                               (vector-ref small (+ best 1))
                                               (vector-ref small (+ best 2))))))
              ;; a corner of the footprint keeps its side of NDC under the crop
              (check "the crop keeps a corner inside clip space"
                     (and (>= (v3-x p) -1.5) (<= (v3-x p) 1.5)
                          (>= (v3-y p) -1.5) (<= (v3-y p) 1.5)))))
          (let* ((p (project-px rvp (vector-ref small i) (vector-ref small (+ i 1))
                                (vector-ref small (+ i 2))))
                 (d (+ (abs (- (car p) cx)) (abs (- (cdr p) cy)))))
            (if (< d bd) (loop (+ i 3) i d) (loop (+ i 3) best bd)))))))

;; ---- refusals ----
(check "a target with no area is a named error"
       (refused? 'reflect-range (lambda () (reflect-range vp rvp (list small) 0 0 H))))
(check "a negative pad is a named error"
       (refused? 'reflect-range (lambda () (reflect-range vp rvp (list small) -1 W H))))

;; ---- the five shapes a first implementation got wrong, all in the same
;; ---- direction: a rectangle too small, or #f where the pass was needed.

;; A fractional pad must not produce a fractional rectangle: whoever
;; converts one to integers later can only shrink it.
(define rf (reflect-range vp rvp (list small) 3/2 W H))
(check "a fractional pad still answers whole pixels"
       (and (vector? rf)
            (integer? (vector-ref rf 0)) (integer? (vector-ref rf 1))
            (integer? (vector-ref rf 2)) (integer? (vector-ref rf 3))))
(when (and (vector? rf) (vector? r))
  (check "a fractional pad rounds outward, never inward"
         (and (<= (vector-ref rf 0) (vector-ref r 0))
              (<= (vector-ref rf 1) (vector-ref r 1))
              (>= (+ (vector-ref rf 0) (vector-ref rf 2)) (+ (vector-ref r 0) (vector-ref r 2)))
              (>= (+ (vector-ref rf 1) (vector-ref rf 3)) (+ (vector-ref r 1) (vector-ref r 3))))))

;; The reflection texture is sampled through projected coordinates, and
;; out of range CLAMP_TO_EDGE fetches an edge texel -- so a reflector that
;; is visible in the main view but whose reflection lands off the target
;; still needs that edge drawn.  It must be a RECTANGLE: answering #t
;; would be conservative and would also throw away the whole point.
(define ro (reflect-range vp rvp-off-target (list small) 0 W H))
(check "a reflection landing off the target still draws the edge"
       (and (vector? ro)
            (>= (vector-ref ro 2) 1) (>= (vector-ref ro 3) 1)
            (>= (vector-ref ro 0) 0) (>= (vector-ref ro 1) 0)
            (<= (+ (vector-ref ro 0) (vector-ref ro 2)) W)
            (<= (+ (vector-ref ro 1) (vector-ref ro 3)) H)))

;; Uncertainty falls toward #t.  A non-finite coordinate satisfies every
;; comparison that would put it behind the eye, so checking position
;; before finiteness answers #f -- the one answer that cannot be undone.
(define nan-vp
  (let ((m (make-vector 16 0.0)))
    (let loop ((i 0))
      (when (< i 16) (vector-set! m i (vector-ref vp i)) (loop (+ i 1))))
    (vector-set! m 15 (fl/ 0.0 0.0))
    m))
(check "a non-finite matrix answers the whole target"
       (eq? #t (reflect-range nan-vp rvp (list small) 0 W H)))
(check "a non-finite footprint answers the whole target"
       (eq? #t (reflect-range vp rvp (list (vector 0.0 (fl/ 0.0 0.0) 0.0
                                                   1.0 0.0 0.0  1.0 0.0 1.0)) 0 W H)))

;; A footprint crossing the near plane with every w still positive is
;; exactly clippable, so it must answer a rectangle that covers the part
;; in front -- the vertices the clip generates, not just the originals.
(define near-crossing
  (vector 0.0 3.98 9.954     ; just inside the near plane, w small and positive
          -2.0 0.0 0.0
          2.0 0.0 0.0))
(define rn (reflect-range vp rvp (list near-crossing) 0 W H))
(check "a near-plane crossing is clipped to a rectangle, not discarded and not given up on"
       (and (vector? rn) (covers? rn (vector -2.0 0.0 0.0  2.0 0.0 0.0) rvp)))

;; A sliver thinner than a pixel still covers pixels.
(define sliver (quad 1.0 0.0 0.6 0.0005))
(define rs (reflect-range vp rvp (list sliver) 0 W H))
(check "a sub-pixel sliver still answers at least one pixel, and only a few"
       (and (vector? rs) (>= (vector-ref rs 2) 1) (>= (vector-ref rs 3) 1)
            (< (vector-ref rs 3) 20)))

;; ---- the rectangle must reach the whole pixel, not the nearest one ----
;; covers? above allows half a pixel of slack, and the fractional-pad
;; cells compare one rectangle against another that was computed the same
;; way.  Neither notices if the whole computation rounds to nearest
;; instead of outward: every rectangle shrinks together and the relative
;; assertions still hold.  This one has no slack and no relative term --
;; the projected extent is computed here, in double precision, and the
;; rectangle must reach past it to the integer pixel boundary on all four
;; sides.  Rounding to nearest loses a pixel of reflection with nothing
;; to report it, which is the failure this library exists to prevent.
(define (px-floor v) (exact (floor v)))
(define (px-ceil v) (- (exact (floor (- 0.0 v)))))
(define (px-extent poly m)
  (let loop ((i 0) (x0 1e30) (x1 -1e30) (y0 1e30) (y1 -1e30))
    (if (>= i (vector-length poly))
        (list x0 x1 y0 y1)
        (let ((p (project-px m (vector-ref poly i) (vector-ref poly (+ i 1))
                             (vector-ref poly (+ i 2)))))
          (loop (+ i 3)
                (min x0 (car p)) (max x1 (car p))
                (min y0 (cdr p)) (max y1 (cdr p)))))))
(when (vector? r)
  (let ((e (px-extent small rvp)))
    (check "the rectangle reaches the whole pixel on every side"
           (and (<= (vector-ref r 0) (px-floor (car e)))
                (>= (+ (vector-ref r 0) (vector-ref r 2)) (px-ceil (cadr e)))
                (<= (vector-ref r 1) (px-floor (caddr e)))
                (>= (+ (vector-ref r 1) (vector-ref r 3)) (px-ceil (cadddr e)))))))

(display (= failed 0))
(newline)
