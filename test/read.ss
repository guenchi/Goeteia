;; expect: #t
(let ((x (read)))
  (and (equal? x '(1 (2 3) abc "str" #\a -45 #t (7 . 8)))
       ;; symbols built by read are eq? to compile-time literals
       (eq? (car (cddr x)) 'abc)
       (eq? (string->symbol "abc") 'abc)
       (symbol? (string->symbol "brand-new"))
       (eq? (read) 42)
       (eof-object? (read))))
