;; expect: 3
;; RED ON PURPOSE: a primitive taken as a value gets a synthesized
;; wrapper whose body is written with bare names, and a program's
;; definition of one of those names captures it.
;;
;; (f 1 2) with f bound to the value + runs a lifted body that walks
;; its argument list with car, cdr and null?, spelled as bare symbols
;; at emission.  car reaches the intrinsic; null? does not -- it is
;; not in the lowered set -- so a program that defines null? at the
;; top level is called from inside the wrapper, the walk never stops,
;; and the run ends in an illegal cast.  Chez answers 3.  This is the
;; fourth spelling of the open null? entry: the prelude's own calls,
;; the compiler's synthesized calls, and now a wrapper built at
;; emission all reach the program's definition by the same bare name.
(import (except (rnrs) null?))
(define (null? x) #f)
(display ((lambda (f) (f 1 2)) +))
