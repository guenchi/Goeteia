;; expect: mine
;; C02, variant e, the negative twin of variant d: a library that
;; DEFINES its own car must mean its own, not the primitive.  This is
;; what stands between "protect the import" and "steal the library's
;; own name", and it is green today and must stay green.
(import (rnrs))
(begin
  (library (orc lib5)
    (export mine)
    (import (rnrs))
    (define (car x) 'mine)
    (define (mine p) (car p)))
  (import (orc lib5)))
(display (mine '(1)))
