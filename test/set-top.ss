;; expect: 10
(define total 0)
(define (add! n)
  (set! total (+ total n)))
(add! 4)
(add! 6)
total
