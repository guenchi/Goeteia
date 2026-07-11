;; expect: #t
(define k (lambda x x))
(define (f a . rest) (cons a rest))
(define g (lambda (a b . r) (cons b (cons a r))))
(and (equal? (k 1 2 3) '(1 2 3))
     (equal? (k) '())
     (equal? (f 1 2 3) '(1 2 3))
     (equal? (f 1) '(1))
     (equal? (g 1 2 3 4) '(2 1 3 4))
     ;; variadic closures called as values
     (let ((h (lambda x x)))
       (and (equal? (h 1 2) '(1 2))
            (equal? ((lambda (a . r) r) 1 2 3) '(2 3)))))
