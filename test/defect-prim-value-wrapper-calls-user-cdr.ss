;; expect: 6
;; RED ON PURPOSE: the cdr half of the primitive-as-value wrapper; see
;; defect-prim-value-wrapper-calls-user-null.  The wrapper's argument
;; walk takes cdr by bare name and gets the program's.  Chez answers 6;
;; here nothing is printed.
(import (rnrs))
(define (cdr x) (quote mine))
(display ((lambda (f) (f 1 2 3)) +))
