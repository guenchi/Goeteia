;; expect: #t
;; R6RS names goeteia did not bind (ledger R20, batch R20b):
;; open-string-output-port, call-with-string-output-port and
;; open-string-input-port.
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
        (call-with-string-output-port (lambda (p) (write 'abc p) (display " " p) (write "x" p) (display 42 p))))
      '"abc \"x\"42")
(want 2
      (guard (c (#t 'raised))
        (call-with-string-output-port (lambda (p) 'nothing)))
      '"")
(want 3
      (guard (c (#t 'raised))
        (call-with-values open-string-output-port (lambda (p get) (display "ab" p) (let ((a (get))) (display "cd" p) (let ((b (get))) (list a b (get)))))))
      '("ab" "cd" ""))
(want 4
      (guard (c (#t 'raised))
        (let ((p (open-string-input-port "ab"))) (let* ((a (read-char p)) (b (peek-char p)) (c (read-char p))) (list a b c (eof-object? (read-char p))))))
      '(#\a #\b #\b #t))
(want 5
      (guard (c (#t 'raised))
        (let ((p (open-string-input-port ""))) (eof-object? (peek-char p))))
      '#t)

(display (if (null? fails) #t (reverse fails)))
