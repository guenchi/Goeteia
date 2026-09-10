;; expect: (1 2 3)
;; RED ON PURPOSE: quasiquote's expansion is written with a bare cons
;; (its append was fixed by slice 3; its cons was not), so a program's
;; top-level cons builds the template.  Chez answers (1 2 3).
(import (except (rnrs) cons))
(define (cons a b) (quote mine))
(display `(1 ,(+ 1 1) 3))
