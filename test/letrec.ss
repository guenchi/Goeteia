;; expect: #t
(letrec ((ev? (lambda (n) (if (zero? n) #t (od? (- n 1)))))
         (od? (lambda (n) (if (zero? n) #f (ev? (- n 1))))))
  (and (ev? 10) (od? 7)))
