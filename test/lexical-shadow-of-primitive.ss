;; expect: inner
;; The green twin of defect-internal-define-shadows-primitive.ss: the
;; same shadow written as a `let' works, and must keep working while
;; the internal-definition case is repaired.
(import (rnrs))
(define (go p) (let ((car (lambda (x) 'inner))) (car p)))
(display (go '(1)))
