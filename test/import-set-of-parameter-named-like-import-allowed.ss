;; expect: 7
;; GREEN TWIN: a parameter spelled like an imported name is the
;; program's to assign.
(import (rnrs))
(display ((lambda (car) (set! car 7) car) 0))
