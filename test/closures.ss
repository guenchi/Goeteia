;; expect: 15
(define (make-adder n)
  (lambda (x) (+ x n)))
((make-adder 5) 10)
