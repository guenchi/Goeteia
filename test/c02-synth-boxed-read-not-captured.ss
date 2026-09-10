;; expect: 7
;; A variable that is assigned lives in a box, and reading it is written
;; by assignment conversion as a car of the box; a program's top-level
;; car used to be what that read called.  The internal-define cells all
;; redefine cons or set-car!, so none of them reached this site: it is
;; the boxed READ, and only a program that defines car can see it.
;; Chez answers 7; before the fix this printed mine.
(import (except (rnrs) car))
(define (car x) (quote mine))
(define (go) (define n 5) (set! n 7) n)
(display (go))
