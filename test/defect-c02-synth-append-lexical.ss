;; expect: (1 2 3)
;; C02, the compiler's own synthesized references: quasiquote splicing
;; expands to a call to the prelude's `append', by bare symbol, and a
;; lexical `append' in scope captures it.  Chez: (1 2 3), because the
;; expander's append is hygienic.  Today: (1 . mine).
;;
;; A top-level (define (append ...)) is already refused -- "top-level
;; name defined twice" -- so the lexical route is the live one.  The
;; twin beside this file shows `car' in the same position is now safe
;; (slices 1 and 2), which is what separates "written references" from
;; "references the compiler makes up".
(import (rnrs))
(display (let ((append (lambda (a b) 'mine))) `(1 ,@'(2 3))))
