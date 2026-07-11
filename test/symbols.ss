;; expect: #t
(and (symbol? 'foo)
     (eq? 'foo 'foo)
     (not (eq? 'foo 'bar))
     (not (symbol? "foo"))
     (eq? (car '(a b)) 'a))
