;; expect: #t
;; RED ON PURPOSE: mutually recursive internal definitions go through the
;; same cons-built cells; see defect-c02-synth-internal-define-cons.
;; Chez answers #t; here an illegal cast.
(import (except (rnrs) cons))
(define (cons a b) (quote mine))
(define (go n) (define (ev? k) (if (= k 0) #t (od? (- k 1)))) (define (od? k) (if (= k 0) #f (ev? (- k 1)))) (ev? n))
(display (go 10))
