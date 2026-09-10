;; expect: sym
;; The twin of c02-excluded-float-op-value-form that cannot pass by
;; accident: the program's fl+ answers a symbol.  A float site that
;; still believed it had the primitive would unbox the symbol as an
;; f64 and print a plausible number; the guard being consulted prints
;; the symbol.  Chez answers sym.
(import (except (rnrs) fl+))
(define fl+ (lambda (a b) (quote sym)))
(display (fl+ 1.0 2.0))
