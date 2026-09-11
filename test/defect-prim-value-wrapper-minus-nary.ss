;; expect: 5
;; REGRESSION GUARD (written as a red witness at 8514ae1; green since).
;; The defect as it then was: the wrapper for - with three arguments
;; folds through a loop tested with bare null?; see defect-prim-value-
;; wrapper-calls-user-null. Chez answers 5; here an illegal cast.
(import (except (rnrs) null?))
(define (null? x) #f)
(display ((lambda (f) (f 10 3 2)) -))
