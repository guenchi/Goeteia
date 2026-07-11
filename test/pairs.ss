;; expect: #t
(define (len ls)
  (if (null? ls) 0 (+ 1 (len (cdr ls)))))
(let ((p (cons 1 (cons 2 '()))))
  (if (pair? p)
      (if (= (car p) 1)
          (= (len p) 2)
          #f)
      #f))
