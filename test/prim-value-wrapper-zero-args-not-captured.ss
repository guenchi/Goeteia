;; expect: 0
;; The wrapper built when a primitive is taken as a value first asks
;; whether it was called with no arguments at all, with null?.  Every
;; other wrapper cell passes arguments, and with arguments present that
;; test answers the same whether it reached the real null? or the
;; program's -- so those cells could not see this site; it needs the
;; zero-argument call.  (+) is 0 in Chez; before the fix this ended in
;; an illegal cast.
(import (except (rnrs) null?))
(define (null? x) #f)
(display ((lambda (f) (f)) +))
