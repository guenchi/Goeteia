;; expect: #t
(define-syntax my-when2
  (syntax-rules ()
    ((_ t e ...) (if t (begin e ...) #f))))
(define-syntax my-or2
  (syntax-rules ()
    ((_) #f)
    ((_ e) e)
    ((_ e1 e2 ...) (let ((t e1)) (if t t (my-or2 e2 ...))))))
(define-syntax arrow
  (syntax-rules (=>)
    ((_ => x) 'yes)
    ((_ x y) 'no)))
(define-syntax firsts
  (syntax-rules ()
    ((_ (a b ...) ...) '(a ...))))
(define-syntax lastly
  (syntax-rules ()
    ((_ a ... b) 'b)))
(and (eq? (my-when2 #t 1 2 3) 3)
     (eq? (my-when2 #f 1) #f)
     (eq? (my-or2) #f)
     (eq? (my-or2 #f 7) 7)
     ;; hygiene: the t introduced by my-or2 must not capture user t
     (let ((t 100)) (eq? (my-or2 #f t) 100))
     (eq? (arrow => 5) 'yes)
     (eq? (arrow 4 5) 'no)
     (equal? (firsts (1 2) (3 4 5) (6)) '(1 3 6))
     (eq? (lastly 1 2 3) 3))
