;; expect: 2432902008176640000 -3.25 0.5
(define (fact n) (if (zero? n) 1 (* n (fact (- n 1)))))
(display (fact 20))
(display " ")
(display (- 0 3.25))
(display " ")
(display 0.5)
(newline)
