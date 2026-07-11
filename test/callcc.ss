;; expect: #t
(define (product ls)
  (call/cc
   (lambda (break)
     (let loop ((ls ls) (acc 1))
       (cond
        ((null? ls) acc)
        ((zero? (car ls)) (break 0))
        (else (loop (cdr ls) (* acc (car ls)))))))))
(define (find-first pred ls)
  (call-with-current-continuation
   (lambda (return)
     (for-each (lambda (x) (when (pred x) (return x))) ls)
     #f)))
(and (eq? (call/cc (lambda (k) 7)) 7)
     (eq? (call/cc (lambda (k) (+ 1 (k 41)))) 41)
     (eq? (product '(1 2 3 4)) 24)
     (eq? (product '(1 2 0 4)) 0)
     (eq? (find-first (lambda (x) (< 2 x)) '(1 2 3 4)) 3)
     (eq? (find-first (lambda (x) (< 9 x)) '(1 2 3)) #f)
     ;; nested: the inner escape lands at the inner call/cc
     (eq? (call/cc (lambda (out)
                     (+ 100 (call/cc (lambda (in) (in 1))))))
          101)
     ;; the outer escape unwinds past the inner call/cc
     (eq? (call/cc (lambda (out)
                     (+ 100 (call/cc (lambda (in) (out 42))))))
          42))
