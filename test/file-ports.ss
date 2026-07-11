;; expect: #t
(define path "/tmp/goeteia-io-test.txt")
(with-output-to-file path
  (lambda ()
    (display "hello ")
    (write '(1 2/3 #\x))
    (newline)
    (display 42)))
(define back
  (call-with-input-file path
    (lambda (p)
      (let* ((a (read p))
             (b (read p))
             (c (read p)))
        (list a b c (eof-object? (read p)))))))
(and (file-exists? path)
     (not (file-exists? "/tmp/goeteia-no-such-file"))
     (equal? back '(hello (1 2/3 #\x) 42 #t))
     ;; char-level reading
     (call-with-input-file path
       (lambda (p)
         (and (char=? (read-char p) #\h)
              (char=? (peek-char p) #\e)))))
