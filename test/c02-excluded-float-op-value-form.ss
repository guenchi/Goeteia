;; expect: 0.0
;; A float primitive's name, excluded from (rnrs) and defined by the
;; program as a VALUE, must be the program's at a float site.  Every
;; site that recognised a float primitive by its symbol used to ask
;; only whether a top-level FUNCTION shadowed it, so a value-form
;; definition was invisible there and 3.0 came out.  Chez answers 0.0.
(import (except (rnrs) fl+))
(define fl+ (lambda (a b) 0.0))
(display (fl+ 1.0 2.0))
