;; expect: 2
;; GREEN TWIN of import-set-of-imported-name-refused: a let-bound local
;; spelled like an imported name is the program's to assign.
(import (rnrs))
(display (let ((car 1)) (set! car 2) car))
