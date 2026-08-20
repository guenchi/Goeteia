;; Text drawn through the (gfx sprite) glyph atlas: the 2d context
;; rasterizes glyphs (measureText/fillText on an offscreen canvas),
;; the GL context draws the quads -- so verifying this page needs
;; BOTH mock contexts to answer, each with its own log.
(import (rnrs) (web js) (web dom) (gfx glsl) (gfx fx) (web typeset)
        (gfx sprite))

(fx-init! (get-element-by-id "c"))

(define at (make-atlas "16px monospace" 16))
(define bt (make-batch at))
(define lay
  (layout (prepare "Sprite text renders here" (atlas-measurer at))
          600.0 (atlas-line-height at)))

(fx-loop!
 (lambda (t dt)
   (batch-begin! bt)
   (rect! bt 10 10 260 40 0.15 0.15 0.5 1.0)
   (draw-text! bt lay 20.0 22.0 1.0 1.0 1.0 1.0)
   (batch-draw! bt)))
