;; expect: #t
(define-syntax def-const
  (syntax-rules ()
    ((_ name val)
     (define-syntax name
       (syntax-rules ()
         ((_) val))))))
(def-const answer 42)
(define-syntax def-lister
  (syntax-rules ()
    ((_ name)
     (define-syntax name
       (syntax-rules ()
         ((_ x (... ...)) '(x (... ...))))))))
(def-lister li)
(define-syntax deep
  (syntax-rules ()
    ((_ (a ...) ...) '(a ... ...))))
(and (eq? (answer) 42)
     (equal? (li 1 2 3) '(1 2 3))
     (equal? (deep (1 2) (3) (4 5)) '(1 2 3 4 5)))
