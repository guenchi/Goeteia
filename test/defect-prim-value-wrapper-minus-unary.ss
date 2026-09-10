;; expect: -5
;; RED ON PURPOSE: the wrapper for - taken as a value negates its single
;; argument through a walk written with bare cdr; see
;; defect-prim-value-wrapper-calls-user-cdr.  Chez answers -5; here
;; nothing is printed.
(import (rnrs))
(define (cdr x) (quote mine))
(display ((lambda (f) (f 5)) -))
