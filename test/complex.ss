;; expect: #t
(define z (make-rectangular 3 4))
(and (complex? z)
     (not (real? z))
     (= (real-part z) 3)
     (= (imag-part z) 4)
     ;; reader syntax
     (= 3+4i z)
     (= (imag-part +2i) 2)
     (= (real-part +2i) 0)
     (= (imag-part -i) -1)
     (= (real-part 5) 5)
     (= (imag-part 5) 0)
     ;; arithmetic
     (= (+ 1+2i 3+4i) 4+6i)
     (= (* 1+2i 3+4i) -5+10i)
     (= (- 3+4i 3+4i) 0)
     ;; exact zero imaginary collapses to a real
     (real? (- 3+4i 0+4i))
     (= (/ -5+10i 3+4i) 1+2i)
     ;; magnitude and sqrt of negatives
     (= (magnitude 3+4i) 5.0)
     (= (sqrt -4) +2.0i)
     (= (* (sqrt -4) (sqrt -4)) -4.0)
     ;; exactness
     (exact? 1+2i)
     (not (exact? 1.0+2i)))
