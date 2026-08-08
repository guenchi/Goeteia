;; expect: #t
;; (gfx raster) v2: texture sampling through the visibility buffer,
;; and the pixel <-> texel correspondence that lets a correction
;; measured on a picture travel back to the atlas it came from.
;;
;; The geometry is chosen so that every number below is exact.  One
;; triangle with screen corners (0,0), (16,0) and (0,16) covers an
;; 8x8 frame entirely, and carrying UVs (0,0), (2,0), (0,2) it maps
;; pixel centre (i+.5, j+.5) to u = (2i+1)/16, v = (2j+1)/16 -- both
;; representable, both far from any texel boundary, so a sample that
;; lands one ulp out still lands in the same cell.  The expected
;; pixels are the ones a separate Python reference implementation
;; produces, cross-checked by hand in exact quarters (see the
;; bilinear derivation below the table).

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

;; ======================================================= the atlas
;;
;; A 4x4 texture whose four channels vary differently: R with the
;; column only, G with the row only, B and A with both and with
;; opposite signs.  R and G alone would catch a u/v swap; B and A
;; catch one that a channel-symmetric fixture would hide.
;;
;; The coefficients are not arbitrary.  A bilinear sample here is a
;; sum of the four texels in sixteenths, quantized by int(x + 0.5),
;; so a sample landing on N/16 with N = 8 (mod 16) sits exactly on a
;; rounding boundary -- and the interpolated (u, v) that reaches it
;; carries about 1e-12 of projection noise, because 1/tan(45 deg) is
;; not 1.0 to the last bit.  On such a pixel the expected byte would
;; be decided by that noise.  With R, G and A stepping by multiples
;; of four the sums land on whole numbers, and with B stepping by 17
;; and 52 they land on quarters; nothing in the frame comes closer
;; than 0.25 to a boundary, which is nine orders of magnitude of
;; margin.  A fixture whose literals are hostage to the last ulp
;; tests the ulp, not the sampler.

(define (tex-r x y) (+ 12 (* 60 x)))
(define (tex-g x y) (+ 8 (* 72 y)))
(define (tex-b x y) (+ 20 (* 17 x) (* 52 y)))
(define (tex-a x y) (- 250 (* 21 x) (* 40 y)))

(define tex (make-rimg 4 4 (alloc! (rimg-bytes 4 4))))

(define atlas-filled
  (let loop ((i 0))
    (if (= i 16)
        #t
        (let ((x (remainder i 4)) (y (quotient i 4)))
          (rimg-set! tex x y (tex-r x y) (tex-g x y)
                     (tex-b x y) (tex-a x y))
          (loop (+ i 1))))))

(define (tex-chan x y k)
  (if (= k 0) (tex-r x y)
      (if (= k 1) (tex-g x y)
          (if (= k 2) (tex-b x y) (tex-a x y)))))

(define container-ok
  (and atlas-filled
       (= (rimg-bytes 4 4) 64)
       (= (rimg-width tex) 4)
       (= (rimg-height tex) 4)
       (rimg? tex)
       (= (rimg-ref tex 0 0 0) 12)
       (= (rimg-ref tex 3 0 0) 192)
       (= (rimg-ref tex 0 3 1) 224)
       (= (rimg-ref tex 3 3 2) 227)
       (= (rimg-ref tex 3 3 3) 67)
       ;; clearing writes all four channels, and only this raster
       (let ((scratch (make-rimg 2 2 (alloc! (rimg-bytes 2 2)))))
         (rimg-clear! scratch 7 8 9 10)
         (and (= (rimg-ref scratch 0 0 0) 7)
              (= (rimg-ref scratch 1 1 3) 10)
              (= (rimg-ref tex 0 0 0) 12)))))

;; ================================== 1. the sampling rule, directly
;;
;; (u, v) reach a sampler with v measured **upwards** from the bottom
;; edge, so row 0 is v = 1.  Coordinates outside [0,1] repeat, and
;; the nearest rule truncates towards zero rather than flooring: u in
;; (-0.25, 0) and u in [0, 0.25) both name column 0 on a 4-wide
;; atlas, while u = -0.25 exactly names column 3.  That asymmetry is
;; the rule as the reference states it; flooring instead would shift
;; every negative-u sample by a column.

(define tc (make-vector 2 0))

(define (texel-at u v)
  (rimg-texel! tex u v tc)
  (list (vector-ref tc 0) (vector-ref tc 1)))

(define texel-rule-ok
  (and (equal? (texel-at 0.0 1.0) '(0 0))     ; v=1 is row 0
       (equal? (texel-at 0.0 0.125) '(0 3))   ; the bottom row
       ;; v=0 is the bottom **edge**, one row past the last, and the
       ;; repeat brings it back to row 0 -- not clamped to row 3
       (equal? (texel-at 0.0 0.0) '(0 0))
       (equal? (texel-at 0.0 0.3) '(0 2))
       (equal? (texel-at 0.99 1.0) '(3 0))
       (equal? (texel-at 0.25 0.75) '(1 1))
       (equal? (texel-at 0.75 0.25) '(3 3))
       ;; repeat: one turn either way names the same texel
       (equal? (texel-at 1.25 1.0) '(1 0))
       (equal? (texel-at -0.25 1.0) '(3 0))
       (equal? (texel-at 2.5 1.0) '(2 0))
       ;; truncation, not flooring: -0.1*4 = -0.4 truncates to 0
       (equal? (texel-at -0.1 1.0) '(0 0))
       (equal? (texel-at -0.3 1.0) '(3 0))
       ;; and the same rule on the v axis
       (equal? (texel-at 0.0 1.1) '(0 0))
       (equal? (texel-at 0.0 1.3) '(0 3))))

(define sample4 (make-vector 4 0.0))

(define (nearest-at u v)
  (rimg-nearest! tex u v sample4)
  (list (vector-ref sample4 0) (vector-ref sample4 1)
        (vector-ref sample4 2) (vector-ref sample4 3)))

;; fetching goes through the same rule the query answers with, so
;; these two can never drift apart
(define nearest-ok
  (let loop ((k 0) (ok #t))
    (if (= k 12)
        ok
        (let* ((u (fl- (fl* (fixnum->flonum k) 0.17) 0.6))
               (v (fl- 1.4 (fl* (fixnum->flonum k) 0.21)))
               (t (texel-at u v))
               (x (car t))
               (y (cadr t)))
          (loop (+ k 1)
                (and ok (equal? (nearest-at u v)
                                (list (rimg-ref tex x y 0)
                                      (rimg-ref tex x y 1)
                                      (rimg-ref tex x y 2)
                                      (rimg-ref tex x y 3)))))))))

;; The bilinear cell at u = 1/16, v = 1 - 1/16 -- the centre of pixel
;; (0,0) in the render below.  Both continuous coordinates come to
;; 4/16 - 1/2 = -1/4, so on each axis the cell is texels 3 and 0 with
;; the fraction 3/4 towards 0, and the four weights are 1/16, 3/16,
;; 3/16 and 9/16.  Working the red channel by hand:
;;
;;   a = R(3,3)*1/4 + R(0,3)*3/4 = 192/4 + 36/4 = 57
;;   b = R(3,0)*1/4 + R(0,0)*3/4 = 192/4 + 36/4 = 57
;;   r = a*1/4 + b*3/4                          = 57
;;
;; and blue, which varies on both axes:
;;
;;   a = B(3,3)/4 + B(0,3)*3/4 = 227/4 + 528/4 = 188.75
;;   b = B(3,0)/4 + B(0,0)*3/4 = 71/4  + 60/4  = 32.75
;;   r = 188.75/4 + 98.25      = 47.1875 + 24.5625 = 71.75
;;
;; Green comes to 62 and alpha to 204.25 the same way.
(define bilinear-ok
  (begin
    (rimg-bilinear! tex 0.0625 0.9375 sample4)
    (and (fl=? (vector-ref sample4 0) 57.0)
         (fl=? (vector-ref sample4 1) 62.0)
         (fl=? (vector-ref sample4 2) 71.75)
         (fl=? (vector-ref sample4 3) 204.25)
         ;; dead centre of a texel: the cell degenerates and the
         ;; answer is that texel exactly, on every channel
         (begin
           (rimg-bilinear! tex 0.375 0.625 sample4)
           (and (fl=? (vector-ref sample4 0) (fixnum->flonum (tex-r 1 1)))
                (fl=? (vector-ref sample4 1) (fixnum->flonum (tex-g 1 1)))
                (fl=? (vector-ref sample4 2) (fixnum->flonum (tex-b 1 1)))
                (fl=? (vector-ref sample4 3)
                      (fixnum->flonum (tex-a 1 1)))))
         ;; and one turn around wraps onto the same numbers
         (begin
           (rimg-bilinear! tex 1.0625 0.9375 sample4)
           (and (fl=? (vector-ref sample4 0) 57.0)
                (fl=? (vector-ref sample4 3) 204.25))))))

;; ==================================================== 2. the scene
;;
;; sx = 4 + X/2 and sy = 4 - Y/2 at depth 8 (az=el=roll=0, dist=8,
;; fov=90 on an 8x8 frame), so the three world positions below land
;; on the screen points (0,0), (16,0) and (0,16).  Every pixel centre
;; of the frame satisfies xc + yc < 16, so the triangle covers all 64.

(define big-pos
  (rattr-vector (vector -8.0 8.0 0.0  24.0 8.0 0.0  -8.0 -24.0 0.0) 3))
(define big (make-rmesh big-pos (ridx-range 3)))
(define cam (make-rcam 0.0 0.0 8.0 0.0 90.0 0.0 0.0 0.0 0.0 0.0 0.1 #f))

;; u = 2*l1 and v = 2*l2 with l1 = sx/16 and l2 = sy/16, so at pixel
;; centres u = (2i+1)/16 and v = (2j+1)/16 -- glTF's convention, with
;; the v origin at the **top**.
(define uv-unit (rattr-vector (vector 0.0 0.0  2.0 0.0  0.0 2.0) 2))
;; the same map shifted half an atlas out of range on both axes, so
;; every sample has to be brought back by the wrap
(define uv-wrap
  (rattr-vector (vector -0.5 -0.5  1.5 -0.5  -0.5 1.5) 2))

(define fr (make-rframe 8 8 (alloc! (rframe-bytes 8 8))))
(define dst (make-rimg 8 8 (alloc! (rimg-bytes 8 8))))
(define scratch (alloc! (raster-scratch-bytes 3)))

(define scene-ok
  (begin
    (render-frame! fr big cam scratch)
    (and (near? (proj-x scratch 0) 0.0 0.000000001)
         (near? (proj-y scratch 0) 0.0 0.000000001)
         (near? (proj-x scratch 1) 16.0 0.000000001)
         (near? (proj-y scratch 1) 0.0 0.000000001)
         (near? (proj-x scratch 2) 0.0 0.000000001)
         (near? (proj-y scratch 2) 16.0 0.000000001)
         (near? (proj-depth scratch 0) 8.0 0.000000001)
         ;; the whole frame is covered, so nothing below is measuring
         ;; the background by accident
         (let loop ((i 0))
           (or (= i 64)
               (and (= 0 (frame-tri fr (remainder i 8) (quotient i 8)))
                    (loop (+ i 1))))))))

;; =========================== 3. nearest: an exact 2x block upscale
;;
;; u*4 = (2i+1)/2 truncates to i div 2, and the row likewise, so a
;; 4x4 atlas on an 8x8 frame is a doubling of the atlas and every
;; pixel is a texel verbatim -- no rounding step anywhere on this
;; path, which is why the nearest render is compared for equality and
;; not within a tolerance.

(define (render! uv mode)
  (render-textured! fr big cam uv tex mode dst scratch))

(define (pixel-is? x y r g b a)
  (and (= (rimg-ref dst x y 0) r) (= (rimg-ref dst x y 1) g)
       (= (rimg-ref dst x y 2) b) (= (rimg-ref dst x y 3) a)))

(define nearest-render-ok
  (let ((covered (render! uv-unit 'nearest)))
    (and (= covered 64)
         ;; four pixels written out in full, from the atlas formula
         (pixel-is? 0 0 12 8 20 250)
         (pixel-is? 2 0 72 8 37 229)
         (pixel-is? 0 2 12 80 72 210)
         (pixel-is? 7 7 192 224 227 67)
         ;; and the whole frame against the block rule
         (let loop ((i 0))
           (or (= i 64)
               (let* ((x (remainder i 8)) (y (quotient i 8))
                      (tx (quotient x 2)) (ty (quotient y 2)))
                 (and (pixel-is? x y (tex-r tx ty) (tex-g tx ty)
                                 (tex-b tx ty) (tex-a tx ty))
                      (loop (+ i 1)))))))))

;; ======================== 4. bilinear: the reference's whole frame
;;
;; 256 bytes as the Python reference implementation produces them,
;; row by row, four channels per pixel.  Pixel (0,0) is the cell
;; derived by hand above: 57, 62, 71.75, 204.25, quantized by
;; min(255, int(x + 0.5)) to 57, 62, 72, 204.  Held in a procedure
;; rather than at top level because constants are hoisted per emitted
;; function and the module's top level is one function.

(define (expect-bilinear-unit)
  (vector
   57 62 72 204    27 62 63 215    57 62 72 204    87 62 80 194
   117 62 89 183   147 62 97 173   177 62 106 162  147 62 97 173
   57 26 46 224    27 26 37 235    57 26 46 224    87 26 54 214
   117 26 63 203   147 26 71 193   177 26 80 182   147 26 71 193
   57 62 72 204    27 62 63 215    57 62 72 204    87 62 80 194
   117 62 89 183   147 62 97 173   177 62 106 162  147 62 97 173
   57 98 98 184    27 98 89 195    57 98 98 184    87 98 106 174
   117 98 115 163  147 98 123 153  177 98 132 142  147 98 123 153
   57 134 124 164  27 134 115 175  57 134 124 164  87 134 132 154
   117 134 141 143 147 134 149 133 177 134 158 122 147 134 149 133
   57 170 150 144  27 170 141 155  57 170 150 144  87 170 158 134
   117 170 167 123 147 170 175 113 177 170 184 102 147 170 175 113
   57 206 176 124  27 206 167 135  57 206 176 124  87 206 184 114
   117 206 193 103 147 206 201 93  177 206 210 82  147 206 201 93
   57 170 150 144  27 170 141 155  57 170 150 144  87 170 158 134
   117 170 167 123 147 170 175 113 177 170 184 102 147 170 175 113))

(define (frame-matches? want)
  (let loop ((i 0))
    (or (= i 64)
        (let ((x (remainder i 8)) (y (quotient i 8)))
          (and (pixel-is? x y
                          (vector-ref want (* i 4))
                          (vector-ref want (+ (* i 4) 1))
                          (vector-ref want (+ (* i 4) 2))
                          (vector-ref want (+ (* i 4) 3)))
               (loop (+ i 1)))))))

(define bilinear-render-ok
  (let ((covered (render! uv-unit 'bilinear)))
    (and (= covered 64)
         (frame-matches? (expect-bilinear-unit)))))

;; ====================================== 5. the wrap, on every pixel
;;
;; The same map shifted by half an atlas: u runs from -7/16 to 7/16
;; across the row, so the left half of the frame samples negative
;; coordinates.  The texel table below is where truncation and
;; flooring part company -- columns 2 and 3 sample u in (-0.25, 0)
;; and truncate to column 0, while columns 0 and 1 sample past -0.25
;; and land on column 3.  A clamp instead of a wrap would put columns
;; 0 and 1 on texel 0.

(define (expect-wrap-texels)
  (vector
   3 3  3 3  0 3  0 3  0 3  0 3  1 3  1 3
   3 3  3 3  0 3  0 3  0 3  0 3  1 3  1 3
   3 0  3 0  0 0  0 0  0 0  0 0  1 0  1 0
   3 0  3 0  0 0  0 0  0 0  0 0  1 0  1 0
   3 0  3 0  0 0  0 0  0 0  0 0  1 0  1 0
   3 0  3 0  0 0  0 0  0 0  0 0  1 0  1 0
   3 1  3 1  0 1  0 1  0 1  0 1  1 1  1 1
   3 1  3 1  0 1  0 1  0 1  0 1  1 1  1 1))

;; the reference's first row under the same shift, bilinear
(define (expect-wrap-bilinear-row0)
  (vector
   117 134 141 143  147 134 149 133  177 134 158 122  147 134 149 133
   57 134 124 164   27 134 115 175   57 134 124 164   87 134 132 154))

(define wrap-ok
  (let ((covered (render! uv-wrap 'nearest))
        (want (expect-wrap-texels)))
    (and (= covered 64)
         ;; the texel a pixel read is the one the table names ...
         (let loop ((i 0))
           (or (= i 64)
               (let* ((x (remainder i 8)) (y (quotient i 8))
                      (t (frame-texel fr big uv-wrap tex x y)))
                 (and t
                      (= (vector-ref t 0) (vector-ref want (* i 2)))
                      (= (vector-ref t 1) (vector-ref want (+ (* i 2) 1)))
                      (loop (+ i 1))))))
         ;; ... and the colour it got is that texel, verbatim
         (let loop ((i 0))
           (or (= i 64)
               (let* ((x (remainder i 8)) (y (quotient i 8))
                      (tx (vector-ref want (* i 2)))
                      (ty (vector-ref want (+ (* i 2) 1))))
                 (and (pixel-is? x y (tex-r tx ty) (tex-g tx ty)
                                 (tex-b tx ty) (tex-a tx ty))
                      (loop (+ i 1))))))
         ;; bilinear under the same shift, first row, from the
         ;; reference: the wrap has to hold across the cell too, not
         ;; only at its centre
         (let ((row (begin (render! uv-wrap 'bilinear)
                           (expect-wrap-bilinear-row0))))
           (let loop ((x 0))
             (or (= x 8)
                 (and (pixel-is? x 0
                                 (vector-ref row (* x 4))
                                 (vector-ref row (+ (* x 4) 1))
                                 (vector-ref row (+ (* x 4) 2))
                                 (vector-ref row (+ (* x 4) 3)))
                      (loop (+ x 1)))))))))

;; ================== 6. render and query agree, pixel by pixel
;;
;; The rendered colour must be the atlas read at the texel the query
;; names -- for every pixel, in nearest mode, on both UV layouts.
;; The two run through the same rule on purpose: if they ever
;; disagree, one of them stopped using it.

(define (render-query-agrees? uv)
  (render! uv 'nearest)
  (let loop ((i 0))
    (or (= i 64)
        (let* ((x (remainder i 8)) (y (quotient i 8))
               (t (frame-texel fr big uv tex x y)))
          (and t
               (let ((tx (vector-ref t 0)) (ty (vector-ref t 1)))
                 (and (= (rimg-ref dst x y 0) (rimg-ref tex tx ty 0))
                      (= (rimg-ref dst x y 1) (rimg-ref tex tx ty 1))
                      (= (rimg-ref dst x y 2) (rimg-ref tex tx ty 2))
                      (= (rimg-ref dst x y 3) (rimg-ref tex tx ty 3))
                      (loop (+ i 1)))))))))

(define query-ok
  (and (render-query-agrees? uv-unit)
       (render-query-agrees? uv-wrap)
       ;; frame-texel! fills a caller's vector and says whether it did
       (let ((out (make-vector 2 0)))
         (and (frame-texel! fr big uv-unit tex 5 3 out)
              (= (vector-ref out 0) 2)
              (= (vector-ref out 1) 1)))))

;; ============================== 7. background is transparent black
;;
;; A triangle covering a quarter of the frame: everything it misses
;; must be (0,0,0,0), and the query must answer #f there rather than
;; some texel of the atlas.  Alpha is what separates "no surface"
;; from "a black surface", and the loss below depends on it.

(define small-pos
  (rattr-vector (vector -8.0 8.0 0.0  0.0 8.0 0.0  -8.0 0.0 0.0) 3))
(define small (make-rmesh small-pos (ridx-range 3)))
(define small-uv (rattr-vector (vector 0.0 0.0  1.0 0.0  0.0 1.0) 2))
(define small-scratch (alloc! (raster-scratch-bytes 3)))

(define background-ok
  (let ((covered (render-textured! fr small cam small-uv tex 'nearest
                                   dst small-scratch)))
    (and (< 0 covered)
         (< covered 64)
         (let loop ((i 0) (bg 0))
           (if (= i 64)
               (= bg (- 64 covered))
               (let* ((x (remainder i 8)) (y (quotient i 8))
                      (empty? (< (frame-tri fr x y) 0)))
                 (if empty?
                     (and (pixel-is? x y 0 0 0 0)
                          (not (frame-texel fr small small-uv tex x y))
                          (loop (+ i 1) (+ bg 1)))
                     (and (frame-texel fr small small-uv tex x y)
                          ;; a covered pixel keeps the atlas' alpha,
                          ;; which on this atlas is never zero
                          (< 0 (rimg-ref dst x y 3))
                          (loop (+ i 1) bg)))))))))

;; ======================================= 8. the transpose: splat
;;
;; Under 'nearest each covered pixel contributes once, with weight 1,
;; to the very texel the query names -- the round trip.  Under
;; 'bilinear it contributes four times, and those four weights are
;; the sampler's own: they sum to one, and the weighted sum of the
;; four texels reproduces the sample to the last bit reachable in
;; quarters.

(define splat-state (make-vector 4 0))     ; calls, mismatches, ...
(define splat-acc (make-vector 4 0.0))     ; the four channels
(define splat-wsum (make-vector 1 0.0))

(define splat-nearest-ok
  (begin
    (render! uv-unit 'nearest)
    (vector-set! splat-state 0 0)
    (vector-set! splat-state 1 0)
    (let ((n (frame-splat! fr big uv-unit tex 'nearest #f
               (lambda (px py tx ty w)
                 (vector-set! splat-state 0 (+ 1 (vector-ref splat-state 0)))
                 (let ((t (frame-texel fr big uv-unit tex px py)))
                   (unless (and t (fl=? w 1.0)
                                (= tx (vector-ref t 0))
                                (= ty (vector-ref t 1))
                                (= (rimg-ref dst px py 0)
                                   (rimg-ref tex tx ty 0)))
                     (vector-set! splat-state 1
                                  (+ 1 (vector-ref splat-state 1)))))))))
      (and (= n 64)
           (= (vector-ref splat-state 0) 64)
           (= (vector-ref splat-state 1) 0)))))

;; one pixel's four contributions, summed back into a colour
(define (splat-pixel-ok? px py)
  (vector-set! splat-acc 0 0.0) (vector-set! splat-acc 1 0.0)
  (vector-set! splat-acc 2 0.0) (vector-set! splat-acc 3 0.0)
  (vector-set! splat-wsum 0 0.0)
  (vector-set! splat-state 2 0)
  (frame-splat! fr big uv-unit tex 'bilinear #f
    (lambda (x y tx ty w)
      (when (and (= x px) (= y py))
        (vector-set! splat-state 2 (+ 1 (vector-ref splat-state 2)))
        (vector-set! splat-wsum 0 (fl+ (vector-ref splat-wsum 0) w))
        (let loop ((k 0))
          (when (< k 4)
            (vector-set! splat-acc k
              (fl+ (vector-ref splat-acc k)
                   (fl* w (fixnum->flonum (rimg-ref tex tx ty k)))))
            (loop (+ k 1)))))))
  (rimg-bilinear! tex
                  ;; the same (u, v) the render used: pixel centres
                  ;; are (2i+1)/16 in glTF's frame, flipped once for
                  ;; the sampler
                  (fl/ (fl+ (fl* 2.0 (fixnum->flonum px)) 1.0) 16.0)
                  (fl- 1.0 (fl/ (fl+ (fl* 2.0 (fixnum->flonum py)) 1.0) 16.0))
                  sample4)
  (and (= (vector-ref splat-state 2) 4)
       (near? (vector-ref splat-wsum 0) 1.0 0.000000000001)
       (near? (vector-ref splat-acc 0) (vector-ref sample4 0) 0.000000001)
       (near? (vector-ref splat-acc 1) (vector-ref sample4 1) 0.000000001)
       (near? (vector-ref splat-acc 2) (vector-ref sample4 2) 0.000000001)
       (near? (vector-ref splat-acc 3) (vector-ref sample4 3) 0.000000001)))

;; The four contributions of pixel (1,0), written out.  u = 3/16 and
;; v = 1/16 there, so the column cell is (0,1) at 1/4 of the way over
;; while the row cell is (3,0) at 3/4 of the way down -- deliberately
;; *unequal* fractions, because tx = ty makes a weight table that has
;; been transposed indistinguishable from one that has not, and on
;; this fixture tx equals ty whenever the pixel's two indices share a
;; parity.  Emission order is (x0,y0), (x1,y0), (x0,y1), (x1,y1).
(define (expect-cell-1-0)
  (vector 0 3 0.1875   1 3 0.0625   0 0 0.5625   1 0 0.1875))

(define splat-cell (make-vector 12 0.0))
(define splat-cell-n (make-vector 1 0))

(define splat-cell-ok
  (begin
    (vector-set! splat-cell-n 0 0)
    (frame-splat! fr big uv-unit tex 'bilinear #f
      (lambda (x y tx ty w)
        (when (and (= x 1) (= y 0))
          (let ((k (vector-ref splat-cell-n 0)))
            (when (< k 4)
              (vector-set! splat-cell (* k 3) tx)
              (vector-set! splat-cell (+ (* k 3) 1) ty)
              (vector-set! splat-cell (+ (* k 3) 2) w))
            (vector-set! splat-cell-n 0 (+ k 1))))))
    (let ((want (expect-cell-1-0)))
      (and (= (vector-ref splat-cell-n 0) 4)
           (let loop ((k 0))
             (or (= k 4)
                 (and (= (vector-ref splat-cell (* k 3))
                         (vector-ref want (* k 3)))
                      (= (vector-ref splat-cell (+ (* k 3) 1))
                         (vector-ref want (+ (* k 3) 1)))
                      (near? (vector-ref splat-cell (+ (* k 3) 2))
                             (vector-ref want (+ (* k 3) 2))
                             0.000000000001)
                      (loop (+ k 1)))))))))

(define splat-bilinear-ok
  (begin
    (render! uv-unit 'bilinear)
    (and (= 256 (frame-splat! fr big uv-unit tex 'bilinear #f
                              (lambda (x y tx ty w) #t)))
         splat-cell-ok
         (splat-pixel-ok? 0 0)              ; the wrapping corner
         (splat-pixel-ok? 1 0)              ; tx /= ty
         (splat-pixel-ok? 2 5)              ; tx /= ty, the other way
         (splat-pixel-ok? 3 5)
         (splat-pixel-ok? 7 7))))

;; ---- the triangle filter, over a scene with two of them ----
;;
;; A second triangle 2 units nearer the camera hides part of the
;; first.  Splatting triangle by triangle must partition exactly the
;; pixels splatting the whole frame visits: no pixel counted twice,
;; none dropped, and none attributed to the triangle behind.

(define two-pos
  (rattr-vector (vector -8.0 8.0 0.0  24.0 8.0 0.0  -8.0 -24.0 0.0
                        -6.0 6.0 2.0  3.0 6.0 2.0  -6.0 -3.0 2.0) 3))
(define two (make-rmesh two-pos (ridx-vector (vector 0 1 2 3 4 5))))
(define two-uv
  (rattr-vector (vector 0.0 0.0  2.0 0.0  0.0 2.0
                        0.0 0.0  1.0 0.0  0.0 1.0) 2))
(define two-scratch (alloc! (raster-scratch-bytes 6)))

(define splat-filter-ok
  (begin
    (render-textured! fr two cam two-uv tex 'nearest dst two-scratch)
    (vector-set! splat-state 3 0)
    (let* ((count (lambda (t)
                    (frame-splat! fr two two-uv tex 'nearest t
                      (lambda (x y tx ty w)
                        (unless (or (not t) (= t (frame-tri fr x y)))
                          (vector-set! splat-state 3
                                       (+ 1 (vector-ref splat-state 3))))))))
           (all (count #f))
           (n0 (count 0))
           (n1 (count 1)))
      (and (= 0 (vector-ref splat-state 3))
           (= all 64)
           (< 0 n0) (< 0 n1)
           (= all (+ n0 n1))
           ;; and asking for a triangle that is not in the mesh
           ;; enumerates nothing rather than everything
           (= 0 (count 2))))))

;; ==================================================== 9. the loss
;;
;; |a - b| over four channels, summed inside a mask.  Alpha counts:
;; two frames that differ only in alpha are two different pictures --
;; one says "surface here", the other says "background here" -- and a
;; loss blind to that cannot tell a hole from a black patch.

(define la (make-rimg 2 2 (alloc! (rimg-bytes 2 2))))
(define lb (make-rimg 2 2 (alloc! (rimg-bytes 2 2))))
(define lmask (make-rmask 2 2 (alloc! (rmask-bytes 2 2))))
(define dout (make-vector 3 0))

(define (diff-of mask)
  (frame-diff la lb mask dout)
  (list (vector-ref dout 0) (vector-ref dout 1) (vector-ref dout 2)))

(define diff-ok
  (begin
    ;; a: (10,20,30,40) (0,0,0,0) (200,200,200,200) (1,2,3,4)
    (rimg-set! la 0 0 10 20 30 40)
    (rimg-set! la 1 0 0 0 0 0)
    (rimg-set! la 0 1 200 200 200 200)
    (rimg-set! la 1 1 1 2 3 4)
    ;; b differs by 1,2,3,4 in the first pixel; by 5 on one channel
    ;; in the second; not at all in the third; and in alpha only in
    ;; the fourth
    (rimg-set! lb 0 0 11 22 33 44)
    (rimg-set! lb 1 0 0 5 0 0)
    (rimg-set! lb 0 1 200 200 200 200)
    (rimg-set! lb 1 1 1 2 3 9)
    (and
     ;; 1+2+3+4 = 10, plus 5, plus 0, plus 5 = 20 over 4 pixels,
     ;; largest single channel 5
     (equal? (diff-of #f) (list 20.0 4 5))
     ;; the mask selects: only the first pixel
     (begin
       (rmask-clear! lmask)
       (rmask-set! lmask 0 0 1)
       (equal? (diff-of lmask) (list 10.0 1 4)))
     ;; a non-zero byte selects, not the value 1 only
     (begin
       (rmask-clear! lmask)
       (rmask-set! lmask 1 1 255)
       (equal? (diff-of lmask) (list 5.0 1 5)))
     ;; two frames differing in alpha alone are different frames
     (begin
       (rimg-clear! la 7 7 7 255)
       (rimg-clear! lb 7 7 7 0)
       (equal? (diff-of #f) (list 1020.0 4 255)))
     ;; identical frames are a zero loss, mask or no mask
     (begin
       (rimg-clear! lb 7 7 7 255)
       (equal? (diff-of #f) (list 0.0 4 0)))
     ;; an empty mask compares nothing and says so, rather than
     ;; reporting a perfect match over a population of zero
     (begin
       (rmask-clear! lmask)
       (equal? (diff-of lmask) (list 0.0 0 0))))))

;; and the loss over the real thing: the two sampling modes of the
;; same pose differ, and differ only where the atlas is not flat
(define render-loss-ok
  (let ((a (make-rimg 8 8 (alloc! (rimg-bytes 8 8))))
        (b (make-rimg 8 8 (alloc! (rimg-bytes 8 8))))
        (out (make-vector 3 0)))
    (render-textured! fr big cam uv-unit tex 'nearest a scratch)
    (render-textured! fr big cam uv-unit tex 'bilinear b scratch)
    (frame-diff a b #f out)
    (and (fl<? 0.0 (vector-ref out 0))
         (= (vector-ref out 1) 64)
         (< 0 (vector-ref out 2))
         ;; against itself, nothing
         (begin (frame-diff a a #f out)
                (and (fl=? (vector-ref out 0) 0.0)
                     (= (vector-ref out 2) 0))))))

;; ---------------------------------------------------------------
(define main-ok
  (and container-ok texel-rule-ok nearest-ok bilinear-ok
       scene-ok nearest-render-ok bilinear-render-ok wrap-ok
       query-ok background-ok
       splat-nearest-ok splat-bilinear-ok splat-filter-ok
       diff-ok render-loss-ok))

main-ok
