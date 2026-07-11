;; expect: 25
(define (twice f x) (f (f x)))
(define (inc n) (+ n 1))
(+ (twice (lambda (n) (* n 3)) 2)
   (twice inc 5))
