;; expect: #t
;; (gfx raster): the CPU rasterizer, checked against hand-computed
;; screen coordinates, a pixel-by-pixel countable footprint, and the
;; properties the interpolation must satisfy rather than a second copy
;; of its formulas.
;;
;; The projection nails and the barycentric literal are the numbers a
;; separate Python reference implementation is pinned to, so the two
;; toolchains answer to one oracle and not to each other.
(import (rnrs) (gfx raster))

(define (near? a b tol)
  (and (fl<? (fl- a b) tol) (fl<? (fl- b a) tol)))

;; ---- staging: a bump heap of our own, so this test needs no GL ----
(define $heap 65536)
(define (alloc! n)
  (let* ((r (remainder $heap 8))
         (base (if (= r 0) $heap (+ $heap (- 8 r))))
         (end (+ base n))
         (have (* 65536 (%mem-size))))
    (when (> end have)
      (%mem-grow (+ 1 (quotient (- end have) 65536))))
    (set! $heap end)
    base))

(define (mask8-equal? a b)
  (let loop ((i 0))
    (or (= i 64)
        (and (= (rmask-ref a (remainder i 8) (quotient i 8))
                (rmask-ref b (remainder i 8) (quotient i 8)))
             (loop (+ i 1))))))

;; ===================================================== 1. projection
;;
;; Fifteen independent nails: five marker vertices of a real asset
;; under three known cameras, the expected screen coordinates worked
;; out in closed form.  With f = 1/tan(22.5 deg) = 2.414213562373095
;; and k = 128f at 256x256,
;;
;;   az=0    right=(1,0,0)  up=(0,1,0)  fwd=(0,0,-1)
;;           sx = 128 + k*x/(300-z)      sy = 128 - k*(y-70)/(300-z)
;;   az=90   right=(0,0,-1) up=(0,1,0)  fwd=(-1,0,0)
;;           sx = 128 + k*(-z)/(300-x)   sy = 128 - k*(y-70)/(300-x)
;;   roll=90 right=(0,-1,0) up=(1,0,0)  fwd=(0,0,-1)
;;           sx = 128 - k*(y-70)/(300-z) sy = 128 - k*x/(300-z)
;;
;; Transposing the projection, swapping az's sin and cos, or writing
;; roll's sign backwards each breaks at least one of the three -- and
;; a silhouette is immune to every one of those mistakes, which is
;; why they are pinned here and not through a mask.

(define (nail-verts)
  (vector -1.1003118753433228 145.75112915039062 0.5352024435997009
          7.598199844360352 -0.13339999318122864 -2.808300018310547
          -31.10059928894043 78.23919677734375 -0.67330002784729
          31.10059928894043 78.23919677734375 -0.67330002784729
          2.7560999393463135 94.31839752197266 35.83539962768555))

(define (nail-az0)
  (vector 126.86458225518277 49.83200222168094
          135.75404990693497 199.57193741012222
          96.03611581049883 119.53210106471555
          159.9638841895012 119.53210106471555
          131.22408139455968 99.55237664759946))

(define (nail-az90)
  (vector 127.4507215794365 50.256594540610436
          130.96789898844526 202.11916303059746
          128.62839731480415 120.31027934518355
          128.77375675428442 118.53151063021484
          90.7449666909892 102.71821943900085))

(define (nail-roll90)
  (vector 49.83200222168094 129.13541774481723
          199.57193741012222 120.24595009306503
          119.53210106471555 159.9638841895012
          119.53210106471555 96.03611581049883
          99.55237664759946 124.77591860544034))

(define (nail-cam az roll)
  (make-rcam az 0.0 300.0 roll 45.0 0.0 70.0 0.0 0.0 0.0 #f #f))

(define (nails-ok? cam want)
  (let ((p (nail-verts)))
    (let loop ((i 0))
      (or (= i 5)
          (let ((got (rcam-project cam (vector-ref p (* i 3))
                                   (vector-ref p (+ (* i 3) 1))
                                   (vector-ref p (+ (* i 3) 2))
                                   256 256)))
            (and got
                 (near? (vector-ref got 0) (vector-ref want (* i 2))
                        0.000000001)
                 (near? (vector-ref got 1) (vector-ref want (+ (* i 2) 1))
                        0.000000001)
                 (loop (+ i 1))))))))

(define projection-ok
  (and (nails-ok? (nail-cam 0.0 0.0) (nail-az0))
       (nails-ok? (nail-cam 90.0 0.0) (nail-az90))
       (nails-ok? (nail-cam 0.0 90.0) (nail-roll90))))

;; Elevation carries a sign, and the three cameras above are all at
;; el=0, where flipping it changes nothing.  These two are the same
;; five vertices raised 30 degrees and lowered 30 degrees: positive
;; elevation lifts the camera and tips it down, so the whole figure
;; slides *up* the frame relative to the negative case.
(define (nail-el30)
  (vector 126.70054105276269 50.840156857284185
          134.95703497240254 182.32639967883176
          95.58222630058398 120.2115415286338
          160.41777369941602 120.2115415286338
          131.31645962766797 124.21839816905465))

(define (nail-el-30)
  (vector 126.99227775264751 67.67286059664744
          136.7819554408495 199.82273555589094
          96.45880672619536 121.10498085631838
          159.54119327380465 121.10498085631838
          131.02957289865458 85.1543681077506))

(define (el-cam el)
  (make-rcam 0.0 el 300.0 0.0 45.0 0.0 70.0 0.0 0.0 0.0 #f #f))

(define elevation-ok
  (and (nails-ok? (el-cam 30.0) (nail-el30))
       (nails-ok? (el-cam -30.0) (nail-el-30))
       ;; the plain statement of the same convention: at el=+30 on a
       ;; 300-unit orbit the eye sits 150 units above the target
       (let ((e (rcam-eye (el-cam 30.0))))
         (and (near? (vector-ref e 0) 0.0 0.000000001)
              (near? (vector-ref e 1) 220.0 0.000000001)
              (near? (vector-ref e 2) 259.8076211353316 0.000000001)))))

;; The basis and the eye of a camera with every degree of freedom
;; engaged at once, including the two frame shifts -- which no
;; silhouette taken through this same camera could ever pin, since
;; they move the eye and the target together.
(define basis-ok
  (let* ((c (make-rcam 35.0 15.0 218.0 12.0 45.0 1.0 72.0 11.0
                       0.5 -0.25 #f #f))
         (b (rcam-basis c))
         (e (rcam-eye c))
         (v (rcam-view c)))
    (and (near? (vector-ref b 0) 0.8321166181924371 0.000000001)
         (near? (vector-ref b 1) -0.20082727174830148 0.000000001)
         (near? (vector-ref b 2) -0.5169626104953005 0.000000001)
         (near? (vector-ref b 3) 0.02510282443860251 0.000000001)
         (near? (vector-ref b 4) 0.944818029471471 0.000000001)
         (near? (vector-ref b 5) -0.3266324224427996 0.000000001)
         (near? (vector-ref b 6) -0.5540322932223234 0.000000001)
         (near? (vector-ref b 7) -0.25881904510252074 0.000000001)
         (near? (vector-ref b 8) -0.7912401152362238 0.000000001)
         (near? (vector-ref e 0) 122.18882252545306 0.000000001)
         (near? (vector-ref e 1) 128.0859336891075 0.000000001)
         (near? (vector-ref e 2) 183.31352192185986 0.000000001)
         ;; rcam-view! is the same three rows plus the eye, not a
         ;; second derivation of either
         (fl=? (vector-ref v 0) (vector-ref b 0))
         (fl=? (vector-ref v 8) (vector-ref b 8))
         (fl=? (vector-ref v 9) (vector-ref e 0))
         (fl=? (vector-ref v 11) (vector-ref e 2)))))

;; a point at or behind the eye plane has no screen position at all
(define behind-ok
  (and (not (rcam-project (nail-cam 0.0 0.0) 0.0 70.0 400.0 256 256))
       (rcam-project (nail-cam 0.0 0.0) 0.0 70.0 0.0 256 256)
       #t))

;; the camera's own serialization round-trips through the reference
;; implementation's field order
(define serialize-ok
  (let* ((c (make-rcam 35.0 15.0 218.0 12.0 45.0 1.0 72.0 11.0
                       0.5 -0.25 0.21 2180.0))
         (d (list->rcam (rcam->list c))))
    (and (fl=? (rcam-az d) 35.0) (fl=? (rcam-el d) 15.0)
         (fl=? (rcam-dist d) 218.0) (fl=? (rcam-roll d) 12.0)
         (fl=? (rcam-fov d) 45.0) (fl=? (rcam-target-y d) 72.0)
         (fl=? (rcam-target-z d) 11.0)
         (fl=? (rcam-shift-u d) 0.5) (fl=? (rcam-shift-v d) -0.25)
         (fl=? (rcam-near d) 0.21) (fl=? (rcam-far d) 2180.0)
         ;; the defaults are derived, not stored as zero
         (let ((e (rcam 0.0 0.0 300.0 45.0 0.0 0.0 0.0)))
           (and (fl=? (rcam-near e) 0.3) (fl=? (rcam-far e) 30000.0))))))

;; ---- the inverse: the ray through a screen point projects back ----
(define ray-ok
  (let ((c (make-rcam 35.0 15.0 218.0 12.0 45.0 0.0 72.0 0.0
                      0.5 -0.25 #f #f)))
    (let loop ((k 0) (ok #t))
      (if (= k 5)
          ok
          (let* ((sx (fl+ 13.5 (fl* (fixnum->flonum k) 47.0)))
                 (sy (fl+ 200.0 (fl* (fixnum->flonum k) -33.0)))
                 (r (rcam-ray c sx sy 256 192))
                 (t 137.0)
                 (px (fl+ (vector-ref r 0) (fl* (vector-ref r 3) t)))
                 (py (fl+ (vector-ref r 1) (fl* (vector-ref r 4) t)))
                 (pz (fl+ (vector-ref r 2) (fl* (vector-ref r 5) t)))
                 (p (rcam-project c px py pz 256 192)))
            (loop (+ k 1)
                  (and ok p
                       (near? (vector-ref p 0) sx 0.000000001)
                       (near? (vector-ref p 1) sy 0.000000001))))))))

;; ============================================ 2. the footprint rule
;;
;; A single triangle on an 8x8 grid, every covered pixel countable by
;; hand.  The camera (az=el=roll=0, dist=8, fov=90, target the origin)
;; makes the mapping sx = 4 + x/2, sy = 4 - y/2, so the three world
;; positions below land on the screen points (0.7, 1.1), (7.2, 2.3)
;; and (1.9, 6.6).  Scanline by scanline, with row centres at j+0.5
;; and column centres at i+0.5:
;;
;;   row 1  x in [0.787, 2.867)  -> columns 1..2
;;   row 2  x in [1.005, 6.953)  -> columns 1..6
;;   row 3  x in [1.224, 5.721)  -> columns 1..5
;;   row 4  x in [1.442, 4.488)  -> columns 1..3
;;   row 5  x in [1.660, 3.256)  -> column  2
;;
;; -- 17 pixels.  Every one of those intervals clears the nearest
;; pixel centre by at least 0.01, so the literal does not sit on a
;; rounding edge.

(define (tri8-expected)
  (vector 0 0 0 0 0 0 0 0
          0 1 1 0 0 0 0 0
          0 1 1 1 1 1 1 0
          0 1 1 1 1 1 0 0
          0 1 1 1 0 0 0 0
          0 0 1 0 0 0 0 0
          0 0 0 0 0 0 0 0
          0 0 0 0 0 0 0 0))

(define tri8-pos
  (rattr-vector (vector -6.6 5.8 0.0  6.4 3.4 0.0  -4.2 -5.2 0.0) 3))
(define tri8 (make-rmesh tri8-pos (ridx-range 3)))
(define tri8-cam
  (make-rcam 0.0 0.0 8.0 0.0 90.0 0.0 0.0 0.0 0.0 0.0 0.1 #f))
(define tri8-mask (make-rmask 8 8 (alloc! (rmask-bytes 8 8))))
(define tri8-scratch (alloc! (raster-scratch-bytes 3)))
(define tri8-count (render-mask! tri8-mask tri8 tri8-cam tri8-scratch))

(define footprint-ok
  (let ((want (tri8-expected)))
    (and (= tri8-count 17)
         (let loop ((i 0))
           (or (= i 64)
               (and (= (rmask-ref tri8-mask (remainder i 8) (quotient i 8))
                       (vector-ref want i))
                    (loop (+ i 1))))))))

;; the projected corners are where the comment says they are
(define project-vertices-ok
  (and (near? (proj-x tri8-scratch 0) 0.7 0.000000001)
       (near? (proj-y tri8-scratch 0) 1.1 0.000000001)
       (near? (proj-x tri8-scratch 1) 7.2 0.000000001)
       (near? (proj-y tri8-scratch 1) 2.3 0.000000001)
       (near? (proj-x tri8-scratch 2) 1.9 0.000000001)
       (near? (proj-y tri8-scratch 2) 6.6 0.000000001)
       (near? (proj-depth tri8-scratch 0) 8.0 0.000000001)))

;; ---- tri-spans! answers in its own right, degenerate cases too ----
(define spans-buf (make-vector (tri-spans-capacity 0 64) 0))

(define (span-list ax ay bx by cx cy)
  (let ((n (tri-spans! ax ay bx by cx cy 0 64 spans-buf)))
    (let loop ((s (- n 1)) (acc '()))
      (if (< s 0)
          acc
          (loop (- s 1)
                (cons (list (vector-ref spans-buf (* s 3))
                            (vector-ref spans-buf (+ (* s 3) 1))
                            (vector-ref spans-buf (+ (* s 3) 2)))
                      acc))))))

(define spans-ok
  (and
   ;; the same five spans the 8x8 literal was counted from
   (equal? (span-list 0.7 1.1 7.2 2.3 1.9 6.6)
           '((1 1 3) (2 1 7) (3 1 6) (4 1 4) (5 2 3)))
   ;; a triangle collapsed onto a single point covers no pixel centre
   ;; anywhere, so it falls back to the one cell holding its centroid
   ;; -- no triangle ever has an empty footprint
   (equal? (span-list 3.2 3.2 3.2 3.2 3.2 3.2) '((3 3 4)))
   ;; a sliver thinner than a pixel does the same
   (equal? (span-list 10.1 10.1 10.9 10.15 10.5 10.12) '((10 10 11)))
   ;; zero area is not the same thing as an empty footprint: three
   ;; collinear points still cross scanlines, and those crossings are
   ;; reported rather than replaced by the fallback
   (equal? (span-list 3.0 3.0 5.0 5.0 4.0 4.0) '((3 3 4) (4 4 5)))
   ;; a flat-topped triangle, top edge at y=0.6: row 0's centre is at
   ;; 0.5, above the triangle, so the first row it can claim is 1
   (equal? (span-list 2.4 0.6 9.7 0.6 2.4 3.4) '((1 2 7) (2 2 5)))
   ;; A horizontal edge sitting exactly ON a row centre.  The rule is
   ;; half-open in y -- an edge counts on this scanline only for
   ;; yc in [py, qy) or [qy, py) -- so a horizontal edge counts for
   ;; neither of its two directions and the row is decided by the two
   ;; slanted edges alone.  Under a closed rule that edge divides by
   ;; its own zero height, and the row it lies on is lost or flooded.
   (equal? (span-list 2.0 2.5 6.0 2.5 4.0 5.5)
           '((2 2 6) (3 3 5) (4 3 5)))
   (equal? (span-list 2.0 5.5 6.0 5.5 4.0 2.5)
           '((3 3 5) (4 3 5)))))

;; ========================================== 3. perspective correction
;;
;; A triangle tilted in depth: every pixel's interpolated 3D point,
;; projected again, must land back on that pixel's centre.  Screen-space
;; (affine) barycentrics cannot satisfy this, and neither can
;; barycentrics whose two numerators are swapped.  The criterion copies
;; no formula from the code under test, so it cannot be wrong in the
;; same way.

(define tilt-pos
  (rattr-vector (vector -12.0 -12.0 12.0  12.0 -12.0 -12.0
                        -12.0 12.0 12.0) 3))
(define tilt (make-rmesh tilt-pos (ridx-range 3)))
(define tilt-cam
  (make-rcam 0.0 0.0 40.0 0.0 60.0 0.0 0.0 0.0 0.0 0.0 0.1 #f))
(define tilt-scratch (alloc! (raster-scratch-bytes 3)))
(define tilt-frame (make-rframe 48 48 (alloc! (rframe-bytes 48 48))))
(define tilt-rendered (render-frame! tilt-frame tilt tilt-cam tilt-scratch))

(define (tilt-worst affine?)
  (let ((p (make-vector 3 0.0))
        (x0 (proj-x tilt-scratch 0)) (y0 (proj-y tilt-scratch 0))
        (x1 (proj-x tilt-scratch 1)) (y1 (proj-y tilt-scratch 1))
        (x2 (proj-x tilt-scratch 2)) (y2 (proj-y tilt-scratch 2)))
    (let ((ar (fl- (fl* (fl- x1 x0) (fl- y2 y0))
                   (fl* (fl- x2 x0) (fl- y1 y0)))))
      (let loop ((k 0) (worst 0.0) (n 0))
        (if (= k 2304)
            (cons worst n)
            (let ((i (remainder k 48)) (j (quotient k 48)))
              (if (< (frame-tri tilt-frame i j) 0)
                  (loop (+ k 1) worst n)
                  (let ((xc (fl+ (fixnum->flonum i) 0.5))
                        (yc (fl+ (fixnum->flonum j) 0.5)))
                    (if affine?
                        ;; the control: screen-space weights on the same
                        ;; pixels, to show the criterion discriminates
                        (let* ((l1 (fl/ (fl- (fl* (fl- xc x0) (fl- y2 y0))
                                             (fl* (fl- x2 x0) (fl- yc y0)))
                                        ar))
                               (l2 (fl/ (fl- (fl* (fl- x1 x0) (fl- yc y0))
                                             (fl* (fl- xc x0) (fl- y1 y0)))
                                        ar))
                               (l0 (fl- (fl- 1.0 l1) l2)))
                          (let lp ((c 0))
                            (when (< c 3)
                              (vector-set! p c
                                (fl+ (fl+ (fl* (rattr-ref tilt-pos 0 c) l0)
                                          (fl* (rattr-ref tilt-pos 1 c) l1))
                                     (fl* (rattr-ref tilt-pos 2 c) l2)))
                              (lp (+ c 1)))))
                        (frame-interp! tilt-frame tilt tilt-pos i j p))
                    (let ((q (rcam-project tilt-cam (vector-ref p 0)
                                           (vector-ref p 1)
                                           (vector-ref p 2) 48 48)))
                      (if (not q)
                          (loop (+ k 1) 1000000.0 (+ n 1))
                          (let ((ex (fl- (vector-ref q 0) xc))
                                (ey (fl- (vector-ref q 1) yc)))
                            (loop (+ k 1)
                                  (let* ((ax (if (fl<? ex 0.0)
                                                 (fl- 0.0 ex) ex))
                                         (ay (if (fl<? ey 0.0)
                                                 (fl- 0.0 ey) ey))
                                         (m (if (fl<? ax ay) ay ax)))
                                    (if (fl<? worst m) m worst))
                                  (+ n 1)))))))))))))

(define perspective-ok
  (let ((p (tilt-worst #f))
        (a (tilt-worst #t)))
    (and (> (cdr p) 400)                    ; the triangle really covers
         (= (cdr p) (cdr a))                ; the same pixels both ways
         (fl<? (car p) 0.000001)            ; reprojection is self-consistent
         (fl<? 1.0 (car a)))))              ; and affine is not: the test bites

;; the barycentric literal, computed by hand for a triangle facing the
;; camera (all three depths equal, so perspective correction is the
;; identity and this pins the affine half alone):
;;   v0=(-10,-10,0) v1=(10,-10,0) v2=(-10,10,0), uv (0,0) (1,0) (0,1)
;;   camera az=el=roll=0, dist=20, fov=90 -> f=1, k=32 at 64x64:
;;     sx = 32 + 32x/20    sy = 32 - 32y/20
;;   pixel (24,40)'s centre (24.5, 40.5) back in world coordinates:
;;     x = (24.5-32)*20/32 = -4.6875     y = -(40.5-32)*20/32 = -5.3125
;;   both edges are 20 long, so
;;     l1 = (x+10)/20 = 0.265625   l2 = (y+10)/20 = 0.234375   l0 = 0.5
;;     uv = l0*(0,0) + l1*(1,0) + l2*(0,1) = (0.265625, 0.234375)
(define flat-pos
  (rattr-vector (vector -10.0 -10.0 0.0  10.0 -10.0 0.0
                        -10.0 10.0 0.0) 3))
(define flat-uv (rattr-vector (vector 0.0 0.0  1.0 0.0  0.0 1.0) 2))
(define flat (make-rmesh flat-pos (ridx-range 3)))
(define flat-cam
  (make-rcam 0.0 0.0 20.0 0.0 90.0 0.0 0.0 0.0 0.0 0.0 0.1 #f))
(define flat-scratch (alloc! (raster-scratch-bytes 3)))
(define flat-frame (make-rframe 64 64 (alloc! (rframe-bytes 64 64))))
(define flat-rendered (render-frame! flat-frame flat flat-cam flat-scratch))

(define barycentric-ok
  (let ((b (make-vector 3 0.0))
        (uv (make-vector 2 0.0)))
    (and (= (frame-tri flat-frame 24 40) 0)
         (frame-bary! flat-frame 24 40 b)
         (near? (vector-ref b 0) 0.5 0.000000001)
         (near? (vector-ref b 1) 0.265625 0.000000001)
         (near? (vector-ref b 2) 0.234375 0.000000001)
         ;; the interpolator is generic in the component count: the
         ;; same call reads a two-wide attribute
         (frame-interp! flat-frame flat flat-uv 24 40 uv)
         (= (rattr-ncomp flat-uv) 2)
         (near? (vector-ref uv 0) 0.265625 0.000000001)
         (near? (vector-ref uv 1) 0.234375 0.000000001)
         (let ((d (frame-depth flat-frame 24 40)))
           (and d (near? d 20.0 0.000000001)))
         ;; and a pixel nothing was rasterized on has no depth at all
         (not (frame-depth flat-frame 63 63))
         (not (frame-bary! flat-frame 63 63 b))
         (not (frame-interp! flat-frame flat flat-uv 63 63 uv)))))

;; ------------------------------------------------------------------
;; The centroid fallback, all the way through the full render.
;;
;; A sliver whose three corners land at (4.05, 3.95), (4.233, 3.96) and
;; (4.32, 3.52) covers no pixel centre at all, so the footprint becomes
;; the single cell holding its centroid -- pixel (4,3), which lies
;; **outside** the triangle.  Barycentrics evaluated there extrapolate
;; without bound, and on a triangle whose corners sit at depths 8, 12
;; and 5 they answer with a depth of 5.95 rather than a depth on the
;; triangle at all; on a steeper one they can drive 1/depth negative
;; and lose the pixel entirely, which is what breaks the two rendering
;; paths apart.  Weights that leave the triangle therefore collapse to
;; (1/3, 1/3, 1/3), and the perspective-correct weights that follow are
;; iz_k / sum(iz) -- pinned here as literals.

(define sliver-pos
  (rattr-vector (vector 0.1 0.1 0.0  0.7 0.12 -4.0  0.4 0.6 3.0) 3))
(define sliver (make-rmesh sliver-pos (ridx-range 3)))
(define sliver-scratch (alloc! (raster-scratch-bytes 3)))
(define sliver-frame (make-rframe 8 8 (alloc! (rframe-bytes 8 8))))
(define sliver-mask-a (make-rmask 8 8 (alloc! (rmask-bytes 8 8))))
(define sliver-mask-b (make-rmask 8 8 (alloc! (rmask-bytes 8 8))))
(define sliver-cov (render-mask! sliver-mask-a sliver tri8-cam sliver-scratch))
(define sliver-rendered
  (render-frame! sliver-frame sliver tri8-cam sliver-scratch))
(define sliver-cov2 (frame-mask! sliver-frame sliver-mask-b))

(define sliver-ok
  (let ((b (make-vector 3 0.0)))
    (and (= sliver-cov 1)                 ; exactly one cell, never zero
         (= sliver-cov2 1)
         (mask8-equal? sliver-mask-a sliver-mask-b)
         (= (rmask-ref sliver-mask-a 4 3) 1)
         (= (frame-tri sliver-frame 4 3) 0)
         (frame-bary! sliver-frame 4 3 b)
         (near? (vector-ref b 0) 0.3061224489795918 0.000000001)
         (near? (vector-ref b 1) 0.2040816326530612 0.000000001)
         (near? (vector-ref b 2) 0.48979591836734704 0.000000001)
         (let ((d (frame-depth sliver-frame 4 3)))
           (and d (near? d 7.346938775510203 0.000000001))))))

;; =================================================== 4. the z-buffer
;;
;; A small triangle at depth 16 in front of a large one at depth 24.
;; In the overlap the nearer one must win, whichever order they are
;; submitted in -- a painter's algorithm passes one order and fails
;; the other.

(define (zb-positions)
  (vector -4.0 4.0 4.0    4.0 4.0 4.0    -4.0 -4.0 4.0
          -54.0 54.0 -4.0  66.0 54.0 -4.0 -54.0 -66.0 -4.0))
(define zb-pos (rattr-vector (zb-positions) 3))
(define zb-cam
  (make-rcam 0.0 0.0 20.0 0.0 90.0 0.0 0.0 0.0 0.0 0.0 0.1 #f))
(define zb-scratch (alloc! (raster-scratch-bytes 6)))
(define zb-near-first
  (make-rmesh zb-pos (ridx-vector (vector 0 1 2 3 4 5))))
(define zb-far-first
  (make-rmesh zb-pos (ridx-vector (vector 3 4 5 0 1 2))))
(define zb-frame-a (make-rframe 16 16 (alloc! (rframe-bytes 16 16))))
(define zb-frame-b (make-rframe 16 16 (alloc! (rframe-bytes 16 16))))
(define zb-a (render-frame! zb-frame-a zb-near-first zb-cam zb-scratch))
(define zb-b (render-frame! zb-frame-b zb-far-first zb-cam zb-scratch))

(define (depth~ fr x y d)
  (let ((v (frame-depth fr x y)))
    (and v (near? v d 0.000000001))))

(define zbuffer-ok
  (and (= (frame-tri zb-frame-a 7 7) 0)      ; the overlap: the near one
       (depth~ zb-frame-a 7 7 16.0)
       (= (frame-tri zb-frame-a 2 2) 1)      ; only the far one reaches here
       (depth~ zb-frame-a 2 2 24.0)
       (= (frame-tri zb-frame-a 0 15) 1)
       (depth~ zb-frame-a 0 15 24.0)
       (not (frame-depth zb-frame-a 13 13))  ; and here, neither
       ;; submitted the other way round, the answer does not move
       (= (frame-tri zb-frame-b 7 7) 1)
       (depth~ zb-frame-b 7 7 16.0)
       (= (frame-tri zb-frame-b 2 2) 0)
       (depth~ zb-frame-b 2 2 24.0)))

;; per-pixel visibility, the criterion baking and feedback rest on
(define visibility-ok
  (and ;; a point on the near triangle -- world (-1,1,4), which lands
       ;; on the centre of pixel (7,7) -- is visible, both when it names
       ;; its own triangle and when it names none
       (frame-point-visible? zb-frame-a zb-cam 0 -1.0 1.0 4.0 0.004)
       (frame-point-visible? zb-frame-a zb-cam -1 -1.0 1.0 4.0 0.004)
       ;; the point of the far triangle behind that same pixel is not
       (not (frame-point-visible? zb-frame-a zb-cam 1 -1.5 1.5 -4.0 0.004))
       ;; where the far triangle is the frontmost thing, it is visible
       (frame-point-visible? zb-frame-a zb-cam 1 -16.5 16.5 -4.0 0.004)
       ;; behind the eye, and off the edge of frame, are both invisible
       (not (frame-point-visible? zb-frame-a zb-cam -1 0.0 0.0 400.0 0.004))
       (not (frame-point-visible? zb-frame-a zb-cam -1 400.0 0.0 4.0 0.004))))

;; ========================================================== 5. IoU
;;
;; The measure of fit is written once, so it is pinned once.  A
;; per-pixel agreement rate would read 0.98 on sparse masks and let a
;; pose search converge on nothing; only the ratio discriminates.

(define iou-a (make-rmask 2 2 (alloc! 4)))
(define iou-b (make-rmask 2 2 (alloc! 4)))

(define (fill4! m a b c d)
  (rmask-set! m 0 0 a) (rmask-set! m 1 0 b)
  (rmask-set! m 0 1 c) (rmask-set! m 1 1 d))

(define iou-ok
  (and (begin (fill4! iou-a 1 1 0 0) (fill4! iou-b 1 0 1 0)
              (near? (mask-iou iou-a iou-b) 0.3333333333333333
                     0.000000000001))
       (begin (fill4! iou-a 1 1 1 1) (fill4! iou-b 0 0 0 0)
              (fl=? (mask-iou iou-a iou-b) 0.0))
       (begin (fill4! iou-a 0 0 0 0) (fill4! iou-b 0 0 0 0)
              (fl=? (mask-iou iou-a iou-b) 1.0))
       (begin (fill4! iou-a 1 0 1 0) (fill4! iou-b 1 0 1 0)
              (fl=? (mask-iou iou-a iou-b) 1.0))
       ;; a mask against itself is 1 whatever is in it
       (fl=? (mask-iou tri8-mask tri8-mask) 1.0)
       (= (rmask-count tri8-mask) 17)))

;; ====================================== 6. the two paths must agree
;;
;; render-mask! builds no depth buffer and no barycentrics;
;; render-frame! builds both.  Neither culls backfaces, so their
;; silhouettes must be identical byte for byte.  Two separately
;; written fills being wrong in the very same way is far less likely
;; than either being wrong alone, which is what makes this worth a
;; test of its own.

(define grid-n 9)
(define (grid-positions)
  (let* ((n grid-n) (v (make-vector (* n n 3) 0.0)))
    (let row ((j 0))
      (when (< j n)
        (let col ((i 0))
          (when (< i n)
            (let ((k (* (+ (* j n) i) 3)))
              (vector-set! v k
                (fl- (fl* (fixnum->flonum i) 2.5) 10.0))
              (vector-set! v (+ k 1)
                (fl- (fl* (fixnum->flonum j) 2.5) 10.0))
              ;; a deterministic ripple: no trig, no host, same bytes
              ;; on every backend
              (vector-set! v (+ k 2)
                (fixnum->flonum
                 (- (remainder (* (+ (* i 37) (* j 17)) 29) 13) 6))))
            (col (+ i 1))))
        (row (+ j 1))))
    v))

(define (grid-indices)
  (let* ((n grid-n)
         (cells (* (- n 1) (- n 1)))
         ;; two triangles per cell, plus two deliberately degenerate
         ;; ones so the centroid fallback is exercised here too
         (v (make-vector (+ (* cells 6) 6) 0)))
    (let row ((j 0) (o 0))
      (if (= j (- n 1))
          (begin
            (vector-set! v o 0) (vector-set! v (+ o 1) 0)
            (vector-set! v (+ o 2) 1)          ; zero area
            (vector-set! v (+ o 3) 5) (vector-set! v (+ o 4) 6)
            (vector-set! v (+ o 5) 5)          ; zero area, other shape
            v)
          (let col ((i 0) (o o))
            (if (= i (- n 1))
                (row (+ j 1) o)
                (let ((a (+ (* j n) i)))
                  (vector-set! v o a)
                  (vector-set! v (+ o 1) (+ a 1))
                  (vector-set! v (+ o 2) (+ a n))
                  (vector-set! v (+ o 3) (+ a 1))
                  (vector-set! v (+ o 4) (+ a n 1))
                  (vector-set! v (+ o 5) (+ a n))
                  (col (+ i 1) (+ o 6)))))))))

(define grid-pos (rattr-vector (grid-positions) 3))
(define grid (make-rmesh grid-pos (ridx-vector (grid-indices))))
(define grid-scratch (alloc! (raster-scratch-bytes (* grid-n grid-n))))
(define grid-frame (make-rframe 64 64 (alloc! (rframe-bytes 64 64))))
(define grid-mask-a (make-rmask 64 64 (alloc! (rmask-bytes 64 64))))
(define grid-mask-b (make-rmask 64 64 (alloc! (rmask-bytes 64 64))))

(define (masks-equal? a b)
  (let loop ((i 0))
    (or (= i 4096)
        (and (= (rmask-ref a (remainder i 64) (quotient i 64))
                (rmask-ref b (remainder i 64) (quotient i 64)))
             (loop (+ i 1))))))

(define (degeneracy-at cam)
  (let ((ca (render-mask! grid-mask-a grid cam grid-scratch)))
    (render-frame! grid-frame grid cam grid-scratch)
    (let ((cb (frame-mask! grid-frame grid-mask-b)))
      (and (= ca cb) (> ca 200) (masks-equal? grid-mask-a grid-mask-b)))))

(define degeneracy-ok
  (and (degeneracy-at (make-rcam 0.0 0.0 40.0 0.0 45.0
                                 0.0 0.0 0.0 0.0 0.0 #f #f))
       (degeneracy-at (make-rcam 35.0 15.0 44.0 12.0 45.0
                                 0.0 0.0 0.0 1.5 -2.0 #f #f))
       (degeneracy-at (make-rcam -72.0 -22.0 38.0 0.0 35.0
                                 0.0 0.0 0.0 0.0 0.0 #f #f))
       (degeneracy-at (make-rcam 155.0 8.0 50.0 -30.0 55.0
                                 0.0 0.0 0.0 0.0 0.0 #f #f))))

;; the same identity with the camera pushed inside the mesh, so
;; triangles straddle the near plane and go through the clipper
(define near-clip-ok
  (degeneracy-at (make-rcam 20.0 5.0 6.0 0.0 60.0
                            0.0 0.0 0.0 0.0 0.0 0.05 #f)))

;; The two identities above only say the two paths agree, and they
;; agree just as well when the clipper is switched off entirely: on a
;; closed mesh the fragments it recovers are already covered by the
;; geometry around them, so a silhouette cannot see it working.  These
;; two triangles can.  Both straddle the near plane and neither has
;; anything in front of it, so without clipping the frame is empty:
;;
;;   camera az=el=roll=0, dist=10, fov=90, near=1, target the origin,
;;   32x32 -> view z = 10 - pz, sx = 16 + 16x/z, sy = 16 - 16y/z
;;
;;   triangle 0  one corner in front (z=10), two behind (z=-10):
;;               the clipped polygon is a triangle
;;   triangle 1  two corners in front, one behind: the clipped polygon
;;               is a quadrilateral, and comes back as a fan of two
;;
;; The depths and weights below are on the *clipped* fragments, and
;; the weights are still those of the original three corners -- which
;; is what lets one interpolator serve clipped and unclipped triangles
;; alike.
(define clip-pos
  (rattr-vector (vector 0.0 -5.0 0.0   -8.0 6.0 20.0   8.0 2.0 20.0
                        -6.0 -6.0 0.0   6.0 -7.0 0.0   0.0 8.0 20.0) 3))
(define clip-mesh (make-rmesh clip-pos (ridx-range 6)))
(define clip-cam
  (make-rcam 0.0 0.0 10.0 0.0 90.0 0.0 0.0 0.0 0.0 0.0 1.0 #f))
(define clip-scratch (alloc! (raster-scratch-bytes 6)))
(define clip-mask-a (make-rmask 32 32 (alloc! (rmask-bytes 32 32))))
(define clip-mask-b (make-rmask 32 32 (alloc! (rmask-bytes 32 32))))
(define clip-frame (make-rframe 32 32 (alloc! (rframe-bytes 32 32))))
(define clip-cov (render-mask! clip-mask-a clip-mesh clip-cam clip-scratch))
(define clip-rendered
  (render-frame! clip-frame clip-mesh clip-cam clip-scratch))
(define clip-cov2 (frame-mask! clip-frame clip-mask-b))

(define (clip-tri-pixels t)
  (let loop ((i 0) (n 0))
    (if (= i 1024)
        n
        (loop (+ i 1)
              (if (= t (frame-tri clip-frame (remainder i 32) (quotient i 32)))
                  (+ n 1) n)))))

(define (clip-pixel-ok x y t d b0 b1 b2)
  (let ((b (make-vector 3 0.0)))
    (and (= (frame-tri clip-frame x y) t)
         (let ((z (frame-depth clip-frame x y)))
           (and z (near? z d 0.000000001)))
         (frame-bary! clip-frame x y b)
         (near? (vector-ref b 0) b0 0.000000001)
         (near? (vector-ref b 1) b1 0.000000001)
         (near? (vector-ref b 2) b2 0.000000001))))

(define near-clip-literal-ok
  (and (= clip-cov 466)
       (= clip-cov2 466)
       (let loop ((i 0))
         (or (= i 1024)
             (and (= (rmask-ref clip-mask-a (remainder i 32) (quotient i 32))
                     (rmask-ref clip-mask-b (remainder i 32) (quotient i 32)))
                  (loop (+ i 1)))))
       (= (clip-tri-pixels 0) 169)
       (= (clip-tri-pixels 1) 297)
       ;; on the fan's first triangle
       (clip-pixel-ok 16 20 1 1.6802800466744445
                      0.28763127187864646 0.29638273045507585
                      0.41598599766627775)
       (clip-pixel-ok 2 20 1 2.0083682008368178
                      0.44142259414225915 0.15899581589958178
                      0.39958158995815907)
       ;; and on the fan's second
       (clip-pixel-ok 29 26 1 5.393258426966287
                      0.0056179775280901165 0.7640449438202241
                      0.23033707865168565)
       ;; the singly-clipped triangle
       (clip-pixel-ok 16 28 0 1.5458937198067646
                      0.5772946859903383 0.20833333333333331
                      0.21437198067632843)
       ;; and nothing above the horizon either triangle reaches
       (not (frame-depth clip-frame 16 5))
       (not (frame-depth clip-frame 8 12))))

;; And the plane clipped against is `near`, not zero.  This triangle
;; has one corner 0.2 in front of the eye -- in front, so a clipper
;; that only rejects what is behind keeps it, and 16x/0.2 throws the
;; corner far off frame and widens the footprint.  Cut at near=1 the
;; row is 27 pixels wide; cut at zero it is 31.
(define edge-pos
  (rattr-vector (vector 0.3 -0.2 9.8  -9.0 -9.0 0.0  9.0 -9.0 0.0) 3))
(define edge-mesh (make-rmesh edge-pos (ridx-range 3)))
(define edge-mask (make-rmask 32 32 (alloc! (rmask-bytes 32 32))))
(define edge-cov (render-mask! edge-mask edge-mesh clip-cam clip-scratch))

(define near-plane-position-ok
  (and (= edge-cov 27)
       (= (rmask-ref edge-mask 3 30) 0)
       (= (rmask-ref edge-mask 4 30) 1)
       (= (rmask-ref edge-mask 30 30) 1)
       (= (rmask-ref edge-mask 31 30) 0)
       ;; and that row is the whole of it
       (let loop ((i 0) (n 0))
         (if (= i 1024)
             (= n 27)
             (loop (+ i 1)
                   (+ n (rmask-ref edge-mask (remainder i 32)
                                   (quotient i 32))))))))

;; ====================================== 7. the input face is wide
;;
;; The same geometry read out of interleaved staging memory -- the
;; shape a glTF primitive's vertex block already has -- and out of
;; plain Scheme vectors must rasterize identically; and 16-bit and
;; 32-bit index streams must too.  Storing the coordinates as f32
;; rounds them (6.4 comes back as 6.4000000953674316, pinned below),
;; which the 8x8 footprint survives because every one of its spans
;; clears the nearest pixel centre by more than a hundredth.

(define stage-base (alloc! 256))
(define (write-tri8-staging!)
  ;; stride 20: three position floats then two unused ones, so the
  ;; offset/stride arithmetic is actually exercised
  (let ((p (vector -6.6 5.8 0.0  6.4 3.4 0.0  -4.2 -5.2 0.0)))
    (let loop ((v 0))
      (when (< v 3)
        (let ((o (+ stage-base (* v 20))))
          (%mem-f32-set! o (vector-ref p (* v 3)))
          (%mem-f32-set! (+ o 4) (vector-ref p (+ (* v 3) 1)))
          (%mem-f32-set! (+ o 8) (vector-ref p (+ (* v 3) 2)))
          (%mem-f32-set! (+ o 12) 99.0)
          (%mem-f32-set! (+ o 16) 99.0))
        (loop (+ v 1))))
    ;; u16 indices at +64, u32 indices at +96
    (let loop ((i 0))
      (when (< i 3)
        (%mem-u8-set! (+ stage-base 64 (* i 2)) i)
        (%mem-u8-set! (+ stage-base 64 (* i 2) 1) 0)
        (%mem-u8-set! (+ stage-base 96 (* i 4)) i)
        (%mem-u8-set! (+ stage-base 96 (* i 4) 1) 0)
        (%mem-u8-set! (+ stage-base 96 (* i 4) 2) 0)
        (%mem-u8-set! (+ stage-base 96 (* i 4) 3) 0)
        (loop (+ i 1))))))

(define staged (begin (write-tri8-staging!) #t))
(define stage-mask (make-rmask 8 8 (alloc! (rmask-bytes 8 8))))
(define stage-scratch (alloc! (raster-scratch-bytes 3)))

(define (render-staged idx)
  (render-mask! stage-mask
                (make-rmesh (rattr-f32 stage-base 20 0 3 3) idx)
                tri8-cam stage-scratch)
  (mask8-equal? stage-mask tri8-mask))

(define input-face-ok
  (and (= (rattr-count (rattr-f32 stage-base 20 0 3 3)) 3)
       (near? (rattr-ref (rattr-f32 stage-base 20 0 3 3) 1 0)
              6.4000000953674316 0.000000001)   ; f32 rounding, as stored
       (render-staged (ridx-u16 (+ stage-base 64) 3))
       (render-staged (ridx-u32 (+ stage-base 96) 3))
       (render-staged (ridx-range 3))
       ;; a wider attribute is accepted where positions are wanted:
       ;; the first three components are read and the rest ignored
       (begin
         (render-mask! stage-mask
                       (make-rmesh (rattr-f32 stage-base 20 0 3 5)
                                   (ridx-range 3))
                       tri8-cam stage-scratch)
         (mask8-equal? stage-mask tri8-mask))))

;; =========================== 10. accumulating a second silhouette
;;
;; render-mask! clears at entry, so rendering an asset's primitives
;; one after another leaves only the last one in the mask.  The
;; accumulate entry render-mask-add! keeps what is already there,
;; letting a multi-primitive asset union into one mask without a
;; per-primitive copy.  The second triangle below lands on rows 6-7,
;; disjoint from tri8's rows 1-5 footprint, so union arithmetic is
;; exact: counts add, and tri8's pixel (1,1) either survives (add)
;; or does not (plain).

(define tri8b-pos
  (rattr-vector (vector 4.2 -4.2 0.0  6.8 -4.4 0.0  4.4 -6.8 0.0) 3))
(define tri8b (make-rmesh tri8b-pos (ridx-range 3)))
(define acc-mask (make-rmask 8 8 (alloc! (rmask-bytes 8 8))))
(define acc-b-count (render-mask! acc-mask tri8b tri8-cam tri8-scratch))
(define accumulate-ok
  (and (> acc-b-count 0)
       ;; the plain entry clears: after A then B, only B remains
       (let* ((c1 (render-mask! acc-mask tri8 tri8-cam tri8-scratch))
              (c2 (render-mask! acc-mask tri8b tri8-cam tri8-scratch)))
         (and (= c1 17) (= c2 acc-b-count)
              (= 0 (rmask-ref acc-mask 1 1))))
       ;; the add entry unions: A then +B holds both footprints
       (let* ((c1 (render-mask! acc-mask tri8 tri8-cam tri8-scratch))
              (c2 (render-mask-add! acc-mask tri8b tri8-cam tri8-scratch)))
         (and (= c1 17)
              (= c2 (+ 17 acc-b-count))
              (= 1 (rmask-ref acc-mask 1 1))))))

;; ---------------------------------------------------------------
(define main-ok
  (and projection-ok elevation-ok basis-ok behind-ok serialize-ok ray-ok
       footprint-ok project-vertices-ok spans-ok
       perspective-ok barycentric-ok sliver-ok
       zbuffer-ok visibility-ok iou-ok
       degeneracy-ok near-clip-ok near-clip-literal-ok
       near-plane-position-ok input-face-ok accumulate-ok))

main-ok
