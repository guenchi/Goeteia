;; expect: 7
;; RED ON PURPOSE: an internal definition later assigned by set! is
;; filled through the same bare set-car!; see
;; defect-c02-synth-internal-define-set-car.  Chez answers 7; here the
;; cell's contents are never written and an unknown object prints.
(import (rnrs))
(define (set-car! p v) (quote mine))
(define (go) (define x 5) (set! x 7) x)
(display (go))
