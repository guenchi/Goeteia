;; expect: 5
;; The green twin of defect-spec-shadowed-parameter-demotes-nothing:
;; the same exact 5 passed through a local that does NOT share the
;; parameter's name.  The demotion sees a call whose first operand is
;; not the f64 parameter, demotes it, and the exact integer travels as
;; eqref.  If this file ever goes red the analysis moved for a reason
;; the defect cell does not describe.
(import (rnrs))
(define (zq a b) (let ((c 5)) (if (fl<? b 0.0) (zq c (fl+ b 1.0)) a)))
(display (zq 5.0 -1.0))
