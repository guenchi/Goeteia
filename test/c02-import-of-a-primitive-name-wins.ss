;; expect: 77
;; A library that imports a sister library's definition of a primitive's
;; name -- excluding that name from (rnrs) -- must call the import, as
;; R6RS says.  When every primitive became a lowered head, the library
;; scope's bound set knew what the library DEFINED and not what it
;; IMPORTED, so the call went to the primitive: 2.0 where the host and
;; the compiler before that change answer 77.  A reviewer's fixture.
;; The oracle cells c and d are the same shape with the opposite
;; answer, and were green throughout; this is their missing half.
(import (rnrs))
(begin
  (library (a) (export flsqrt) (import (except (rnrs) flsqrt)) (define (flsqrt x) 77))
  (library (b) (export probe) (import (except (rnrs) flsqrt) (a)) (define (probe) (flsqrt 4.0)))
  (import (b)))
(display (probe))
