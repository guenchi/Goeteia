;; expect: #t
;; R6RS names goeteia did not bind (ledger R20, batch R20c):
;; the textual port procedures over string ports: get-char, lookahead-char,
;; get-line, get-string-n(!), get-string-all, get-datum, put-char, put-string,
;; put-datum, flush-output-port, port-eof?, textual-port?, binary-port?,
;; call-with-port.
;;
;; Each row is an expression and the answer Chez 10 gives for it in (rnrs),
;; compared as a value.  A row that raises here answers `raised'.  A row
;; with a comment above it pins goeteia's own answer where its domain is
;; narrower than R6RS's.
;;
;; ON THE TREE BEFORE THE CHANGE this file does not compile: the names are
;; unbound.
(import (rnrs))

(define fails '())
(define (want row got expect)
  (unless (equal? got expect)
    (set! fails (cons (list row 'got got 'want expect) fails))))

(want 1
      (guard (c (#t 'raised))
        (let ((p (open-string-input-port "ab"))) (let* ((a (get-char p)) (b (lookahead-char p)) (c (get-char p))) (list a b c (eof-object? (get-char p)) (eof-object? (lookahead-char p))))))
      '(#\a #\b #\b #t #t))
(want 2
      (guard (c (#t 'raised))
        (let ((p (open-string-input-port "ab\ncd\n\nef"))) (let* ((a (get-line p)) (b (get-line p)) (c (get-line p)) (d (get-line p))) (list a b c d (eof-object? (get-line p))))))
      '("ab" "cd" "" "ef" #t))
(want 3
      (guard (c (#t 'raised))
        (let ((p (open-string-input-port "abcdef"))) (let* ((a (get-string-n p 3)) (b (get-string-n p 10)) (c (get-string-n p 2))) (list a b (eof-object? c)))))
      '("abc" "def" #t))
(want 4
      (guard (c (#t 'raised))
        (let ((p (open-string-input-port "abcdef")) (s (make-string 6 #\-))) (let* ((n (get-string-n! p s 1 3)) (m (get-string-n! p s 4 2))) (list n m s))))
      '(3 2 "-abcde"))
(want 5
      (guard (c (#t 'raised))
        (let ((p (open-string-input-port "xyz"))) (let* ((a (get-string-all p)) (b (get-string-all p))) (list a (eof-object? b)))))
      '("xyz" #t))
(want 6
      (guard (c (#t 'raised))
        (let ((p (open-string-input-port ""))) (list (eof-object? (get-string-all p)) (eof-object? (get-char p)) (port-eof? p))))
      '(#t #t #t))
(want 7
      (guard (c (#t 'raised))
        (let ((p (open-string-input-port "a"))) (let* ((x (port-eof? p)) (c (get-char p)) (y (port-eof? p))) (list x c y))))
      '(#f #\a #t))
(want 8
      (guard (c (#t 'raised))
        (let ((p (open-string-input-port "(1 2) foo \"bar\" #(3)"))) (let* ((a (get-datum p)) (b (get-datum p)) (c (get-datum p)) (d (get-datum p))) (list a b c d (eof-object? (get-datum p))))))
      '((1 2) foo "bar" #(3) #t))
(want 9
      (guard (c (#t 'raised))
        (call-with-string-output-port (lambda (p) (put-char p #\a) (put-string p "bcd") (put-string p "efgh" 1) (put-string p "ijklm" 1 2) (put-datum p '(1 "x" #\y)) (flush-output-port p))))
      '"abcdfghjk(1 \"x\" #\\y)")
(want 10
      (guard (c (#t 'raised))
        (let ((p (open-string-input-port "x"))) (call-with-values open-string-output-port (lambda (q get) (list (textual-port? p) (textual-port? q) (binary-port? p) (binary-port? q))))))
      '(#t #t #f #f))
(want 11
      (guard (c (#t 'raised))
        (let ((p (open-string-input-port "hello"))) (call-with-port p (lambda (q) (list (eq? p q) (get-string-n q 2))))))
      '(#t "he"))
(want 12
      (guard (c (#t 'raised))
        (call-with-values (lambda () (call-with-port (open-string-input-port "ab") (lambda (q) (let* ((a (get-char q)) (b (get-char q))) (values a b 'third))))) list))
      '(#\a #\b third))

(display (if (null? fails) #t (reverse fails)))
