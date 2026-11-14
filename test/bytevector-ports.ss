;; expect: #t
;; binary ports over bytevectors (R6RS 8.2): open-bytevector-input-port,
;; open-bytevector-output-port and call-with-bytevector-output-port, and
;; get-u8, lookahead-u8, the four get-bytevector procedures, put-u8 and
;; put-bytevector on them; what the port predicates answer; what is
;; refused (ledger R20).
;;
;; Each row is an expression and the answer Chez 10 gives for it, compared
;; as a value; a row that raises answers `raised'.  A row marked OWN pins
;; goeteia's answer where R6RS leaves the matter open and Chez differs.
;;
;; Each `site' row answers (kind error? violation? i/o-read? message?
;; irritants?) for what the expression raises.
;;
;; ON THE TREE BEFORE THE CHANGE this file does not compile: the names are
;; unbound.
(import (rnrs))

(define (caught thunk)
  (guard (c (#t (if (assertion-violation? c) 'assertion 'other))) (thunk)))
(define (in . bytes) (open-bytevector-input-port (u8-list->bytevector bytes)))
(define (bv . bytes) (u8-list->bytevector bytes))
;; what a read answers, written without the printer: eof as the symbol eof,
;; a bytevector as its list of bytes
(define (e x) (cond ((eof-object? x) 'eof) ((bytevector? x) (bytevector->u8-list x)) (else x)))
(define (out) (let-values (((p get) (open-bytevector-output-port))) p))

(define fails '())
(define (want row got expect)
  (unless (equal? got expect)
    (set! fails (cons (list row 'got got 'want expect) fails))))

(want 'get-u8-to-the-end
      (guard (c (#t 'raised))
        (let ((p (in 1 2 3))) (list (e (get-u8 p)) (e (get-u8 p)) (e (get-u8 p)) (e (get-u8 p)) (e (get-u8 p)))))
      '(1 2 3 eof eof))
(want 'lookahead-u8-does-not-move
      (guard (c (#t 'raised))
        (let ((p (in 7 8))) (list (e (lookahead-u8 p)) (e (lookahead-u8 p)) (e (get-u8 p)) (e (lookahead-u8 p)) (e (get-u8 p)) (e (lookahead-u8 p)))))
      '(7 7 7 8 8 eof))
(want 'get-bytevector-n
      (guard (c (#t 'raised))
        (let ((p (in 1 2 3 4 5))) (list (e (get-bytevector-n p 2)) (e (get-bytevector-n p 0)) (e (get-bytevector-n p 10)) (e (get-bytevector-n p 1)))))
      '((1 2) () (3 4 5) eof))
(want 'get-bytevector-n-bang
      (guard (c (#t 'raised))
        (let ((p (in 9 8 7)) (b (make-bytevector 5 0))) (list (e (get-bytevector-n! p b 1 2)) (e b) (e (get-bytevector-n! p b 0 5)) (e b) (e (get-bytevector-n! p b 0 1)))))
      '(2 (0 9 8 0 0) 1 (7 9 8 0 0) eof))
(want 'get-bytevector-some
      (guard (c (#t 'raised))
        (let ((p (in 1 2 3))) (list (e (get-bytevector-some p)) (e (get-bytevector-some p)))))
      '((1 2 3) eof))
(want 'get-bytevector-all
      (guard (c (#t 'raised))
        (list (e (get-bytevector-all (in 1 2))) (e (get-bytevector-all (in))) (let ((p (in 1 2 3))) (get-u8 p) (list (e (get-bytevector-all p)) (e (get-bytevector-all p))))))
      '((1 2) eof ((2 3) eof)))
(want 'port-eof
      (guard (c (#t 'raised))
        (let ((p (in 1))) (list (port-eof? p) (e (get-u8 p)) (port-eof? p) (port-eof? (in)))))
      '(#f 1 #t #t))
(want 'input-predicates
      (guard (c (#t 'raised))
        (let ((p (in 1))) (list (port? p) (input-port? p) (output-port? p) (binary-port? p) (textual-port? p))))
      '(#t #t #f #t #f))
(want 'output-predicates
      (guard (c (#t 'raised))
        (let ((p (out))) (list (port? p) (input-port? p) (output-port? p) (binary-port? p) (textual-port? p))))
      '(#t #f #t #t #f))
(want 'put-and-extract
      (guard (c (#t 'raised))
        (let-values (((p get) (open-bytevector-output-port))) (put-u8 p 1) (put-bytevector p (bv 2 3 4)) (put-bytevector p (bv 5 6 7 8) 1) (put-bytevector p (bv 9 10 11 12) 1 2) (let ((first (e (get)))) (put-u8 p 99) (list first (e (get)) (e (get))))))
      '((1 2 3 4 6 7 8 10 11) (99) ()))
(want 'call-with-bytevector-output-port
      (guard (c (#t 'raised))
        (e (call-with-bytevector-output-port (lambda (p) (put-u8 p 65) (put-bytevector p (bv 66 67))))))
      '(65 66 67))
(want 'an-empty-output
      (guard (c (#t 'raised))
        (let-values (((p get) (open-bytevector-output-port))) (e (get))))
      '())
(want 'put-u8-out-of-range
      (guard (c (#t 'raised))
        (list (caught (lambda () (put-u8 (out) 256))) (caught (lambda () (put-u8 (out) -1))) (caught (lambda () (put-u8 (out) 'a)))))
      '(assertion assertion assertion))
(want 'put-bytevector-bad-range
      (guard (c (#t 'raised))
        (list (caught (lambda () (put-bytevector (out) (bv 1 2 3) 2 5))) (caught (lambda () (put-bytevector (out) (bv 1 2 3) 4)))))
      '(assertion assertion))
(want 'get-on-a-textual-port
      (guard (c (#t 'raised))
        (list (caught (lambda () (get-u8 (open-string-input-port "a")))) (caught (lambda () (lookahead-u8 (open-string-input-port "a"))))))
      '(assertion assertion))
(want 'textual-get-on-a-binary-port
      (guard (c (#t 'raised))
        (list (caught (lambda () (get-char (in 65)))) (caught (lambda () (get-line (in 65 10))))))
      '(assertion assertion))
(want 'put-on-an-input-port
      (guard (c (#t 'raised))
        (caught (lambda () (put-u8 (in 1) 2))))
      'assertion)
(want 'bad-counts
      (guard (c (#t 'raised))
        (list (caught (lambda () (get-bytevector-n (in 1) -1))) (caught (lambda () (get-bytevector-n! (in 1 2) (make-bytevector 2 0) 1 2)))))
      '(assertion assertion))
(want 'a-closed-port
      (guard (c (#t 'raised))
        (let ((p (in 1 2))) (close-port p) (caught (lambda () (get-u8 p)))))
      'assertion)
(want 'a-non-bytevector
      (guard (c (#t 'raised))
        (caught (lambda () (open-bytevector-input-port "abc"))))
      'assertion)

(display (if (null? fails) #t (reverse fails)))
