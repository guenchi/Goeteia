;; expect: 42
(define (f a b)
  (begin
    (+ a b)
    (let ((x (* a b)) (y 2))
      (+ x y))))
(f 5 8)
