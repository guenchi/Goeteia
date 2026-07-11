;; expect: #t
;; named character literals read identically on both hosts; #\return
;; once silently read as #\r in the self-hosted reader
(and (= (char->integer #\return) 13)
     (= (char->integer #\newline) 10)
     (= (char->integer #\tab) 9)
     (= (char->integer #\space) 32)
     (= (char->integer #\nul) 0)
     (= (char->integer #\delete) 127)
     (char=? #\r (string-ref "return" 0))    ; single chars still work
     (not (char=? #\return #\r)))
