;; Signed distance fields from rasterized text (or any canvas
;; alpha): the fix for bitmap labels that blur when the camera
;; leans in.  Rasterize once at a modest size, run a distance
;; transform, and sample with a smoothstep around 0.5 -- the edge
;; re-sharpens at ANY magnification, because what the texture
;; stores is geometry, not pixels.
;;
;;   (define wh (sdf-from-canvas! cv base 12.0))
;;   (gl-texture-data! tex base (car wh) (cdr wh))
;;   ... fragment: (local vec4 t (texture2D u_tex v_uv))
;;       (local float a (smoothstep (fl 0 44) (fl 0 56) t.a))
;;
;; sdf-from-canvas! grabs the canvas's alpha into staging memory at
;; `base` (one JS call, whatever the size), then runs a two-pass
;; 3-4 chamfer distance transform out of the shape and another one
;; in, entirely in wasm.  The result overwrites [base, base+w*h*4)
;; as white RGBA whose alpha is the signed distance mapped to
;; 0.5 +/- spread pixels -- feed it straight to gl-texture-data!.
;; Widen the smoothstep for soft halos, shift its center below 0.5
;; for outlines and glow; the field carries all of it.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (gfx sdf)
  (export sdf-from-canvas!)
  (import (rnrs) (web js))

  (define $sdf-grab-src
    (string-append
     "globalThis.__goeteia_sdf_grab = (cv, base) => {"
     " const ctx = cv.getContext('2d');"
     " const d = ctx.getImageData(0, 0, cv.width, cv.height).data;"
     " const m = new Uint8Array(globalThis.__goeteia_mem.buffer);"
     " const n = cv.width * cv.height;"
     " for (let i = 0; i < n; i++) m[base + i] = d[i * 4 + 3];"
     " return n; };"))

  (define $sdf-inf 1000000)

  ;; the forward+backward 3-4 chamfer over a fixnum field stored as
  ;; 4-byte ints at `at`; distances scale by 3 (one pixel = 3)
  (define ($sdf-chamfer! at w h)
    (define (dref i) (%mem-i32-ref (+ at (* i 4))))
    (define (dset! i v) (%mem-i32-set! (+ at (* i 4)) v))
    (define (relax! i v) (when (< v (dref i)) (dset! i v)))
    ;; forward: left, up, and the two upper diagonals
    (let fwd ((y 0))
      (when (< y h)
        (let row ((x 0))
          (when (< x w)
            (let ((i (+ (* y w) x)))
              (when (> x 0) (relax! i (+ (dref (- i 1)) 3)))
              (when (> y 0)
                (relax! i (+ (dref (- i w)) 3))
                (when (> x 0) (relax! i (+ (dref (- i w 1)) 4)))
                (when (< x (- w 1)) (relax! i (+ (dref (- i w -1)) 4)))))
            (row (+ x 1))))
        (fwd (+ y 1))))
    ;; backward: right, down, and the two lower diagonals
    (let bwd ((y (- h 1)))
      (when (>= y 0)
        (let row ((x (- w 1)))
          (when (>= x 0)
            (let ((i (+ (* y w) x)))
              (when (< x (- w 1)) (relax! i (+ (dref (+ i 1)) 3)))
              (when (< y (- h 1))
                (relax! i (+ (dref (+ i w)) 3))
                (when (< x (- w 1)) (relax! i (+ (dref (+ i w 1)) 4)))
                (when (> x 0) (relax! i (+ (dref (+ i w -1)) 4)))))
            (row (- x 1))))
        (bwd (- y 1))))
    #t)

  ;; scratch layout after `base`: the grabbed alpha bytes sit at
  ;; base..base+n, the two distance fields follow as i32 grids
  (define (sdf-from-canvas! cv base spread)
    (js-eval $sdf-grab-src)
    (let* ((w (js->number (js-get cv "width")))
           (h (js->number (js-get cv "height")))
           (n (* w h))
           (dout (+ base n))             ; distance to the shape
           (din (+ dout (* n 4)))        ; distance to the outside
           (need (+ din (* n 4)))
           (have (* 65536 (%mem-size)))
           (sp (if (flonum? spread) spread (exact->inexact spread))))
      (when (> need have)
        (%mem-grow (quotient (+ (- need have) 65535) 65536)))
      (js-call (js-get (js-global) "__goeteia_sdf_grab") (js-undefined)
               cv base)
      ;; seed both fields from the binarized alpha
      (let seed ((i 0))
        (when (< i n)
          (let ((in? (> (%mem-u8-ref (+ base i)) 127)))
            (%mem-i32-set! (+ dout (* i 4)) (if in? 0 $sdf-inf))
            (%mem-i32-set! (+ din (* i 4)) (if in? $sdf-inf 0)))
          (seed (+ i 1))))
      ($sdf-chamfer! dout w h)
      ($sdf-chamfer! din w h)
      ;; signed distance -> alpha around 128, white RGBA in place.
      ;; Ascending is load-bearing: the write at index i lands over
      ;; dout entries already consumed, never ones still ahead
      (let out ((i 0))
        (when (< i n)
          (let* ((o (%mem-i32-ref (+ dout (* i 4))))
                 (v (%mem-i32-ref (+ din (* i 4))))
                 ;; chamfer units are thirds of a pixel
                 (signed (fl/ (fixnum->flonum (- v o)) 3.0))
                 (a (fl+ 128.0 (fl* 127.0 (fl/ signed sp))))
                 (b (%fl->fx (if (fl<? a 0.0)
                                 0.0
                                 (if (fl<? 255.0 a) 255.0 a))))
                 (at (+ base (* i 4))))
            (%mem-u8-set! at 255)
            (%mem-u8-set! (+ at 1) 255)
            (%mem-u8-set! (+ at 2) 255)
            (%mem-u8-set! (+ at 3) b))
          (out (+ i 1))))
      (cons w h))))
