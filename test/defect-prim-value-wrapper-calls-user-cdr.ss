;; expect: 6
;; RED ON PURPOSE: the cdr half of the primitive-as-value wrapper; see
;; defect-prim-value-wrapper-calls-user-null.  The wrapper's argument
;; walk takes cdr by bare name and gets the program's.  The program's
;; cdr answers the empty list so the walk STOPS after one element and
;; the wrong sum is observable: 1 where Chez answers 6.  (A cdr that
;; answered a symbol made the walk loop forever, and a cell that hangs
;; costs every gate 180 seconds per host for the same reading.)
(import (except (rnrs) cdr))
(define (cdr x) (quote ()))
(display ((lambda (f) (f 1 2 3)) +))
