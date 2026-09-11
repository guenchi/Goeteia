;; expect: 5
;; REGRESSION GUARD (written as a red witness at 52f6ef5; green since).
;; The defect as it then was: the set-car! half of the internal-define
;; lowering; see defect-c02-synth-internal-define-cons. Chez answers 5.
(import (except (rnrs) set-car!))
(define (set-car! p v) (quote mine))
(define (go) (define x 5) (define (f) x) (f))
(display (go))
