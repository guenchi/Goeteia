;; expect: 5
;; RED ON PURPOSE: the set-car! half of the internal-define lowering; see
;; defect-c02-synth-internal-define-cons.  Chez answers 5.
(import (except (rnrs) set-car!))
(define (set-car! p v) (quote mine))
(define (go) (define x 5) (define (f) x) (f))
(display (go))
