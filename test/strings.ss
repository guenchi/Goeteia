;; expect: #t
(and (= (string-length "hello") 5)
     (eq? (string-ref "abc" 1) #\b)
     (string=? "foo" "foo")
     (not (string=? "foo" "bar"))
     (string=? (symbol->string 'abc) "abc"))
