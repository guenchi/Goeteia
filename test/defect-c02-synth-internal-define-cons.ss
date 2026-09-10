;; expect: 5
;; RED ON PURPOSE: internal definitions are lowered through cells built
;; with a bare cons and filled with a bare set-car!, so a program's
;; top-level cons is what every internal define allocates through.
;; Chez answers 5; here the run ends in an illegal cast.
(import (rnrs))
(define (cons a b) (quote mine))
(define (go) (define x 5) (define (f) x) (f))
(display (go))
