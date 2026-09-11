;; expect: one
;; REGRESSION GUARD (written as a red witness at 52f6ef5; green since).
;; The defect as it then was: the expansion of case is written with a
;; bare eq?, so a program's top-level eq? is what every case dispatches
;; through. Chez answers one; here the run exhausts the stack. Same
;; class as slice 3's append and $escape -- a reference the compiler
;; writes during expansion -- and not in that slice's list.
(import (except (rnrs) eq?))
(define (eq? a b) #f)
(display (case 1 ((1) (quote one)) (else (quote other))))
