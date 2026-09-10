;; expect: inner
;; An internal definition whose name is a primitive's is broken; the
;; same shadow through `let' is not.  Chez: inner.  Today: illegal cast
;; -- a trap, so this file's verdict is that one row and no more.
;;
;; Found by the session implementing the second binding-identity slice
;; while checking its internal-definition arm, and measured on the
;; snapshot that predates that slice before being reported, so it is
;; not a regression from it.  The let twin is beside this file.
(import (rnrs))
(define (go p) (define (car x) 'inner) (car p))
(display (go '(1)))
