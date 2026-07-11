;; expect: #t
;; string-literal escapes: \n \t \r become control chars; \" \\ literal
(and (= (string-length "a\nb") 3)
     (= (char->integer (string-ref "a\nb" 1)) 10)
     (= (char->integer (string-ref "x\ty" 1)) 9)
     (= (char->integer (string-ref "x\ry" 1)) 13)
     (string=? "q\"q" (string #\q #\" #\q))
     (string=? "b\\b" (string #\b #\\ #\b))
     (string=? (string-append "a" "\n" "b")
               (string #\a #\newline #\b)))
