;; expect: 500000
(define (count i acc)
  (if (= i 0) acc (count (- i 1) (+ acc 1))))
(count 500000 0)
