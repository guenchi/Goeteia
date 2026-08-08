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
;; does this triangle cover, and what is in front of what.  On top of
;; those sits one more pair, which closes the fitting loop rather than
;; opening a renderer: sample a texture through the visibility buffer
;; to get a picture, and say for any pixel which texel it read, so a
;; correction measured on the picture can travel back up to the atlas
;; it came from.  Image IO stays the caller's business -- (gfx image)
;; decodes a PNG into exactly the RGBA8 block this module samples.
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
          frame-interp! frame-mask! frame-point-visible?
          ;; RGBA8 rasters and the sampling rule
          make-rimg rimg? rimg-base rimg-width rimg-height
          rimg-bytes rimg-clear! rimg-ref rimg-set!
          rimg-texel! rimg-nearest! rimg-bilinear!
          ;; textured rendering, and the pixel <-> texel correspondence
          render-textured! shade-textured!
          frame-texel frame-texel! frame-splat!
          frame-diff)
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

  ;; ---------------------------------------------------------------
  ;; RGBA8 rasters
  ;;
  ;; One container for two roles: the texture a render samples, and
  ;; the colour frame a render writes.  They are the same object --
  ;; w*h texels of four bytes, row 0 at the base, exactly what
  ;; `png-decode!' leaves behind -- and giving them two record types
  ;; would only oblige callers to convert between them.  What differs
  ;; is the *sampling* rule, and that lives in the samplers below, not
  ;; in the container.

  (define-record-type ($rimg $make-rimg rimg?)
    (fields (immutable base rimg-base)
            (immutable w rimg-width)
            (immutable h rimg-height)))

  (define (rimg-bytes w h) (* 4 (* w h)))

  (define (make-rimg w h base)
    (when (or (< w 1) (< h 1))
      (error 'make-rimg "an RGBA8 raster needs a positive width and height"))
    ($make-rimg base w h))

  (define ($rimg-o img x y)
    (+ (rimg-base img) (* 4 (+ (* y (rimg-width img)) x))))

  ;; Raw indexing: channel k (0=R 1=G 2=B 3=A) of the texel at column
  ;; x, row y.  No wrap and no clamp -- like `tri-spans!', this one
  ;; neither knows nor decides what happens outside, so the same
  ;; container serves a sampler that repeats and a frame that does not.
  (define (rimg-ref img x y k) (%mem-u8-ref (+ ($rimg-o img x y) k)))

  (define (rimg-set! img x y r g b a)
    (let ((o ($rimg-o img x y)))
      (%mem-u8-set! o r)
      (%mem-u8-set! (+ o 1) g)
      (%mem-u8-set! (+ o 2) b)
      (%mem-u8-set! (+ o 3) a)))

  (define (rimg-clear! img r g b a)
    (let ((n (* (rimg-width img) (rimg-height img)))
          (base (rimg-base img)))
      (let loop ((i 0))
        (when (< i n)
          (let ((o (+ base (* 4 i))))
            (%mem-u8-set! o r)
            (%mem-u8-set! (+ o 1) g)
            (%mem-u8-set! (+ o 2) b)
            (%mem-u8-set! (+ o 3) a))
          (loop (+ i 1))))))

  ;; ---------------------------------------------------------------
  ;; the sampling rule -- the one place it is written
  ;;
  ;; Conventions, stated here and assumed nowhere else:
  ;;
  ;;   * (u, v) reach a sampler in the OpenGL sense: u to the right
  ;;     over [0,1] and v **upwards** from the bottom edge, so row 0
  ;;     of the raster is at v = 1.
  ;;   * Coordinates outside [0,1] REPEAT, which is glTF's default
  ;;     wrap.  The modulus is floored, so u = -0.25 and u = 0.75 name
  ;;     the same column.
  ;;   * glTF puts the UV origin at the **top** left, so a caller
  ;;     holding glTF texture coordinates samples at (u, 1-v).  The
  ;;     frame-level entry points below apply that flip themselves;
  ;;     nothing else in this module does.
  ;;
  ;; On that path 1-v is therefore taken twice -- once by the caller's
  ;; flip and once inside the sampler -- and the pair is deliberately
  ;; **not** cancelled.  1-(1-v) is not v to the last bit (v = 0.1
  ;; returns 0.09999999999999998), the reference implementation this
  ;; module is pinned to performs both subtractions, and cancelling
  ;; them would move a texel boundary by an ulp on every pixel whose
  ;; sample lands on one.  `$v-row' is that inner flip, named so the
  ;; rule reads as a rule and not as an accident.

  (define ($v-row v) (fl- 1.0 v))

  ;; The floored modulus: `remainder' takes the sign of the dividend,
  ;; and a texel column of -1 has to name the last column, not fail.
  (define ($wrap i n)
    (let ((r (remainder i n)))
      (if (< r 0) (+ r n) r)))

  ;; Truncation towards zero, pinned into the same safe window
  ;; `$ifloor' uses so `%fl->fx' cannot trap.  It is truncation and
  ;; not flooring on purpose: the reference reads the nearest texel as
  ;; int(u*W), so u in (-1/W, 0) and u in [0, 1/W) both land on column
  ;; 0.  That asymmetry is the rule as it stands, and a `floor' here
  ;; would shift every negative-u sample by one column.
  (define ($itrunc x)
    (%fl->fx (fltruncate ($max (fl- 0.0 $col-limit) ($min $col-limit x)))))

  ;; The nearest rule, one axis: `s' is the coordinate measured from
  ;; the raster's low edge (column 0 / row 0) and `n' that axis' size.
  (define ($near-i n s) ($wrap ($itrunc (fl* s (fixnum->flonum n))) n))

  ;; The bilinear cell, one axis.  Sampling reads it forwards and
  ;; splatting reads it backwards, so it is written once and both go
  ;; through it: `$bi-c' the continuous texel coordinate, `$bi-lo' and
  ;; `$bi-hi' the two texels it falls between, `$bi-t' the fraction.
  (define ($bi-c n s) (fl- (fl* s (fixnum->flonum n)) 0.5))
  (define ($bi-lo n c) ($wrap ($ifloor c) n))
  (define ($bi-hi n c) ($wrap (+ ($ifloor c) 1) n))
  (define ($bi-t c) (fl- c (flfloor c)))

  ;; -> out[0] = column, out[1] = row: the single texel a nearest
  ;; sample of (u, v) reads.  This is the query `frame-texel' answers
  ;; per pixel, and it is the same arithmetic `rimg-nearest!' fetches
  ;; through -- there is no second copy of it.
  (define (rimg-texel! img u v out)
    (vector-set! out 0 ($near-i (rimg-width img) u))
    (vector-set! out 1 ($near-i (rimg-height img) ($v-row v)))
    out)

  ;; -> out[0..3] = R G B A, exact bytes.
  (define (rimg-nearest! img u v out)
    (let ((o ($rimg-o img
                      ($near-i (rimg-width img) u)
                      ($near-i (rimg-height img) ($v-row v)))))
      (let loop ((k 0))
        (when (< k 4)
          (vector-set! out k (%mem-u8-ref (+ o k)))
          (loop (+ k 1))))
      out))

  ;; -> out[0..3] = R G B A as flonums, un-quantized: the caller
  ;; decides whether the answer becomes a byte, and if so by which
  ;; rounding.  All four channels go through the same arithmetic --
  ;; alpha is not a special case here, and a texture whose alpha
  ;; varies is resampled as faithfully as its colour.
  (define (rimg-bilinear! img u v out)
    (let* ((w (rimg-width img))
           (h (rimg-height img))
           (cx ($bi-c w u))
           (cy ($bi-c h ($v-row v)))
           (tx ($bi-t cx))
           (ty ($bi-t cy))
           (mx (fl- 1.0 tx))
           (my (fl- 1.0 ty))
           (x0 ($bi-lo w cx))
           (x1 ($bi-hi w cx))
           (y0 ($bi-lo h cy))
           (y1 ($bi-hi h cy))
           (o00 ($rimg-o img x0 y0))
           (o10 ($rimg-o img x1 y0))
           (o01 ($rimg-o img x0 y1))
           (o11 ($rimg-o img x1 y1)))
      (let loop ((k 0))
        (when (< k 4)
          (let ((a (fl+ (fl* (fixnum->flonum (%mem-u8-ref (+ o00 k))) mx)
                        (fl* (fixnum->flonum (%mem-u8-ref (+ o10 k))) tx)))
                (b (fl+ (fl* (fixnum->flonum (%mem-u8-ref (+ o01 k))) mx)
                        (fl* (fixnum->flonum (%mem-u8-ref (+ o11 k))) tx))))
            (vector-set! out k (fl+ (fl* a my) (fl* b ty))))
          (loop (+ k 1))))
      out))

  ;; A sampled channel back to a byte: the reference's min(255,
  ;; int(x + 0.5)).  Over the range a sample can actually take -- 0 to
  ;; 255, since samples and weights are both non-negative -- flooring
  ;; and truncating agree, so this is that expression and not a
  ;; near-miss of it.  The clamp before `%fl->fx' is not the rounding
  ;; policy but the trap guard: that primitive faults outside the
  ;; fixnum range, and a caller who reaches this with a value it never
  ;; should must still get a byte back rather than a crash.
  (define ($quant x)
    (let ((n (%fl->fx (flfloor (fl+ ($min 255.5 ($max 0.0 x)) 0.5)))))
      (if (> n 255) 255 n)))

  ;; 'nearest -> #t, 'bilinear -> #f, anything else -> an error, and
  ;; the error is raised once at the top of a render rather than once
  ;; per pixel.
  (define ($nearest-mode? who mode)
    (cond ((eq? mode 'nearest) #t)
          ((eq? mode 'bilinear) #f)
          (else
           (error who "sampling mode must be 'nearest or 'bilinear"))))

  ;; The glTF flip, at the one boundary where glTF's convention meets
  ;; the sampler's.  See the note above on why it is not fused with
  ;; `$v-row'.
  (define ($gltf-v v) (fl- 1.0 v))

  ;; ---------------------------------------------------------------
  ;; shading a visibility buffer with a texture
  ;;
  ;; This is the "render" half of a dense fitting loop: given a pose
  ;; already rasterized into `fr', an attribute carrying UVs and an
  ;; atlas, produce the picture that pose predicts.  It is layered on
  ;; `render-frame!' rather than fused into it -- the visibility
  ;; buffer knows nothing of colour, and a caller that wants two
  ;; different textures through one pose pays for the geometry once.
  ;;
  ;; Pixels no triangle covered are written (0, 0, 0, 0): transparent
  ;; black, so a background pixel is distinguishable from a black
  ;; surface by the alpha channel alone and `frame-diff' can see the
  ;; difference between "wrongly empty" and "wrongly dark".
  ;;
  ;; -> the number of pixels a triangle covered.

  (define (shade-textured! fr mesh uv tex mode dst)
    (unless (and (= (rframe-width fr) (rimg-width dst))
                 (= (rframe-height fr) (rimg-height dst)))
      (error 'shade-textured! "frame and destination sizes differ"))
    (when (< (rattr-ncomp uv) 2)
      (error 'shade-textured! "texture coordinates need two components"))
    (let* ((near? ($nearest-mode? 'shade-textured! mode))
           (w (rframe-width fr))
           (h (rframe-height fr))
           (db (rimg-base dst))
           (tw (rimg-width tex))
           (th (rimg-height tex))
           ;; one scratch vector for the whole render, at whatever
           ;; width the UV attribute declares -- an interleaved vertex
           ;; block is accepted here exactly as it is for positions
           (a (make-vector (rattr-ncomp uv) 0.0))
           (c (make-vector 4 0.0)))
      (let rows ((y 0) (covered 0))
        (if (= y h)
            covered
            (let cols ((x 0) (n covered))
              (if (= x w)
                  (rows (+ y 1) n)
                  (let ((o (+ db (* 4 (+ (* y w) x)))))
                    (if (not (frame-interp! fr mesh uv x y a))
                        (begin
                          (%mem-u8-set! o 0)
                          (%mem-u8-set! (+ o 1) 0)
                          (%mem-u8-set! (+ o 2) 0)
                          (%mem-u8-set! (+ o 3) 0)
                          (cols (+ x 1) n))
                        (let ((u (vector-ref a 0))
                              (v ($gltf-v (vector-ref a 1))))
                          (if near?
                              ;; the bytes are already bytes; going
                              ;; through a flonum and back would only
                              ;; invent a rounding step
                              (let ((s ($rimg-o tex ($near-i tw u)
                                                ($near-i th ($v-row v)))))
                                (%mem-u8-set! o (%mem-u8-ref s))
                                (%mem-u8-set! (+ o 1) (%mem-u8-ref (+ s 1)))
                                (%mem-u8-set! (+ o 2) (%mem-u8-ref (+ s 2)))
                                (%mem-u8-set! (+ o 3) (%mem-u8-ref (+ s 3))))
                              (begin
                                (rimg-bilinear! tex u v c)
                                (%mem-u8-set! o ($quant (vector-ref c 0)))
                                (%mem-u8-set! (+ o 1) ($quant (vector-ref c 1)))
                                (%mem-u8-set! (+ o 2) ($quant (vector-ref c 2)))
                                (%mem-u8-set! (+ o 3)
                                              ($quant (vector-ref c 3)))))
                          (cols (+ x 1) (+ n 1)))))))))))

  ;; Geometry and shading in one call, for the common case where the
  ;; visibility buffer is wanted only to be shaded.  It is literally
  ;; the two halves in sequence: `fr' is left holding the pose, so
  ;; every query below (`frame-texel', `frame-splat!',
  ;; `frame-point-visible?') still applies to the picture just made.
  (define (render-textured! fr mesh cam uv tex mode dst scratch)
    (render-frame! fr mesh cam scratch)
    (shade-textured! fr mesh uv tex mode dst))

  ;; ---------------------------------------------------------------
  ;; pixel -> texel
  ;;
  ;; Which texel did this pixel read?  -> #t with out[0] the texel
  ;; column and out[1] the texel row, or #f where the pixel is
  ;; background.  It runs through `frame-interp!' and the same
  ;; `$near-i' the sampler fetches through, so a nearest-mode render
  ;; and this query cannot disagree: the rendered pixel is by
  ;; construction `rimg-ref' of the texel this returns.
  ;;
  ;; Under 'bilinear a pixel has no single texel, and this answers the
  ;; nearest one -- the right answer for "where on the atlas am I",
  ;; and the wrong one for redistributing a correction, which is what
  ;; `frame-splat!' below is for.

  (define (frame-texel! fr mesh uv tex x y out)
    (when (< (rattr-ncomp uv) 2)
      (error 'frame-texel! "texture coordinates need two components"))
    (let ((a (make-vector (rattr-ncomp uv) 0.0)))
      (and (frame-interp! fr mesh uv x y a)
           (begin
             (rimg-texel! tex (vector-ref a 0)
                          ($gltf-v (vector-ref a 1)) out)
             #t))))

  (define (frame-texel fr mesh uv tex x y)
    (let ((out (make-vector 2 0)))
      (and (frame-texel! fr mesh uv tex x y out) out)))

  ;; ---------------------------------------------------------------
  ;; texel <- pixel: the transpose of sampling
  ;;
  ;; `proc' is called (proc px py tx ty w) once per (pixel, texel)
  ;; contribution, and the return value is how many times it was
  ;; called.  Under 'nearest that is once per covered pixel with
  ;; w = 1.0; under 'bilinear four times per covered pixel, with
  ;; exactly the four weights the sampler gave those four texels, so
  ;; they sum to one and sum(w * texel) reproduces the sample.
  ;; Spraying a per-pixel correction back onto the atlas is then
  ;; accumulating w*correction into texel (tx, ty), which is what
  ;; "project the photograph back onto the UVs" means.
  ;;
  ;; `tri' selects one triangle, or #f for every covered pixel.
  ;;
  ;; There is no index from texel to pixels, and deliberately none:
  ;; which pixels a texel reaches depends on the pose, so the only
  ;; honest answer is "enumerate this view and keep what matches" --
  ;; a caller after one texel filters on (tx, ty) inside `proc'.
  ;;
  ;; `tri' narrows what is *emitted*, not what is walked: the scan is
  ;; the whole frame either way, since a rendered frame carries no
  ;; per-triangle bounding box and inventing one would be a second
  ;; footprint rule beside `tri-spans!'.  What it saves is the
  ;; interpolation, the sampling and the callback, which is nearly all
  ;; of the cost; a caller splatting every triangle in turn should
  ;; pass #f once and dispatch on `frame-tri' itself.

  (define (frame-splat! fr mesh uv tex mode tri proc)
    (when (< (rattr-ncomp uv) 2)
      (error 'frame-splat! "texture coordinates need two components"))
    (let* ((near? ($nearest-mode? 'frame-splat! mode))
           (w (rframe-width fr))
           (h (rframe-height fr))
           (tw (rimg-width tex))
           (th (rimg-height tex))
           (a (make-vector (rattr-ncomp uv) 0.0)))
      (let rows ((y 0) (n 0))
        (if (= y h)
            n
            (let cols ((x 0) (n n))
              (if (= x w)
                  (rows (+ y 1) n)
                  (if (and tri (not (= tri (frame-tri fr x y))))
                      (cols (+ x 1) n)
                      (if (not (frame-interp! fr mesh uv x y a))
                          (cols (+ x 1) n)
                          ;; `s' is the row coordinate the sampler
                          ;; reaches after both flips, so splatting
                          ;; walks into exactly the cell sampling
                          ;; walked out of
                          (let ((u (vector-ref a 0))
                                (s ($v-row ($gltf-v (vector-ref a 1)))))
                            (if near?
                                (begin
                                  (proc x y ($near-i tw u) ($near-i th s) 1.0)
                                  (cols (+ x 1) (+ n 1)))
                                (let* ((cx ($bi-c tw u))
                                       (cy ($bi-c th s))
                                       (tu ($bi-t cx))
                                       (tv ($bi-t cy))
                                       (mu (fl- 1.0 tu))
                                       (mv (fl- 1.0 tv))
                                       (x0 ($bi-lo tw cx))
                                       (x1 ($bi-hi tw cx))
                                       (y0 ($bi-lo th cy))
                                       (y1 ($bi-hi th cy)))
                                  (proc x y x0 y0 (fl* mu mv))
                                  (proc x y x1 y0 (fl* tu mv))
                                  (proc x y x0 y1 (fl* mu tv))
                                  (proc x y x1 y1 (fl* tu tv))
                                  (cols (+ x 1) (+ n 4)))))))))))))

  ;; ---------------------------------------------------------------
  ;; the loss
  ;;
  ;; |a - b| over the pixels a mask admits, filled into out:
  ;;
  ;;   out[0]  the sum over all four channels, as a flonum
  ;;   out[1]  how many pixels were compared
  ;;   out[2]  the largest single-channel difference
  ;;
  ;; Alpha counts.  A render that put background where the photograph
  ;; has surface differs from one that put a black surface there, and
  ;; a difference summed over RGB alone cannot tell those apart --
  ;; both read (0,0,0).  `mask' is an `rmask' whose non-zero bytes
  ;; select, or #f for every pixel.
  ;;
  ;; The sum is a flonum rather than an exact integer: it is a whole
  ;; number below 2^53 for any raster that fits in memory, so nothing
  ;; is lost, and every consumer of a loss wants a flonum anyway.
  ;; The count and the maximum stay exact, because they are counts.

  (define (frame-diff a b mask out)
    (let ((w (rimg-width a)) (h (rimg-height a)))
      (unless (and (= w (rimg-width b)) (= h (rimg-height b)))
        (error 'frame-diff "frame sizes differ"))
      (when mask
        (unless (and (= w (rmask-width mask)) (= h (rmask-height mask)))
          (error 'frame-diff "frame and mask sizes differ")))
      (let ((pa (rimg-base a))
            (pb (rimg-base b))
            (mb (and mask (rmask-base mask)))
            (n (* w h)))
        (let loop ((i 0) (sum 0.0) (cnt 0) (mx 0))
          (if (= i n)
              (begin
                (vector-set! out 0 sum)
                (vector-set! out 1 cnt)
                (vector-set! out 2 mx)
                out)
              (if (and mb (= 0 (%mem-u8-ref (+ mb i))))
                  (loop (+ i 1) sum cnt mx)
                  (let ((o (* 4 i)))
                    (let chan ((k 0) (s sum) (m mx))
                      (if (= k 4)
                          (loop (+ i 1) s (+ cnt 1) m)
                          (let* ((p (%mem-u8-ref (+ pa o k)))
                                 (q (%mem-u8-ref (+ pb o k)))
                                 (d (if (< p q) (- q p) (- p q))))
                            (chan (+ k 1)
                                  (fl+ s (fixnum->flonum d))
                                  (if (> d m) d m))))))))))))

  )
