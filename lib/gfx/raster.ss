;; A CPU rasterizer: orbit camera -> vertex projection -> screen-space
;; triangle scanline -> z-buffer -> perspective-correct barycentrics.
;; No canvas is touched and no GL command is issued; the whole module
;; is arithmetic over staging memory, so it verifies headlessly and
;; runs identically on the Wasm and the JS backend.
;;
;; What it is for: fitting pipelines.  Searching for the camera pose
;; that best explains a photograph, baking photographs back onto a UV
;; atlas, and deciding what a given view can actually see are all the
;; same three questions -- where does this vertex land, which pixels
;; does this triangle cover, and what is in front of what.  Those and
;; nothing else live here; shading, textures and image I/O are the
;; caller's business and are deliberately absent.
;;
;;   (define scr (make-rmask 256 256 (fx-alloc! (rmask-bytes 256 256))))
;;   (define scratch (fx-alloc! (raster-scratch-bytes nverts)))
;;   (define cam (rcam 35.0 15.0 300.0 45.0 0.0 70.0 0.0))
;;   (render-mask! scr mesh cam scratch)
;;   (mask-iou scr reference)
;;
;; Two rendering paths, on purpose.  `render-mask!` wants nothing but
;; the silhouette, so it builds no depth buffer and computes no
;; barycentrics.  `render-frame!` builds the full visibility buffer
;; (per pixel: triangle id, perspective-correct barycentrics, 1/depth).
;; Neither culls backfaces, so for one and the same camera the two
;; masks must agree bit for bit -- a cross-check worth having, since
;; the chance that two separately written fills are wrong in the very
;; same way is far below the chance of either being wrong alone.
;;
;; The footprint rule lives in exactly one place, `tri-spans!`: a
;; pixel is covered when its centre lies inside the triangle (row
;; centres at y=j+0.5, column centres at x=i+0.5), and a triangle
;; that covers no centre at all falls back to the single cell holding
;; its centroid, so no triangle ever has an empty footprint.
;; `tri-spans!` neither clips nor wraps; a viewport is the caller's
;; policy, expressed as the row window it asks for and the column
;; clamp it applies.
;;
;; Screen coordinates: x right over [0,W], y **downwards** over [0,H],
;; pixel centres at (i+.5, j+.5).  The near plane clips; the far plane
;; is metadata that travels with the camera and is never applied.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (gfx raster)
  (export ;; camera
          make-rcam rcam rcam?
          rcam-az rcam-el rcam-dist rcam-roll rcam-fov
          rcam-target-x rcam-target-y rcam-target-z
          rcam-shift-u rcam-shift-v rcam-near rcam-far
          rcam->list list->rcam
          rcam-basis rcam-basis! rcam-eye rcam-eye!
          rcam-view rcam-view!
          rcam-project rcam-project! rcam-ray rcam-ray!
          ;; attribute and index sources
          rattr? rattr-count rattr-ncomp rattr-ref
          rattr-f32 rattr-f64 rattr-vector rattr-proc
          ridx? ridx-count ridx-ref
          ridx-u16 ridx-u32 ridx-vector ridx-range ridx-proc
          ;; mesh
          make-rmesh rmesh? rmesh-positions rmesh-indices
          rmesh-vertex-count rmesh-tri-count rmesh-tri
          ;; projected-vertex scratch
          raster-scratch-bytes
          project-vertices! proj-x proj-y proj-depth
          ;; the footprint rule
          tri-spans! tri-spans-capacity
          ;; masks
          make-rmask rmask? rmask-base rmask-width rmask-height
          rmask-bytes rmask-clear! rmask-ref rmask-set! rmask-count
          render-mask! mask-iou
          ;; visibility buffer
          make-rframe rframe? rframe-base rframe-width rframe-height
          rframe-bytes rframe-clear! render-frame!
          frame-tri frame-depth frame-invd frame-bary!
          frame-interp! frame-mask! frame-point-visible?)
  (import (rnrs) (gfx mat))

  ;; ---------------------------------------------------------------
  ;; scalar helpers.  The prelude has no flabs/flmin/flmax/flceiling,
  ;; and no exponent literals, so the constants are written out.

  (define ($fl v) (if (flonum? v) v (exact->inexact v)))
  (define ($abs x) (if (fl<? x 0.0) (fl- 0.0 x) x))
  (define ($min a b) (if (fl<? a b) a b))
  (define ($max a b) (if (fl<? a b) b a))
  (define ($ceil x) (fl- 0.0 (flfloor (fl- 0.0 x))))

  ;; %fl->fx traps past the fixnum range, so every flonum that is
  ;; about to become an index is pinned into a safe window first.
  ;; Columns are clamped far outside any viewport the caller can pass
  ;; (2^28), so the clamp can never change which pixels get written --
  ;; the caller clamps to [0,W) anyway -- and the decision that
  ;; produced the span was already taken in flonum arithmetic.
  (define $col-limit 268435456.0)
  ;; Rows are different: a triangle grazing the near plane projects to
  ;; coordinates large enough that walking every scanline between them
  ;; would not terminate in useful time.  A million rows above and
  ;; below is several thousand viewports; past that the triangle is
  ;; certainly not empty, which is the only thing rows outside the
  ;; window are consulted for.
  (define $row-limit 1048576.0)

  (define ($ifloor x)
    (%fl->fx (flfloor ($max (fl- 0.0 $col-limit) ($min $col-limit x)))))

  (define ($irow x)
    (%fl->fx ($max (fl- 0.0 $row-limit) ($min $row-limit x))))

  (define $deg->rad 0.017453292519943295)  ; the double nearest pi/180
  (define ($radians d) (fl* d $deg->rad))

  ;; sin and cos of an angle in DEGREES, out[0] = sin, out[1] = cos.
  ;;
  ;; Reducing in degrees, not in radians, is what keeps the axis
  ;; cameras exact.  A quarter turn is an integer here, so cos 0 comes
  ;; back as 1.0 -- where a reduction that has to evaluate a sine
  ;; series at pi/2 answers 1.0 minus a few parts in 1e12, and that
  ;; error arrives at the eye position multiplied by dist and is worth
  ;; a nanometre of screen space on a 300-unit orbit.  Folded onto
  ;; [0,45] degrees the series argument never leaves [0, pi/4], where
  ;; its truncation is far below an ulp, and the cosine comes from
  ;; sqrt(1 - sin^2): exactly 1 at 0 and still well conditioned at 45.
  (define ($sincosd! d out)
    (let* ((q (flfloor (fl/ d 360.0)))
           (r (fl- d (fl* q 360.0)))
           (k0 (%fl->fx (flfloor (fl/ r 90.0))))
           (k (if (> k0 3) 0 k0))       ; r rounding up to 360.0 exactly
           (m (fl- r (fl* (fixnum->flonum k0) 90.0)))
           (sw (fl<? 45.0 m))
           (mm (if sw (fl- 90.0 m) m))
           (s0 (flsin ($radians mm)))
           (c0 (flsqrt (fl- 1.0 (fl* s0 s0))))
           (sm (if sw c0 s0))
           (cm (if sw s0 c0)))
      (cond ((= k 0) (vector-set! out 0 sm)
                     (vector-set! out 1 cm))
            ((= k 1) (vector-set! out 0 cm)
                     (vector-set! out 1 (fl- 0.0 sm)))
            ((= k 2) (vector-set! out 0 (fl- 0.0 sm))
                     (vector-set! out 1 (fl- 0.0 cm)))
            (else    (vector-set! out 0 (fl- 0.0 cm))
                     (vector-set! out 1 sm)))
      out))

  ;; ---------------------------------------------------------------
  ;; the camera
  ;;
  ;; An orbit camera around `target`.  The conventions are stated here
  ;; and nowhere else may assume a second set:
  ;;
  ;;   * world +Y is up.
  ;;   * az   azimuth in degrees.  At az=0 the camera sits in the +Z
  ;;          direction from target and looks towards -Z; increasing
  ;;          az rotates the camera about +Y towards +X.
  ;;   * el   elevation in degrees; positive raises the camera so it
  ;;          looks down.
  ;;   * dist camera-to-target distance.
  ;;   * roll roll about the view direction in degrees; positive turns
  ;;          the picture content clockwise.
  ;;   * fov  the **vertical** field of view in degrees; the
  ;;          horizontal one follows from the aspect ratio.
  ;;   * shift-u / shift-v  translate target along the camera's right
  ;;          and up directions, in world units.  This is how "the
  ;;          subject is off-centre in frame" is said without opening
  ;;          two more degrees of freedom that move world coordinates.
  ;;   * near the near plane, which **is** used for clipping.
  ;;   * far  metadata that travels along: there is no far clipping.

  (define-record-type ($rcam $make-rcam rcam?)
    (fields (immutable az rcam-az)
            (immutable el rcam-el)
            (immutable dist rcam-dist)
            (immutable roll rcam-roll)
            (immutable fov rcam-fov)
            (immutable tx rcam-target-x)
            (immutable ty rcam-target-y)
            (immutable tz rcam-target-z)
            (immutable su rcam-shift-u)
            (immutable sv rcam-shift-v)
            (immutable near rcam-near)
            (immutable far rcam-far)))

  ;; near and far accept #f, meaning "the defaults derived from dist"
  ;; -- the same rule the reference implementation applies, so a
  ;; serialized camera that omits them reconstructs identically.
  (define (make-rcam az el dist roll fov tx ty tz su sv near far)
    (let ((d ($fl dist)))
      ($make-rcam ($fl az) ($fl el) d ($fl roll) ($fl fov)
                  ($fl tx) ($fl ty) ($fl tz) ($fl su) ($fl sv)
                  (if near ($fl near) ($max 0.0001 (fl* d 0.001)))
                  (if far ($fl far) (fl* d 100.0)))))

  (define (rcam az el dist fov tx ty tz)
    (make-rcam az el dist 0.0 fov tx ty tz 0.0 0.0 #f #f))

  ;; The serialization order is the reference implementation's KEYS
  ;; tuple, so a camera crossing between the two toolchains keeps its
  ;; meaning without either side owning a private field order.
  (define (rcam->list c)
    (list (rcam-az c) (rcam-el c) (rcam-dist c) (rcam-roll c)
          (rcam-fov c)
          (list (rcam-target-x c) (rcam-target-y c) (rcam-target-z c))
          (rcam-shift-u c) (rcam-shift-v c)
          (rcam-near c) (rcam-far c)))

  (define ($seq-ref s i)
    (if (vector? s) (vector-ref s i) (list-ref s i)))

  (define (list->rcam l)
    (let ((t ($seq-ref l 5)))
      (make-rcam ($seq-ref l 0) ($seq-ref l 1) ($seq-ref l 2)
                 ($seq-ref l 3) ($seq-ref l 4)
                 ($seq-ref t 0) ($seq-ref t 1) ($seq-ref t 2)
                 ($seq-ref l 6) ($seq-ref l 7)
                 ($seq-ref l 8) ($seq-ref l 9))))

  ;; right up fwd, nine flonums into out[0..8].  fwd is the unit
  ;; vector the camera looks along.
  (define (rcam-basis! c out)
    (let* ((sc (make-vector 2 0.0))
           (sa (vector-ref ($sincosd! (rcam-az c) sc) 0))
           (ca (vector-ref sc 1))
           (se (vector-ref ($sincosd! (rcam-el c) sc) 0))
           (ce (vector-ref sc 1))
           ;; direction of the camera relative to target (az=0 -> +Z)
           (ox (fl* sa ce)) (oy se) (oz (fl* ca ce))
           (fx (fl- 0.0 ox)) (fy (fl- 0.0 oy)) (fz (fl- 0.0 oz))
           ;; straight up or straight down needs another reference up
           (up-z? (fl<? 0.9999 ($abs fy)))
           (wx 0.0) (wy (if up-z? 0.0 1.0)) (wz (if up-z? 1.0 0.0))
           (crx (fl- (fl* fy wz) (fl* fz wy)))
           (cry (fl- (fl* fz wx) (fl* fx wz)))
           (crz (fl- (fl* fx wy) (fl* fy wx)))
           (len (flsqrt (fl+ (fl+ (fl* crx crx) (fl* cry cry))
                             (fl* crz crz))))
           (zl (fl=? len 0.0))
           (rx (if zl 0.0 (fl/ crx len)))
           (ry (if zl 0.0 (fl/ cry len)))
           (rz (if zl 1.0 (fl/ crz len)))
           (ux (fl- (fl* ry fz) (fl* rz fy)))
           (uy (fl- (fl* rz fx) (fl* rx fz)))
           (uz (fl- (fl* rx fy) (fl* ry fx)))
           (sr (vector-ref ($sincosd! (rcam-roll c) sc) 0))
           (cr (vector-ref sc 1)))
      ;; a positive roll turns the picture content clockwise, which is
      ;; the basis turning anticlockwise
      (vector-set! out 0 (fl- (fl* cr rx) (fl* sr ux)))
      (vector-set! out 1 (fl- (fl* cr ry) (fl* sr uy)))
      (vector-set! out 2 (fl- (fl* cr rz) (fl* sr uz)))
      (vector-set! out 3 (fl+ (fl* sr rx) (fl* cr ux)))
      (vector-set! out 4 (fl+ (fl* sr ry) (fl* cr uy)))
      (vector-set! out 5 (fl+ (fl* sr rz) (fl* cr uz)))
      (vector-set! out 6 fx)
      (vector-set! out 7 fy)
      (vector-set! out 8 fz)
      out))

  (define (rcam-basis c) (rcam-basis! c (make-vector 9 0.0)))

  ;; right up fwd eye, twelve flonums: taking a world point into view
  ;; space then costs three dot products.
  (define (rcam-view! c out)
    (rcam-basis! c out)
    (let ((d (rcam-dist c)) (su (rcam-shift-u c)) (sv (rcam-shift-v c)))
      (vector-set! out 9
        (fl+ (fl+ (fl- (rcam-target-x c) (fl* (vector-ref out 6) d))
                  (fl* (vector-ref out 0) su))
             (fl* (vector-ref out 3) sv)))
      (vector-set! out 10
        (fl+ (fl+ (fl- (rcam-target-y c) (fl* (vector-ref out 7) d))
                  (fl* (vector-ref out 1) su))
             (fl* (vector-ref out 4) sv)))
      (vector-set! out 11
        (fl+ (fl+ (fl- (rcam-target-z c) (fl* (vector-ref out 8) d))
                  (fl* (vector-ref out 2) su))
             (fl* (vector-ref out 5) sv)))
      out))

  (define (rcam-view c) (rcam-view! c (make-vector 12 0.0)))

  (define (rcam-eye! c out)
    (let ((v (rcam-view c)))
      (vector-set! out 0 (vector-ref v 9))
      (vector-set! out 1 (vector-ref v 10))
      (vector-set! out 2 (vector-ref v 11))
      out))

  (define (rcam-eye c) (rcam-eye! c (make-vector 3 0.0)))

  ;; 1/tan(fov/2): the reciprocal of a tangent, not a cotangent series,
  ;; because that is the shape the reference implementation rounds --
  ;; a half-degree of field of view is a pixel of disagreement at the
  ;; frame edge and the fixtures are pinned to nine places.
  (define ($focal c)
    (let ((sc ($sincosd! (fl* (rcam-fov c) 0.5) (make-vector 2 0.0))))
      (fl/ 1.0 (fl/ (vector-ref sc 0) (vector-ref sc 1)))))
  (define ($aspect w h) (fl/ (fixnum->flonum w) (fixnum->flonum h)))

  ;; Project one point -> #t with out[0..2] = (sx, sy, depth), depth
  ;; being the distance along the view direction; #f when the point is
  ;; at or behind the eye plane.
  (define (rcam-project! c px py pz w h out)
    (let* ((v (rcam-view c))
           (dx (fl- ($fl px) (vector-ref v 9)))
           (dy (fl- ($fl py) (vector-ref v 10)))
           (dz (fl- ($fl pz) (vector-ref v 11)))
           (xv (fl+ (fl+ (fl* dx (vector-ref v 0))
                         (fl* dy (vector-ref v 1)))
                    (fl* dz (vector-ref v 2))))
           (yv (fl+ (fl+ (fl* dx (vector-ref v 3))
                         (fl* dy (vector-ref v 4)))
                    (fl* dz (vector-ref v 5))))
           (zv (fl+ (fl+ (fl* dx (vector-ref v 6))
                         (fl* dy (vector-ref v 7)))
                    (fl* dz (vector-ref v 8)))))
      (and (fl<? 0.0 zv)
           (let ((f ($focal c)) (a ($aspect w h)))
             (vector-set! out 0
               (fl* (fl* (fl+ 1.0 (fl/ (fl* (fl/ f a) xv) zv)) 0.5)
                    (fixnum->flonum w)))
             (vector-set! out 1
               (fl* (fl* (fl- 1.0 (fl/ (fl* f yv) zv)) 0.5)
                    (fixnum->flonum h)))
             (vector-set! out 2 zv)
             #t))))

  (define (rcam-project c px py pz w h)
    (let ((out (make-vector 3 0.0)))
      (and (rcam-project! c px py pz w h out) out)))

  ;; The inverse: the world-space ray through a screen point, out[0..2]
  ;; the origin (the eye) and out[3..5] a unit direction.  Every point
  ;; origin + t*dir with t > 0 projects back to exactly (sx, sy), which
  ;; is what the round-trip test checks.
  (define (rcam-ray! c sx sy w h out)
    (let* ((v (rcam-view c))
           (f ($focal c))
           (a ($aspect w h))
           (hw (fl* 0.5 (fixnum->flonum w)))
           (hh (fl* 0.5 (fixnum->flonum h)))
           (xz (fl* (fl- (fl/ ($fl sx) hw) 1.0) (fl/ a f)))
           (yz (fl/ (fl- 1.0 (fl/ ($fl sy) hh)) f))
           (dx (fl+ (fl+ (fl* (vector-ref v 0) xz)
                         (fl* (vector-ref v 3) yz))
                    (vector-ref v 6)))
           (dy (fl+ (fl+ (fl* (vector-ref v 1) xz)
                         (fl* (vector-ref v 4) yz))
                    (vector-ref v 7)))
           (dz (fl+ (fl+ (fl* (vector-ref v 2) xz)
                         (fl* (vector-ref v 5) yz))
                    (vector-ref v 8)))
           (len (flsqrt (fl+ (fl+ (fl* dx dx) (fl* dy dy)) (fl* dz dz))))
           (il (if (fl=? len 0.0) 1.0 (fl/ 1.0 len))))
      (vector-set! out 0 (vector-ref v 9))
      (vector-set! out 1 (vector-ref v 10))
      (vector-set! out 2 (vector-ref v 11))
      (vector-set! out 3 (fl* dx il))
      (vector-set! out 4 (fl* dy il))
      (vector-set! out 5 (fl* dz il))
      out))

  (define (rcam-ray c sx sy w h)
    (rcam-ray! c sx sy w h (make-vector 6 0.0)))

  ;; ---------------------------------------------------------------
  ;; attribute sources
  ;;
  ;; Everything per-vertex -- positions, normals, UVs, colours, a
  ;; scalar mask, anything -- is one shape: a count, a component
  ;; count, and a reader.  Positions are simply an attribute whose
  ;; first three components are read, so a source carrying more than
  ;; three (a whole interleaved vertex) is accepted where positions
  ;; are wanted, and the interpolator works at any width without a
  ;; second interface.

  (define-record-type ($rattr $make-rattr rattr?)
    (fields (immutable count rattr-count)
            (immutable ncomp rattr-ncomp)
            (immutable get $rattr-get)))

  (define (rattr-ref a i k) (($rattr-get a) i k))

  ;; interleaved 32-bit floats in staging memory: exactly the shape
  ;; a glTF primitive's vertex block already has (base, stride and
  ;; the attribute's byte offset inside the vertex).
  (define (rattr-f32 base stride offset count ncomp)
    ($make-rattr count ncomp
      (lambda (i k)
        (%mem-f32-ref (+ base offset (* i stride) (* k 4))))))

  (define (rattr-f64 base stride offset count ncomp)
    ($make-rattr count ncomp
      (lambda (i k)
        (%mem-f64-ref (+ base offset (* i stride) (* k 8))))))

  ;; a flat Scheme vector, ncomp values per element.  Exact numbers
  ;; are coerced on the way out, so a literal written (0 1 0) reads
  ;; back as flonums.
  (define (rattr-vector v ncomp)
    ($make-rattr (quotient (vector-length v) ncomp) ncomp
      (lambda (i k) ($fl (vector-ref v (+ (* i ncomp) k))))))

  (define (rattr-proc count ncomp get)
    ($make-rattr count ncomp (lambda (i k) ($fl (get i k)))))

  ;; ---------------------------------------------------------------
  ;; index sources

  (define-record-type ($ridx $make-ridx ridx?)
    (fields (immutable count ridx-count)
            (immutable get $ridx-get)))

  (define (ridx-ref x i) (($ridx-get x) i))

  (define (ridx-u16 base count)
    ($make-ridx count
      (lambda (i)
        (let ((o (+ base (* i 2))))
          (+ (%mem-u8-ref o) (* 256 (%mem-u8-ref (+ o 1))))))))

  ;; assembled by multiplication rather than shifts: an index at or
  ;; past 2^29 would trap the bitwise operators, and the arithmetic
  ;; form says the same thing without that edge.
  (define (ridx-u32 base count)
    ($make-ridx count
      (lambda (i)
        (let ((o (+ base (* i 4))))
          (+ (%mem-u8-ref o)
             (* 256 (%mem-u8-ref (+ o 1)))
             (* 65536 (%mem-u8-ref (+ o 2)))
             (* 16777216 (%mem-u8-ref (+ o 3))))))))

  (define (ridx-vector v)
    ($make-ridx (vector-length v) (lambda (i) (vector-ref v i))))

  ;; the non-indexed draw: vertex i is triangle corner i
  (define (ridx-range count) ($make-ridx count (lambda (i) i)))

  (define (ridx-proc count get) ($make-ridx count get))

  ;; ---------------------------------------------------------------
  ;; the mesh: positions plus a triangle list, and nothing else the
  ;; rasterizer would have to know about.

  (define-record-type ($rmesh $make-rmesh rmesh?)
    (fields (immutable pos rmesh-positions)
            (immutable idx rmesh-indices)))

  (define (make-rmesh positions indices)
    (when (< (rattr-ncomp positions) 3)
      (error 'make-rmesh "positions need at least 3 components"))
    ($make-rmesh positions indices))

  (define (rmesh-vertex-count m) (rattr-count (rmesh-positions m)))
  (define (rmesh-tri-count m) (quotient (ridx-count (rmesh-indices m)) 3))

  ;; corner k (0..2) of triangle t, as a vertex index
  (define (rmesh-tri m t k) (ridx-ref (rmesh-indices m) (+ (* t 3) k)))

  ;; ---------------------------------------------------------------
  ;; projected vertices
  ;;
  ;; One pass over the mesh writes three f64s per vertex -- screen x,
  ;; screen y, depth -- into caller-owned staging.  A vertex at or
  ;; inside near gets depth 0.0; near-plane clipping is left a level
  ;; up, per triangle, where the two survivors are still available.

  (define (raster-scratch-bytes vertex-count) (* 24 vertex-count))

  (define (proj-x base i) (%mem-f64-ref (+ base (* i 24))))
  (define (proj-y base i) (%mem-f64-ref (+ base (* i 24) 8)))
  (define (proj-depth base i) (%mem-f64-ref (+ base (* i 24) 16)))

  (define ($proj-set! base i x y d)
    (%mem-f64-set! (+ base (* i 24)) x)
    (%mem-f64-set! (+ base (* i 24) 8) y)
    (%mem-f64-set! (+ base (* i 24) 16) d))

  ;; The three planes are interleaved per vertex (x, y, depth
  ;; adjacent) rather than laid out as three arrays: the consumers
  ;; read all three of one vertex at a time, and interleaving keeps
  ;; the layout independent of the vertex count, so a caller may
  ;; project a sub-range into the same block.
  (define (project-vertices! mesh cam w h base)
    (let* ((pos (rmesh-positions mesh))
           (get ($rattr-get pos))
           (n (rattr-count pos))
           (v (rcam-view cam))
           (rx (vector-ref v 0)) (ry (vector-ref v 1)) (rz (vector-ref v 2))
           (ux (vector-ref v 3)) (uy (vector-ref v 4)) (uz (vector-ref v 5))
           (fx (vector-ref v 6)) (fy (vector-ref v 7)) (fz (vector-ref v 8))
           (ex (vector-ref v 9)) (ey (vector-ref v 10)) (ez (vector-ref v 11))
           (f ($focal cam))
           (kx (fl* (fl* (fl/ f ($aspect w h)) 0.5) (fixnum->flonum w)))
           (ky (fl* (fl* f 0.5) (fixnum->flonum h)))
           (hw (fl* 0.5 (fixnum->flonum w)))
           (hh (fl* 0.5 (fixnum->flonum h)))
           (near (rcam-near cam)))
      (let loop ((i 0))
        (when (< i n)
          (let* ((dx (fl- (get i 0) ex))
                 (dy (fl- (get i 1) ey))
                 (dz (fl- (get i 2) ez))
                 (zv (fl+ (fl+ (fl* dx fx) (fl* dy fy)) (fl* dz fz))))
            (if (fl<? near zv)
                (let ((xv (fl+ (fl+ (fl* dx rx) (fl* dy ry)) (fl* dz rz)))
                      (yv (fl+ (fl+ (fl* dx ux) (fl* dy uy)) (fl* dz uz))))
                  ($proj-set! base i
                              (fl+ hw (fl/ (fl* kx xv) zv))
                              (fl- hh (fl/ (fl* ky yv) zv))
                              zv))
                ($proj-set! base i 0.0 0.0 0.0)))
          (loop (+ i 1))))
      base))

  ;; ---------------------------------------------------------------
  ;; the footprint rule -- the one place it is written
  ;;
  ;; Spans are half-open [x0, x1) per scanline, written into `spans`
  ;; as (row, x0, x1) triples; the return value is how many were
  ;; written.  Rows outside [jlo, jhi) are visited but not emitted:
  ;; they still decide whether the triangle covered any pixel centre
  ;; at all, and the centroid fallback hangs on exactly that.  The
  ;; fallback cell itself is emitted wherever it lands, row window or
  ;; not, and the caller range-checks every span it is handed --
  ;; which is what makes clipping the caller's policy rather than a
  ;; convention buried in here.

  (define (tri-spans-capacity jlo jhi) (* 3 (+ (- jhi jlo) 1)))

  (define (tri-spans! ax ay bx by cx cy jlo jhi spans)
    (let* ((ymin ($min ay ($min by cy)))
           (ymax ($max ay ($max by cy)))
           (j0 ($irow ($ceil (fl- ymin 0.5))))
           (j1 ($irow (flfloor (fl- ymax 0.5)))))
      (let loop ((j j0) (n 0) (any? #f))
        (if (> j j1)
            (if any?
                n
                ;; no pixel centre anywhere: the single cell holding
                ;; the centroid, so a sliver never vanishes entirely
                (let ((gx (fl/ (fl+ (fl+ ax bx) cx) 3.0))
                      (gy (fl/ (fl+ (fl+ ay by) cy) 3.0)))
                  (vector-set! spans 0 ($ifloor gy))
                  (vector-set! spans 1 ($ifloor gx))
                  (vector-set! spans 2 (+ ($ifloor gx) 1))
                  1))
            (let ((yc (fl+ (fixnum->flonum j) 0.5)))
              (let edges ((e 0) (lo 0.0) (hi 0.0) (hit? #f))
                (if (< e 3)
                    (let* ((px (if (= e 0) ax (if (= e 1) bx cx)))
                           (py (if (= e 0) ay (if (= e 1) by cy)))
                           (qx (if (= e 0) bx (if (= e 1) cx ax)))
                           (qy (if (= e 0) by (if (= e 1) cy ay))))
                      ;; the half-open rule: the edge counts on this
                      ;; scanline when yc lies in [py, qy) or [qy, py),
                      ;; so a shared vertex is claimed by exactly one
                      ;; of the two edges meeting there
                      (if (or (and (not (fl<? yc py)) (fl<? yc qy))
                              (and (not (fl<? yc qy)) (fl<? yc py)))
                          (let ((x (fl+ px (fl/ (fl* (fl- qx px)
                                                     (fl- yc py))
                                                (fl- qy py)))))
                            (edges (+ e 1)
                                   (if hit? ($min lo x) x)
                                   (if hit? ($max hi x) x)
                                   #t))
                          (edges (+ e 1) lo hi hit?)))
                    (if (not hit?)
                        (loop (+ j 1) n any?)
                        (let ((i0f ($ceil (fl- lo 0.5)))
                              (i1f (flfloor (fl- hi 0.5))))
                          (if (fl<? i1f i0f)
                              (loop (+ j 1) n any?)
                              (if (and (<= jlo j) (< j jhi))
                                  (let ((i0 ($ifloor i0f))
                                        (i1 ($ifloor i1f))
                                        (o (* n 3)))
                                    (vector-set! spans o j)
                                    (vector-set! spans (+ o 1) i0)
                                    (vector-set! spans (+ o 2) (+ i1 1))
                                    (loop (+ j 1) (+ n 1) #t))
                                  (loop (+ j 1) n #t))))))))))))

  ;; ---------------------------------------------------------------
  ;; near-plane clipping
  ;;
  ;; -> the clipped polygon triangulated as a fan, each vertex being
  ;; (sx, sy, depth, w0, w1, w2) -- six flonums in `poly`.  The w* are
  ;; that vertex's barycentric weights with respect to the **original**
  ;; triangle, so interpolation after clipping still uses the original
  ;; three vertices' attributes and needs no second set of its own.
  ;; That is exactly why the clipped and the unclipped path can share
  ;; one interpolator.  Returns the number of output vertices (0, or
  ;; 3 or 4 forming a fan).

  (define ($clip-near! mesh cam ia ib ic w h poly tmp)
    (let* ((pos (rmesh-positions mesh))
           (get ($rattr-get pos))
           (v (rcam-view cam))
           (near (rcam-near cam)))
      ;; the three corners in view space, with their own barycentrics
      (let load ((k 0))
        (when (< k 3)
          (let* ((vi (if (= k 0) ia (if (= k 1) ib ic)))
                 (dx (fl- (get vi 0) (vector-ref v 9)))
                 (dy (fl- (get vi 1) (vector-ref v 10)))
                 (dz (fl- (get vi 2) (vector-ref v 11)))
                 (o (* k 6)))
            (vector-set! tmp o
              (fl+ (fl+ (fl* dx (vector-ref v 0)) (fl* dy (vector-ref v 1)))
                   (fl* dz (vector-ref v 2))))
            (vector-set! tmp (+ o 1)
              (fl+ (fl+ (fl* dx (vector-ref v 3)) (fl* dy (vector-ref v 4)))
                   (fl* dz (vector-ref v 5))))
            (vector-set! tmp (+ o 2)
              (fl+ (fl+ (fl* dx (vector-ref v 6)) (fl* dy (vector-ref v 7)))
                   (fl* dz (vector-ref v 8))))
            (vector-set! tmp (+ o 3) (if (= k 0) 1.0 0.0))
            (vector-set! tmp (+ o 4) (if (= k 1) 1.0 0.0))
            (vector-set! tmp (+ o 5) (if (= k 2) 1.0 0.0)))
          (load (+ k 1))))
      ;; Sutherland-Hodgman against the single plane z = near
      (let cut ((i 0) (m 0))
        (if (= i 3)
            (if (< m 3)
                0
                ;; view space -> screen, the projection the vertex
                ;; pass uses, so a clipped triangle and an unclipped
                ;; one land on the same arithmetic
                (let* ((f ($focal cam))
                       (kx (fl* (fl* (fl/ f ($aspect w h)) 0.5)
                                (fixnum->flonum w)))
                       (ky (fl* (fl* f 0.5) (fixnum->flonum h)))
                       (hw (fl* 0.5 (fixnum->flonum w)))
                       (hh (fl* 0.5 (fixnum->flonum h))))
                  (let scr ((k 0))
                    (when (< k m)
                      (let* ((o (* k 6))
                             (x (vector-ref poly o))
                             (y (vector-ref poly (+ o 1)))
                             (z (vector-ref poly (+ o 2))))
                        (vector-set! poly o (fl+ hw (fl/ (fl* kx x) z)))
                        (vector-set! poly (+ o 1)
                                     (fl- hh (fl/ (fl* ky y) z))))
                      (scr (+ k 1))))
                  m))
            (let* ((oa (* i 6))
                   (ob (* (if (= i 2) 0 (+ i 1)) 6))
                   (az (vector-ref tmp (+ oa 2)))
                   (bz (vector-ref tmp (+ ob 2)))
                   (ain (fl<? near az))
                   (bin (fl<? near bz))
                   (m1 (if ain
                           (let ((d (* m 6)))
                             (let cp ((k 0))
                               (when (< k 6)
                                 (vector-set! poly (+ d k)
                                              (vector-ref tmp (+ oa k)))
                                 (cp (+ k 1))))
                             (+ m 1))
                           m)))
              (if (eq? ain bin)
                  (cut (+ i 1) m1)
                  (let ((t (fl/ (fl- near az) (fl- bz az)))
                        (d (* m1 6)))
                    (let cp ((k 0))
                      (when (< k 6)
                        (let ((p (vector-ref tmp (+ oa k)))
                              (q (vector-ref tmp (+ ob k))))
                          (vector-set! poly (+ d k)
                                       (fl+ p (fl* (fl- q p) t))))
                        (cp (+ k 1))))
                    (vector-set! poly (+ d 2) near)
                    (cut (+ i 1) (+ m1 1)))))))))

  ;; ---------------------------------------------------------------
  ;; masks

  (define-record-type ($rmask $make-rmask rmask?)
    (fields (immutable base rmask-base)
            (immutable w rmask-width)
            (immutable h rmask-height)))

  (define (rmask-bytes w h) (* w h))
  (define (make-rmask w h base) ($make-rmask base w h))

  (define (rmask-clear! m)
    (let ((b (rmask-base m)) (n (* (rmask-width m) (rmask-height m))))
      (let loop ((i 0))
        (when (< i n) (%mem-u8-set! (+ b i) 0) (loop (+ i 1))))))

  (define (rmask-ref m x y)
    (%mem-u8-ref (+ (rmask-base m) (* y (rmask-width m)) x)))

  (define (rmask-set! m x y v)
    (%mem-u8-set! (+ (rmask-base m) (* y (rmask-width m)) x) v))

  (define (rmask-count m)
    (let ((b (rmask-base m)) (n (* (rmask-width m) (rmask-height m))))
      (let loop ((i 0) (s 0))
        (if (= i n) s
            (loop (+ i 1) (if (= 0 (%mem-u8-ref (+ b i))) s (+ s 1)))))))

  ;; Silhouette only: the union of every triangle's footprint, which
  ;; is independent of z ordering, so there is no depth buffer and no
  ;; barycentric here at all.
  (define (render-mask! mask mesh cam scratch)
    (let* ((w (rmask-width mask))
           (h (rmask-height mask))
           (mb (rmask-base mask))
           (nt (rmesh-tri-count mesh))
           (idx (rmesh-indices mesh))
           (iget ($ridx-get idx))
           (spans (make-vector (tri-spans-capacity 0 h) 0))
           (poly (make-vector 24 0.0))
           (tmp (make-vector 18 0.0)))
      (rmask-clear! mask)
      (project-vertices! mesh cam w h scratch)
      (let tri ((t 0))
        (when (< t nt)
          (let* ((ia (iget (* t 3)))
                 (ib (iget (+ (* t 3) 1)))
                 (ic (iget (+ (* t 3) 2)))
                 (da (proj-depth scratch ia))
                 (db (proj-depth scratch ib))
                 (dc (proj-depth scratch ic))
                 (za (fl=? da 0.0))
                 (zb (fl=? db 0.0))
                 (zc (fl=? dc 0.0)))
            (cond
             ((and za zb zc) #f)          ; the whole triangle is behind
             ((or za zb zc)
              (let ((m ($clip-near! mesh cam ia ib ic w h poly tmp)))
                (let fan ((k 1))
                  (when (< k (- m 1))
                    ($mask-tri! mb w h
                                (vector-ref poly 0) (vector-ref poly 1)
                                (vector-ref poly (* k 6))
                                (vector-ref poly (+ (* k 6) 1))
                                (vector-ref poly (* (+ k 1) 6))
                                (vector-ref poly (+ (* (+ k 1) 6) 1))
                                spans)
                    (fan (+ k 1))))))
             (else
              ($mask-tri! mb w h
                          (proj-x scratch ia) (proj-y scratch ia)
                          (proj-x scratch ib) (proj-y scratch ib)
                          (proj-x scratch ic) (proj-y scratch ic)
                          spans))))
          (tri (+ t 1))))
      (rmask-count mask)))

  (define ($mask-tri! mb w h x0 y0 x1 y1 x2 y2 spans)
    (let ((n (tri-spans! x0 y0 x1 y1 x2 y2 0 h spans)))
      (let loop ((s 0))
        (when (< s n)
          (let* ((o (* s 3))
                 (j (vector-ref spans o))
                 (a (vector-ref spans (+ o 1)))
                 (b (vector-ref spans (+ o 2))))
            (when (and (<= 0 j) (< j h))
              (let ((a2 (if (< a 0) 0 a)) (b2 (if (> b w) w b)))
                (when (< a2 b2)
                  (let ((row (+ mb (* j w))))
                    (let fill ((x a2))
                      (when (< x b2)
                        (%mem-u8-set! (+ row x) 1)
                        (fill (+ x 1)))))))))
          (loop (+ s 1))))))

  ;; Intersection over union of two masks.  The measure of fit lives
  ;; in this one procedure and nowhere else may compute it a second
  ;; time; two empty masks are a perfect match, by definition.
  (define (mask-iou a b)
    (unless (and (= (rmask-width a) (rmask-width b))
                 (= (rmask-height a) (rmask-height b)))
      (error 'mask-iou "mask sizes differ"))
    (let ((pa (rmask-base a)) (pb (rmask-base b))
          (n (* (rmask-width a) (rmask-height a))))
      (let loop ((i 0) (inter 0) (union 0))
        (if (= i n)
            (if (= union 0) 1.0 (fl/ (fixnum->flonum inter)
                                     (fixnum->flonum union)))
            (let ((x (if (= 0 (%mem-u8-ref (+ pa i))) 0 1))
                  (y (if (= 0 (%mem-u8-ref (+ pb i))) 0 1)))
              (loop (+ i 1)
                    (+ inter (if (= 1 (* x y)) 1 0))
                    (+ union (if (= 0 (+ x y)) 0 1))))))))

  ;; ---------------------------------------------------------------
  ;; the visibility buffer
  ;;
  ;; Per pixel: 1/depth (larger is nearer, and the depth test compares
  ;; this one number), three perspective-correct barycentrics, and the
  ;; triangle id (-1 = empty).  The four f64 planes come first so
  ;; every eight-byte store is aligned.

  (define-record-type ($rframe $make-rframe rframe?)
    (fields (immutable base rframe-base)
            (immutable w rframe-width)
            (immutable h rframe-height)))

  (define (rframe-bytes w h) (* 36 (* w h)))
  (define (make-rframe w h base) ($make-rframe base w h))

  (define ($fr-n fr) (* (rframe-width fr) (rframe-height fr)))
  (define ($fr-invd fr i) (+ (rframe-base fr) (* i 8)))
  (define ($fr-b fr k i)
    (+ (rframe-base fr) (* ($fr-n fr) (* 8 (+ k 1))) (* i 8)))
  (define ($fr-tri fr i)
    (+ (rframe-base fr) (* 32 ($fr-n fr)) (* i 4)))

  (define (rframe-clear! fr)
    (let ((n ($fr-n fr)))
      (let loop ((i 0))
        (when (< i n)
          (%mem-f64-set! ($fr-invd fr i) 0.0)
          (%mem-f64-set! ($fr-b fr 0 i) 0.0)
          (%mem-f64-set! ($fr-b fr 1 i) 0.0)
          (%mem-f64-set! ($fr-b fr 2 i) 0.0)
          (%mem-i32-set! ($fr-tri fr i) -1)
          (loop (+ i 1))))))

  (define (frame-tri fr x y)
    (%mem-i32-ref ($fr-tri fr (+ (* y (rframe-width fr)) x))))

  (define (frame-invd fr x y)
    (%mem-f64-ref ($fr-invd fr (+ (* y (rframe-width fr)) x))))

  ;; -> the depth, or #f where nothing was rasterized.  A sentinel
  ;; "infinity" would have to be compared correctly by every caller;
  ;; #f cannot be mistaken for a distance.
  (define (frame-depth fr x y)
    (let ((v (frame-invd fr x y)))
      (and (fl<? 0.0 v) (fl/ 1.0 v))))

  (define (frame-bary! fr x y out)
    (let ((i (+ (* y (rframe-width fr)) x)))
      (and (<= 0 (%mem-i32-ref ($fr-tri fr i)))
           (begin
             (vector-set! out 0 (%mem-f64-ref ($fr-b fr 0 i)))
             (vector-set! out 1 (%mem-f64-ref ($fr-b fr 1 i)))
             (vector-set! out 2 (%mem-f64-ref ($fr-b fr 2 i)))
             #t))))

  ;; Interpolate any per-vertex attribute at a pixel, at whatever
  ;; width the attribute carries -- positions, normals, UVs and a
  ;; scalar all go through this one procedure.  out is filled with
  ;; ncomp values; #f means the pixel is empty.
  (define (frame-interp! fr mesh attr x y out)
    (let ((i (+ (* y (rframe-width fr)) x)))
      (let ((t (%mem-i32-ref ($fr-tri fr i))))
        (and (<= 0 t)
             (let ((a (rmesh-tri mesh t 0))
                   (b (rmesh-tri mesh t 1))
                   (c (rmesh-tri mesh t 2))
                   (w0 (%mem-f64-ref ($fr-b fr 0 i)))
                   (w1 (%mem-f64-ref ($fr-b fr 1 i)))
                   (w2 (%mem-f64-ref ($fr-b fr 2 i)))
                   (nc (rattr-ncomp attr))
                   (get ($rattr-get attr)))
               (let loop ((k 0))
                 (when (< k nc)
                   (vector-set! out k
                     (fl+ (fl+ (fl* (get a k) w0) (fl* (get b k) w1))
                          (fl* (get c k) w2)))
                   (loop (+ k 1))))
               #t)))))

  ;; The silhouette of a rendered frame.  It must equal render-mask!'s
  ;; answer byte for byte; that the two are computed by different code
  ;; is the point.
  (define (frame-mask! fr mask)
    (unless (and (= (rframe-width fr) (rmask-width mask))
                 (= (rframe-height fr) (rmask-height mask)))
      (error 'frame-mask! "frame and mask sizes differ"))
    (let ((n ($fr-n fr)) (mb (rmask-base mask)))
      (let loop ((i 0) (s 0))
        (if (= i n)
            s
            (let ((v (if (<= 0 (%mem-i32-ref ($fr-tri fr i))) 1 0)))
              (%mem-u8-set! (+ mb i) v)
              (loop (+ i 1) (+ s v)))))))

  ;; Is a world point visible in this frame?  `ti` is the triangle the
  ;; point is known to belong to (-1 when it belongs to none): landing
  ;; on one's own triangle counts as visible straight away, which is
  ;; what keeps a surface from shadowing itself out of its own bake.
  ;; `bias` is a relative depth tolerance.
  (define (frame-point-visible? fr cam ti px py pz bias)
    (let ((w (rframe-width fr))
          (h (rframe-height fr))
          (out (make-vector 3 0.0)))
      (and (rcam-project! cam px py pz w h out)
           (let ((sx (vector-ref out 0))
                 (sy (vector-ref out 1))
                 (d (vector-ref out 2)))
             (and (not (fl<? sx 0.0))
                  (not (fl<? sy 0.0))
                  (fl<? sx (fixnum->flonum w))
                  (fl<? sy (fixnum->flonum h))
                  (let* ((x (%fl->fx (flfloor sx)))
                         (y (%fl->fx (flfloor sy)))
                         (hit (frame-tri fr x y)))
                    (cond ((= hit ti) #t)
                          ((< hit 0) #f)
                          (else
                           (let ((z (frame-depth fr x y)))
                             (and z
                                  (not (fl<? (fl* z (fl+ 1.0 ($fl bias)))
                                             d))))))))))))

  ;; Full rasterization: scanlines, z-buffer, perspective-correct
  ;; barycentrics.
  (define (render-frame! fr mesh cam scratch)
    (let* ((w (rframe-width fr))
           (h (rframe-height fr))
           (nt (rmesh-tri-count mesh))
           (iget ($ridx-get (rmesh-indices mesh)))
           (spans (make-vector (tri-spans-capacity 0 h) 0))
           (poly (make-vector 24 0.0))
           (tmp (make-vector 18 0.0)))
      (rframe-clear! fr)
      (project-vertices! mesh cam w h scratch)
      (let tri ((t 0))
        (when (< t nt)
          (let* ((ia (iget (* t 3)))
                 (ib (iget (+ (* t 3) 1)))
                 (ic (iget (+ (* t 3) 2)))
                 (da (proj-depth scratch ia))
                 (db (proj-depth scratch ib))
                 (dc (proj-depth scratch ic))
                 (za (fl=? da 0.0))
                 (zb (fl=? db 0.0))
                 (zc (fl=? dc 0.0)))
            (cond
             ((and za zb zc) #f)
             ((or za zb zc)
              (let ((m ($clip-near! mesh cam ia ib ic w h poly tmp)))
                (let fan ((k 1))
                  (when (< k (- m 1))
                    ($frame-tri! fr w h t spans poly 0 (* k 6) (* (+ k 1) 6))
                    (fan (+ k 1))))))
             (else
              ;; the unclipped case is the same fan vertex shape with
              ;; the canonical barycentric basis
              (vector-set! poly 0 (proj-x scratch ia))
              (vector-set! poly 1 (proj-y scratch ia))
              (vector-set! poly 2 da)
              (vector-set! poly 3 1.0)
              (vector-set! poly 4 0.0)
              (vector-set! poly 5 0.0)
              (vector-set! poly 6 (proj-x scratch ib))
              (vector-set! poly 7 (proj-y scratch ib))
              (vector-set! poly 8 db)
              (vector-set! poly 9 0.0)
              (vector-set! poly 10 1.0)
              (vector-set! poly 11 0.0)
              (vector-set! poly 12 (proj-x scratch ic))
              (vector-set! poly 13 (proj-y scratch ic))
              (vector-set! poly 14 dc)
              (vector-set! poly 15 0.0)
              (vector-set! poly 16 0.0)
              (vector-set! poly 17 1.0)
              ($frame-tri! fr w h t spans poly 0 6 12))))
          (tri (+ t 1))))
      fr))

  (define ($frame-tri! fr w h t spans poly o0 o1 o2)
    (let* ((x0 (vector-ref poly o0)) (y0 (vector-ref poly (+ o0 1)))
           (z0 (vector-ref poly (+ o0 2)))
           (x1 (vector-ref poly o1)) (y1 (vector-ref poly (+ o1 1)))
           (z1 (vector-ref poly (+ o1 2)))
           (x2 (vector-ref poly o2)) (y2 (vector-ref poly (+ o2 1)))
           (z2 (vector-ref poly (+ o2 2)))
           (area (fl- (fl* (fl- x1 x0) (fl- y2 y0))
                      (fl* (fl- x2 x0) (fl- y1 y0))))
           (n (tri-spans! x0 y0 x1 y1 x2 y2 0 h spans)))
      (if (fl=? area 0.0)
          ;; Degenerate: tri-spans! has already fallen back to the
          ;; cell holding the centroid, so take the mean barycentrics.
          (let ((inv (fl/ (fl+ (fl+ (fl/ 1.0 z0) (fl/ 1.0 z1))
                               (fl/ 1.0 z2))
                          3.0))
                (b0 (fl/ (fl+ (fl+ (vector-ref poly (+ o0 3))
                                   (vector-ref poly (+ o1 3)))
                              (vector-ref poly (+ o2 3))) 3.0))
                (b1 (fl/ (fl+ (fl+ (vector-ref poly (+ o0 4))
                                   (vector-ref poly (+ o1 4)))
                              (vector-ref poly (+ o2 4))) 3.0))
                (b2 (fl/ (fl+ (fl+ (vector-ref poly (+ o0 5))
                                   (vector-ref poly (+ o1 5)))
                              (vector-ref poly (+ o2 5))) 3.0)))
            (let loop ((s 0))
              (when (< s n)
                (let* ((o (* s 3))
                       (j (vector-ref spans o))
                       (a (vector-ref spans (+ o 1)))
                       (b (vector-ref spans (+ o 2))))
                  (when (and (<= 0 j) (< j h))
                    (let ((a2 (if (< a 0) 0 a)) (b2x (if (> b w) w b)))
                      (let fill ((x a2))
                        (when (< x b2x)
                          (let ((i (+ (* j w) x)))
                            (when (fl<? (%mem-f64-ref ($fr-invd fr i)) inv)
                              (%mem-f64-set! ($fr-invd fr i) inv)
                              (%mem-i32-set! ($fr-tri fr i) t)
                              (%mem-f64-set! ($fr-b fr 0 i) b0)
                              (%mem-f64-set! ($fr-b fr 1 i) b1)
                              (%mem-f64-set! ($fr-b fr 2 i) b2)))
                          (fill (+ x 1)))))))
                (loop (+ s 1)))))
          (let ((iarea (fl/ 1.0 area))
                (iz0 (fl/ 1.0 z0)) (iz1 (fl/ 1.0 z1)) (iz2 (fl/ 1.0 z2))
                (wa0 (vector-ref poly (+ o0 3)))
                (wa1 (vector-ref poly (+ o0 4)))
                (wa2 (vector-ref poly (+ o0 5)))
                (wb0 (vector-ref poly (+ o1 3)))
                (wb1 (vector-ref poly (+ o1 4)))
                (wb2 (vector-ref poly (+ o1 5)))
                (wc0 (vector-ref poly (+ o2 3)))
                (wc1 (vector-ref poly (+ o2 4)))
                (wc2 (vector-ref poly (+ o2 5))))
            (let loop ((s 0))
              (when (< s n)
                (let* ((o (* s 3))
                       (j (vector-ref spans o))
                       (a (vector-ref spans (+ o 1)))
                       (b (vector-ref spans (+ o 2))))
                  (when (and (<= 0 j) (< j h))
                    (let ((a2 (if (< a 0) 0 a))
                          (b2x (if (> b w) w b))
                          (yc (fl+ (fixnum->flonum j) 0.5)))
                      (let fill ((x a2))
                        (when (< x b2x)
                          (let* ((xc (fl+ (fixnum->flonum x) 0.5))
                                 ;; Barycentrics by Cramer's rule on
                                 ;; P = v0 + l1*(v1-v0) + l2*(v2-v0):
                                 ;;   l1 = |dp d2| / |d1 d2|
                                 ;;   l2 = |d1 dp| / |d1 d2|
                                 ;; Reversing the order inside either
                                 ;; numerator yields -l1/-l2, and
                                 ;; l0 = 1-l1-l2 still sums to 1 with a
                                 ;; roughly correct depth; only
                                 ;; attribute interpolation **inside**
                                 ;; the triangle comes out wrong --
                                 ;; which neither the mask nor the
                                 ;; outline can reveal at all.
                                 (l1 (fl* (fl- (fl* (fl- xc x0) (fl- y2 y0))
                                               (fl* (fl- x2 x0) (fl- yc y0)))
                                          iarea))
                                 (l2 (fl* (fl- (fl* (fl- x1 x0) (fl- yc y0))
                                               (fl* (fl- xc x0) (fl- y1 y0)))
                                          iarea))
                                 (l0 (fl- (fl- 1.0 l1) l2))
                                 ;; A sliver containing no pixel centre
                                 ;; at all fell back to the cell holding
                                 ;; the centroid, and that cell lies
                                 ;; **outside** the triangle, so the
                                 ;; extrapolated barycentrics can be
                                 ;; arbitrarily large -- large enough to
                                 ;; drive 1/depth negative.  Fall back to
                                 ;; the centroid barycentrics: on a
                                 ;; sub-pixel triangle there is no better
                                 ;; answer for depth or attributes
                                 ;; anyway, and this is what makes the
                                 ;; two rendering paths' footprints agree
                                 ;; strictly.
                                 (out? (or (fl<? l0 -0.000000001)
                                           (fl<? l1 -0.000000001)
                                           (fl<? l2 -0.000000001)))
                                 (m0 (if out? 0.3333333333333333 l0))
                                 (m1 (if out? 0.3333333333333333 l1))
                                 (m2 (if out? 0.3333333333333333 l2))
                                 (inv (fl+ (fl+ (fl* m0 iz0) (fl* m1 iz1))
                                           (fl* m2 iz2)))
                                 (i (+ (* j w) x)))
                            (when (fl<? (%mem-f64-ref ($fr-invd fr i)) inv)
                              (let* ((g0 (fl/ (fl* m0 iz0) inv))
                                     (g1 (fl/ (fl* m1 iz1) inv))
                                     (g2 (fl- (fl- 1.0 g0) g1)))
                                (%mem-f64-set! ($fr-invd fr i) inv)
                                (%mem-i32-set! ($fr-tri fr i) t)
                                (%mem-f64-set! ($fr-b fr 0 i)
                                  (fl+ (fl+ (fl* wa0 g0) (fl* wb0 g1))
                                       (fl* wc0 g2)))
                                (%mem-f64-set! ($fr-b fr 1 i)
                                  (fl+ (fl+ (fl* wa1 g0) (fl* wb1 g1))
                                       (fl* wc1 g2)))
                                (%mem-f64-set! ($fr-b fr 2 i)
                                  (fl+ (fl+ (fl* wa2 g0) (fl* wb2 g1))
                                       (fl* wc2 g2))))))
                          (fill (+ x 1)))))))
                (loop (+ s 1))))))))

  )
