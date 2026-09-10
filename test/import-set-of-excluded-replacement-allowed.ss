;; expect: 2
;; GREEN TWIN: after excluding the name, the program's own replacement
;; is an ordinary variable and may be assigned.
(import (except (rnrs) car))
(define car 1)
(set! car 2)
(display car)
