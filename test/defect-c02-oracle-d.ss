;; expect: from-lib
;; C02, variant d: a library function WRITTEN DIRECTLY -- no macro --
;; calls car, and the program defines car after importing it.  Chez:
;; from-lib.  Today: shadow.
;;
;; This is the row the first slice cannot reach, and it is the row that
;; matters most: that slice attaches a defining scope to identifiers a
;; macro INTRODUCES (rename-introduced records it), and a library's own
;; body is not introduced by anything -- it is written.  Every library
;; in lib/ and the whole of the prelude are this shape.  a3 going green
;; while d stays red is the measurement that the slice protects
;; templates and not scopes.
(import (except (rnrs) car))
(begin
  (library (orc lib4)
    (export head)
    (import (rnrs))
    (define (head p) (car p)))
  (import (orc lib4)))
(define (car x) 'shadow)
(display (head '(from-lib)))
