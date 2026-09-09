;; expect: #t
;; The one macro-introduced top-level definition that works, and why.
;;
;; A name handed in as a macro ARGUMENT is never renamed, so the key
;; *vars* is built from and the key the assignment looks up are the
;; same.  ⭐ It is green for a reason that cannot quietly change,
;; unlike the three defect files beside it -- two of those compile
;; today only because dead-code elimination deletes the definition
;; before anything can fail to find it.
;;
;; ⇒ If this one ever goes red, the renaming rule changed, and the
;; place to look is how a macro's own arguments are marked.
(import (rnrs))
(define-syntax m (syntax-rules () ((_ n) (define n (car '(9))))))
(m pin)
(display (= 9 pin))
