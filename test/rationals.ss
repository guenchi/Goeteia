;; expect: #t
(define (fact n) (if (zero? n) 1 (* n (fact (- n 1)))))
(and ;; exact division makes exact ratios
     (= (/ 7 2) 7/2)
     (= (numerator 7/2) 7)
     (= (denominator 7/2) 2)
     ;; normalization
     (= 6/4 3/2)
     (fixnum? (/ 8 2))
     (fixnum? (+ 1/2 1/2))
     ;; arithmetic
     (= (+ 1/3 1/6) 1/2)
     (= (* 2/3 3/4) 1/2)
     (= (- 1/2 1/3) 1/6)
     (= (/ 1/2 1/4) 2)
     (< 1/3 1/2)
     (< 2/7 1/3)
     ;; negatives keep the sign on the numerator
     (= (/ -6 4) -3/2)
     (< -1/2 1/3)
     ;; contagion with flonums
     (= (+ 1/2 0.5) 1.0)
     (= (exact->inexact 1/4) 0.25)
     ;; inexact->exact recovers dyadic rationals exactly
     (= (inexact->exact 0.5) 1/2)
     (= (inexact->exact 0.375) 3/8)
     ;; bignum ratio reduction via full division
     (= (/ (fact 20) (fact 18)) 380)
     (= (/ (fact 18) (fact 20)) 1/380)
     ;; gcd/lcm along the way
     (= (gcd 12 18) 6)
     (= (gcd (fact 20) (fact 18)) (fact 18))
     (= (lcm 4 6) 12)
     ;; full bignum quotient/remainder
     (= (quotient (fact 20) (fact 18)) 380)
     (= (remainder (+ (fact 20) 7) (fact 18)) 7))
