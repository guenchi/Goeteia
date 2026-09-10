;; expect: (1 2 3)
;; A library that excludes `append' from its import and defines its own
;; is a valid R6RS program; Chez runs it and the splice still uses the
;; expander's append: (1 2 3).  Today the compiler refuses it -- "top-
;; level name defined twice" -- because in the flat-splice model a
;; library's definitions land at top level beside the prelude's, and the
;; import list constrains nothing.  A different defect from the
;; binding-identity family: not a capture, a rejection of a legal
;; program.  Recorded here so it is not mistaken for coverage of the
;; library route, which this rejection closes by accident.
(import (rnrs))
(begin (library (o l) (export f) (import (except (rnrs) append)) (define (append a b) 'mine) (define (f) `(1 ,@'(2 3)))) (import (o l)))
(display (f))
