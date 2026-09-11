;; expect: -5
;; REGRESSION GUARD (written as a red witness at 8514ae1; green since).
;; The defect as it then was: the wrapper for - taken as a value negates
;; its single argument after testing the rest of the list with bare
;; null?, so a program's null? that answers #f sends it into the fold
;; instead, and the fold's first car is taken from an empty list:
;; illegal cast where Chez answers -5. (Redefining cdr made this walk
;; loop forever; the hang is the same defect and a worse cell.)
(import (except (rnrs) null?))
(define (null? x) #f)
(display ((lambda (f) (f 5)) -))
