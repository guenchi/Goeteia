;; expect: (raised 7)
;; A record accessor given something that is not its record raises; it does
;; not call a procedure named error that the program wrote.  The accessor's
;; failure path is the compiler's, and a program that excludes error from
;; its import and defines one of its own used to have it called there:
;; the accessor answered whatever that procedure returned.
(import (except (rnrs) error))
(define (error . xs) 'mine)
(define-record-type point (fields x))
(display (list (guard (e (#t 'raised)) (point-x 5))
               (point-x (make-point 7))))
