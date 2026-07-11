;; expect: #t
(define (add a b) (+ a b))
(define (weird a . rest) (cons a rest))
(and (eq? (apply add '(20 22)) 42)
     (eq? (apply add 20 '(22)) 42)
     (equal? (apply list 1 2 '(3 4)) '(1 2 3 4))
     (equal? (apply weird 1 2 '(3)) '(1 2 3))
     (eq? (apply (lambda (x y z) (* x (+ y z))) '(2 3 4)) 14)
     ;; apply with a closure value
     (let ((mul (lambda (a b) (* a b))))
       (eq? (apply mul '(6 7)) 42)))
