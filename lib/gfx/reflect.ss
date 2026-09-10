;; Copyright 2026 guenchi
;;
;; Licensed under the Apache License, Version 2.0 (the "License");
;; you may not use this file except in compliance with the License.
;; You may obtain a copy of the License at
;;
;;     http://www.apache.org/licenses/LICENSE-2.0
;;
;; Unless required by applicable law or agreed to in writing, software
;; distributed under the License is distributed on an "AS IS" BASIS,
;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;; See the License for the specific language governing permissions and
;; limitations under the License.

;; How much of a reflection target actually needs drawing.
;;
;; A planar reflection re-renders the world into an offscreen target
;; with a mirrored camera, and almost always only a small part of that
;; target can ever be sampled, because the reflector -- a pond, a
;; floor, a pane -- covers a small part of the screen.  Given the main
;; and mirrored view-projections and the reflector's footprint, this
;; answers how much: #f to skip the pass, #t for the whole target, or
;; a pixel rectangle.
;;
;; THE FAILURE MODE THIS EXISTS TO AVOID IS A SILENTLY MISSING
;; REFLECTION.  A rectangle one pixel too small reflects nothing there
;; and nothing reports it -- no error, no black, just a wrong picture
;; that looks plausible.  Every decision here therefore leans one way:
;;
;;   - anything that cannot be projected conservatively answers #t;
;;   - rounding is outward only, floor the minimum and ceil the
;;     maximum, then pad, then clamp;
;;   - #f is returned only when the footprint is PROVABLY not visible
;;     IN THE MAIN VIEW, never as the result of arithmetic that ran
;;     out of precision, and never merely because the reflection
;;     projected outside the target: a sampler with CLAMP_TO_EDGE
;;     still fetches the edge texel, so a footprint that lands off the
;;     target gets the edge strip it will actually read.
;;
;; WHERE reflect-vp COMES FROM, since this file asks for one and never
;; says how to get it: it is the ordinary view-projection with the
;; mirror composed into it,
;;
;;   (m4-mul proj (m4-mul view (reflect-plane-matrix plane-y)))
;;
;; and reflect-plane-matrix, just above, is that mirror.  Two things
;; come with it and neither of them raises.
;;
;; The reflection has determinant -1, so it REVERSES TRIANGLE WINDING.
;; The reflection pass has to flip which face it culls, or every model
;; in the reflection is inside out -- and inside out, on water, reads
;; as an odd highlight rather than as a fault.
;;
;; And do not rebuild the mirrored view out of m4-look-at at a mirrored
;; eye instead.  m4-look-at builds its basis with cross products, a
;; cross product is not equivariant under a transform of determinant
;; -1, and the matrix that comes out differs from the composition above
;; by exactly a negated camera x axis: measured, the two agree to zero
;; once that one axis is flipped back.  A negated x axis is a
;; left-right mirrored reflection.  It is self-consistent, it is
;; plausible on moving water, and it is wrong -- which is the failure
;; this file opened by saying it exists to avoid.
;;
;; What this library does NOT cover, and the caller must: the polygons
;; passed in have to enclose the maximum displacement the caller's
;; shader applies.  A pixel pad cannot recover geometry a wave pushes
;; into view, because padding happens after the footprint has been
;; clipped against the main view -- a crest that rises into frame from
;; a footprint already rejected contributes nothing, and the
;; reflection is missing exactly where the wave is.  `pad' covers only
;; what happens after projection: distorted sampling and filter taps.
;;
;; Pixels have their origin at the LOWER LEFT, matching gl.scissor and
;; cmd-viewport!, and the bounds are the target's -- not the canvas
;; backing size.  (gfx sprite) speaks the opposite convention; code
;; crossing that boundary flips.
(library (gfx reflect)
  (export reflect-plane-matrix reflect-range m4-crop-rect)
  (import (rnrs) (gfx mat))

  (define ($fail who what irritants)
    (apply error who what irritants))

  (define ($fl x) (if (flonum? x) x (exact->inexact x)))

  ;; A value we cannot reason about is not a small error, it is an
  ;; unknown: every caller of this answers #t rather than guessing.
  (define ($finite? x)
    (and (fl=? x x)                     ; not a NaN
         (fl<? x 1e30) (fl<? -1e30 x)))

  (define ($ceil x)
    (let ((f (flfloor x)))
      (if (fl=? f x) f (fl+ f 1.0))))

  ;; ---- the mirror ----

  (define (reflect-plane-matrix plane-y)
    (let ((p ($fl plane-y)))
      (vector 1.0 0.0 0.0 0.0
              0.0 -1.0 0.0 0.0
              0.0 0.0 1.0 0.0
              0.0 (fl* 2.0 p) 0.0 1.0)))

  ;; ---- clip space ----
  ;;
  ;; The raw row products, NOT m4-transform: that one divides by w
  ;; (lib/gfx/mat.ss:433) and w is exactly what the tests below are
  ;; about.  A vertex is carried as its world position AND its clip
  ;; position, because the clipping happens in clip space while what
  ;; comes out has to be re-projected with a different matrix.
  (define ($clip-row m r x y z)
    (fl+ (fl+ (fl* (vector-ref m r) x)
              (fl* (vector-ref m (+ r 4)) y))
         (fl+ (fl* (vector-ref m (+ r 8)) z)
              (vector-ref m (+ r 12)))))

  (define ($vertex m x y z)
    (vector x y z
            ($clip-row m 0 x y z) ($clip-row m 1 x y z)
            ($clip-row m 2 x y z) ($clip-row m 3 x y z)))

  (define ($vx v) (vector-ref v 0))
  (define ($vy v) (vector-ref v 1))
  (define ($vz v) (vector-ref v 2))
  (define ($cx v) (vector-ref v 3))
  (define ($cy v) (vector-ref v 4))
  (define ($cz v) (vector-ref v 5))
  (define ($cw v) (vector-ref v 6))

  ;; the six half-spaces of the canonical view volume, as distances
  ;; that are >= 0 inside: w-x, w+x, w-y, w+y, w-z, w+z
  (define ($half-space i v)
    (let ((w ($cw v)))
      (case i
        ((0) (fl- w ($cx v)))
        ((1) (fl+ w ($cx v)))
        ((2) (fl- w ($cy v)))
        ((3) (fl+ w ($cy v)))
        ((4) (fl- w ($cz v)))
        (else (fl+ w ($cz v))))))

  ;; The half-space test is widened by a hair toward ACCEPTING.  A
  ;; sliver that is visible by less than this is kept, which costs a
  ;; few pixels; a sliver dropped here is gone before the outward
  ;; rounding at the end can do anything about it, and the reflection
  ;; is missing there.  (No red test drove this constant: it is the
  ;; conservative direction, added on the same principle as the rest
  ;; of the file rather than in answer to a reproduction.)
  (define $edge-eps 1e-6)

  ;; Below this the perspective divide stops being informative: the
  ;; quotient is finite but its error is not bounded by anything the
  ;; caller would recognise.  (Also added on principle, without a
  ;; reproduction.)
  (define $min-w 1e-6)

  (define ($lerp a b t) (fl+ a (fl* t (fl- b a))))

  (define ($mix a b t)
    (vector ($lerp ($vx a) ($vx b) t) ($lerp ($vy a) ($vy b) t) ($lerp ($vz a) ($vz b) t)
            ($lerp ($cx a) ($cx b) t) ($lerp ($cy a) ($cy b) t)
            ($lerp ($cz a) ($cz b) t) ($lerp ($cw a) ($cw b) t)))

  ;; Sutherland-Hodgman against one half-space.  Answers the new
  ;; polygon, or 'unknown when an intersection cannot be computed
  ;; safely -- which the caller turns into #t rather than into a
  ;; slightly wrong edge.
  (define ($clip-half vs i)
    (if (null? vs)
        '()
        (let loop ((l vs) (prev (car (reverse vs))) (acc '()))
          (if (null? l)
              (reverse acc)
              (let* ((cur (car l))
                     (dp ($half-space i prev))
                     (dc ($half-space i cur)))
                (if (not (and ($finite? dp) ($finite? dc)))
                    'unknown
                    (let* ((in-p (not (fl<? dp (fl- 0.0 $edge-eps))))
                           (in-c (not (fl<? dc (fl- 0.0 $edge-eps))))
                           (acc (if (eq? in-p in-c)
                                    acc
                                    (let ((den (fl- dp dc)))
                                      (if (fl<? (if (fl<? den 0.0) (fl- 0.0 den) den) 1e-12)
                                          'unknown
                                          (cons ($mix prev cur (fl/ dp den)) acc))))))
                      (if (eq? acc 'unknown)
                          'unknown
                          (loop (cdr l) cur (if in-c (cons cur acc) acc))))))))))

  (define ($clip-all vs)
    (let loop ((i 0) (vs vs))
      (cond
       ((eq? vs 'unknown) 'unknown)
       ((null? vs) '())
       ((= i 6) vs)
       (else (loop (+ i 1) ($clip-half vs i))))))

  ;; ---- the range ----

  (define ($poly-vertices m poly)
    (let loop ((i 0) (acc '()))
      (if (>= (+ i 2) (vector-length poly))
          (reverse acc)
          (loop (+ i 3)
                (cons ($vertex m
                               ($fl (vector-ref poly i))
                               ($fl (vector-ref poly (+ i 1)))
                               ($fl (vector-ref poly (+ i 2))))
                      acc)))))

  (define (reflect-range main-vp reflect-vp polys pad width height)
    (unless (and (integer? width) (> width 0))
      ($fail 'reflect-range "the target width is a positive integer" (list width)))
    (unless (and (integer? height) (> height 0))
      ($fail 'reflect-range "the target height is a positive integer" (list height)))
    (unless (and (number? pad) (>= pad 0) ($finite? ($fl pad)))
      ($fail 'reflect-range "the pad is a finite number of pixels, at least zero"
             (list pad)))
    (unless (list? polys)
      ($fail 'reflect-range "the footprints are a list of flat xyz vectors" (list 'polys)))
    (let ((fw ($fl width)) (fh ($fl height)))
      (let outer ((ps polys) (minx 0.0) (miny 0.0) (maxx 0.0) (maxy 0.0) (any? #f))
        (cond
         ((not (pair? ps))
          (if (not any?)
              #f
              ;; Outward only, and the pad joins the arithmetic BEFORE
              ;; the rounding, so the four components come out whole
              ;; whatever the caller passed.  A fractional pad used to
              ;; produce a fractional rectangle, and then whoever
              ;; turned it into pixels could round it inward -- which
              ;; is the one direction this whole file exists to avoid.
              (let* ((fp ($fl pad))
                     (x0 (exact (flfloor (fl- minx fp))))
                     (y0 (exact (flfloor (fl- miny fp))))
                     (x1 (exact ($ceil (fl+ maxx fp))))
                     (y1 (exact ($ceil (fl+ maxy fp))))
                     ;; Clamping cannot empty the rectangle.  The
                     ;; reflection texture is sampled by the
                     ;; reflector's own fragments through projected
                     ;; coordinates, and out-of-range coordinates fetch
                     ;; the EDGE texel under CLAMP_TO_EDGE -- so if the
                     ;; footprint is visible at all, the edge row or
                     ;; column it lands against still has to be drawn.
                     ;; A one-pixel strip is the honest answer there;
                     ;; #f would silently drop a reflection that is
                     ;; being sampled.
                     (cx0 (min (max 0 x0) (- width 1)))
                     (cy0 (min (max 0 y0) (- height 1)))
                     (cx1 (max (min width x1) (+ cx0 1)))
                     (cy1 (max (min height y1) (+ cy0 1))))
                (if (and (= cx0 0) (= cy0 0) (= cx1 width) (= cy1 height))
                    #t
                    (vector cx0 cy0 (- cx1 cx0) (- cy1 cy0))))))
         (else
          (let ((poly (car ps)))
            (unless (vector? poly)
              ($fail 'reflect-range "a footprint is a flat vector of world xyz"
                     (list 'footprint)))
            (unless (= 0 (mod (vector-length poly) 3))
              ($fail 'reflect-range "a footprint's length is a multiple of three"
                     (list (vector-length poly))))
            (let ((vs ($poly-vertices main-vp poly)))
              (cond
               ((null? vs) (outer (cdr ps) minx miny maxx maxy any?))
               ;; FINITENESS FIRST, before any test that reads a
               ;; position.  A NaN w satisfies "not greater than zero"
               ;; and so passed the behind-the-eye test below, which
               ;; answers #f -- an unknown falling toward "draw
               ;; nothing".  Every uncertainty in this file has to
               ;; fall the other way.
               ((let bad ((l vs))
                  (and (pair? l)
                       (or (not ($finite? ($cw (car l))))
                           (not ($finite? ($cx (car l))))
                           (not ($finite? ($cy (car l))))
                           (not ($finite? ($cz (car l))))
                           (bad (cdr l)))))
                #t)
               ;; entirely behind the eye: provably invisible, and this
               ;; test comes FIRST -- reading it as "crosses the eye
               ;; plane" would answer #t for a reflector the camera has
               ;; driven past, which is the common case
               ((let all ((l vs)) (or (null? l) (and (not (fl<? 0.0 ($cw (car l)))) (all (cdr l)))))
                (outer (cdr ps) minx miny maxx maxy any?))
               ;; crossing it: no conservative projection exists
               ((let some ((l vs)) (and (pair? l) (or (not (fl<? 0.0 ($cw (car l)))) (some (cdr l)))))
                #t)
               (else
                (let ((clipped ($clip-all vs)))
                  (cond
                   ((eq? clipped 'unknown) #t)
                   ((null? clipped) (outer (cdr ps) minx miny maxx maxy any?))
                   (else
                    ;; the mirrored side gets the same question: a
                    ;; vertex that survives the main view can still
                    ;; land at w <= 0 under the reflected projection.
                    ;; Falling outside the mirrored near or far plane
                    ;; is NOT a reason to drop a sample, so only w is
                    ;; tested here.
                    (let inner ((l clipped) (mnx minx) (mny miny)
                                (mxx maxx) (mxy maxy) (seen any?))
                      (if (null? l)
                          (outer (cdr ps) mnx mny mxx mxy seen)
                          (let* ((v (car l))
                                 (rx ($clip-row reflect-vp 0 ($vx v) ($vy v) ($vz v)))
                                 (ry ($clip-row reflect-vp 1 ($vx v) ($vy v) ($vz v)))
                                 (rw ($clip-row reflect-vp 3 ($vx v) ($vy v) ($vz v))))
                            ;; a positive but tiny w divides to a huge
                            ;; coordinate whose error is huge too:
                            ;; "the result is finite" is not "the
                            ;; bound is conservative"
                            (if (or (not ($finite? rw)) (fl<? rw $min-w)
                                    (not ($finite? rx)) (not ($finite? ry)))
                                #t
                                (let ((px (fl* (fl/ (fl+ (fl/ rx rw) 1.0) 2.0) fw))
                                      (py (fl* (fl/ (fl+ (fl/ ry rw) 1.0) 2.0) fh)))
                                  (if (not (and ($finite? px) ($finite? py)))
                                      #t
                                      (inner (cdr l)
                                             (if seen (if (fl<? px mnx) px mnx) px)
                                             (if seen (if (fl<? py mny) py mny) py)
                                             (if seen (if (fl<? mxx px) px mxx) px)
                                             (if seen (if (fl<? mxy py) py mxy) py)
                                             #t)))))))))))))))))))

  ;; Restrict a projection to a pixel rectangle of the target: the
  ;; rectangle becomes the whole of NDC.  Pre-multiplying keeps an
  ;; asymmetric or oblique projection intact, which rebuilding a
  ;; symmetric frustum from the rectangle would quietly lose; and the
  ;; coefficients are computed from pixels rather than from NDC edges,
  ;; which on a small rectangle would be a difference of nearly equal
  ;; numbers.
  (define (m4-crop-rect proj x y w h width height)
    (unless (and (integer? width) (> width 0) (integer? height) (> height 0))
      ($fail 'm4-crop-rect "the target dimensions are positive integers"
             (list width height)))
    (unless (and (number? w) (> w 0) (number? h) (> h 0))
      ($fail 'm4-crop-rect "the rectangle has a positive width and height"
             (list w h)))
    (let ((fx ($fl x)) (fy ($fl y)) (fw ($fl w)) (fh ($fl h))
          (fW ($fl width)) (fH ($fl height)))
      (m4-mul (vector (fl/ fW fw) 0.0 0.0 0.0
                      0.0 (fl/ fH fh) 0.0 0.0
                      0.0 0.0 1.0 0.0
                      (fl/ (fl- (fl- fW (fl* 2.0 fx)) fw) fw)
                      (fl/ (fl- (fl- fH (fl* 2.0 fy)) fh) fh)
                      0.0 1.0)
              proj))))
