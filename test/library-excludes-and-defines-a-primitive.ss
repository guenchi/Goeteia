;; expect: 9
;; A library that excludes a primitive's name from (rnrs) and defines
;; its own is the legal R6RS form, and its own calls use its
;; definition.  This is the primitive half of what
;; defect-library-redefines-imported-name asks for a prelude PROCEDURE
;; (append), which waits on the coexistence step.  Chez answers 9.
(import (rnrs))
(begin
  (library (o l) (export f) (import (except (rnrs) car)) (define (car x) 9) (define (f) (car (list 1))))
  (import (o l)))
(display (f))
