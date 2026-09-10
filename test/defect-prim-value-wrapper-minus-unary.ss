;; expect: -5
;; RED ON PURPOSE: the wrapper for - taken as a value negates its single
;; argument after testing the rest of the list with bare null?, so a
;; program's null? that answers #f sends it into the fold instead, and
;; the fold's first car is taken from an empty list: illegal cast where
;; Chez answers -5.  (Redefining cdr made this walk loop forever; the
;; hang is the same defect and a worse cell.)
(import (except (rnrs) null?))
(define (null? x) #f)
(display ((lambda (f) (f 5)) -))
