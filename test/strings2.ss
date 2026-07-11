;; expect: #t
(let ((s (list->string '(#\h #\e #\y))))
  (and (string=? s "hey")
       (equal? (string->list "ab") '(#\a #\b))
       (let ((m (%make-string 2)))
         (string-set! m 0 #\o)
         (string-set! m 1 #\k)
         (string=? m "ok"))))
