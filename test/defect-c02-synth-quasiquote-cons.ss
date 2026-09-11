;; expect: (1 2 3)
;; REGRESSION GUARD. Written as a red witness at 52f6ef5, when
;; quasiquote's expansion used a bare cons, so a program that excludes
;; cons and defines its own had its cons build the template. Pins that
;; the cons quasiquote's expansion introduces is the prelude's, because
;; the compiler wrote that reference, while the program's own cons still
;; serves the program. Chez answers (1 2 3).
(import (except (rnrs) cons))
(define (cons a b) (quote mine))
(display `(1 ,(+ 1 1) 3))
