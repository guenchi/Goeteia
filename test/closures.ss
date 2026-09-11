;; expect: 15
(import (rnrs))
(define (make-adder n)
  (lambda (x) (+ x n)))
((make-adder 5) 10)
