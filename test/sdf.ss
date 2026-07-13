;; expect: #t
;; (web sdf) against a synthetic canvas: a filled square becomes a
;; signed distance field -- deep inside saturates high, far outside
;; saturates low, and the boundary crosses 128 within one pixel.
(import (rnrs) (web js) (web sdf))

;; a 16x16 canvas whose alpha is a square over x,y in [4,12)
(js-eval "
globalThis.__mockcv = {
  width: 16, height: 16,
  getContext(k) {
    return { getImageData(x, y, w, h) {
      const d = new Uint8ClampedArray(w * h * 4);
      for (let yy = 0; yy < h; yy++)
        for (let xx = 0; xx < w; xx++)
          if (xx >= 4 && xx < 12 && yy >= 4 && yy < 12)
            d[(yy * w + xx) * 4 + 3] = 255;
      return { data: d };
    } };
  } };")

(define BASE 8192)
(define wh (sdf-from-canvas! (js-get (js-global) "__mockcv") BASE 4.0))

(define (alpha x y) (%mem-u8-ref (+ BASE (* (+ (* y 16) x) 4) 3)))

(and (equal? wh '(16 . 16))
     ;; every pixel is white; only alpha carries the field
     (= (%mem-u8-ref BASE) 255)
     (= (%mem-u8-ref (+ BASE 1)) 255)
     (= (%mem-u8-ref (+ BASE 2)) 255)
     ;; the middle of the square: 4px deep, saturated at the spread
     (= (alpha 8 8) 255)
     ;; the far corner: 4+px outside, saturated the other way
     (= (alpha 0 0) 0)
     ;; the first inside column reads just above the 128 midline...
     (let ((a (alpha 4 8))) (and (< 145 a) (< a 175)))
     ;; ...and its outside neighbor just below
     (let ((a (alpha 3 8))) (and (< 80 a) (< a 112))))
