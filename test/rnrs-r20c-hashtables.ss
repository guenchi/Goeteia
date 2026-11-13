;; expect: #t
;; R6RS names goeteia did not bind (ledger R20, batch R20c):
;; hashtable-copy (immutable unless asked), hashtable-mutable?,
;; hashtable-clear!, hashtable-entries, the equivalence and hash functions, symbol-hash and
;; string-ci-hash.
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
        (let ((h (make-eqv-hashtable))) (hashtable-set! h 1 'one) (hashtable-set! h 2 'two) (let ((c (hashtable-copy h))) (list (hashtable-ref c 1 #f) (hashtable-size c) (hashtable-mutable? c) (hashtable-mutable? h) (guard (e (#t 'raised)) (hashtable-set! c 3 'three) 'set)))))
      '(one 2 #f #t raised))
(want 2
      (guard (c (#t 'raised))
        (let ((h (make-eqv-hashtable))) (hashtable-set! h 1 'one) (let ((c (hashtable-copy h #t))) (hashtable-set! c 3 'three) (list (hashtable-mutable? c) (hashtable-size c) (hashtable-size h) (hashtable-ref h 3 'absent)))))
      '(#t 2 1 absent))
(want 3
      (guard (c (#t 'raised))
        (let ((h (make-eqv-hashtable))) (hashtable-set! h 1 'one) (let ((c (hashtable-copy h))) (list (guard (e (#t 'raised)) (hashtable-delete! c 1) 'deleted) (guard (e (#t 'raised)) (hashtable-update! c 1 (lambda (v) v) 0) 'updated) (guard (e (#t 'raised)) (hashtable-clear! c) 'cleared) (hashtable-size c)))))
      '(raised raised raised 1))
(want 4
      (guard (c (#t 'raised))
        (let ((h (make-eq-hashtable))) (hashtable-set! h 'a 1) (hashtable-set! h 'b 2) (hashtable-clear! h) (list (hashtable-size h) (hashtable-ref h 'a 'gone) (begin (hashtable-set! h 'c 3) (hashtable-ref h 'c #f)))))
      '(0 gone 3))
(want 5
      (guard (c (#t 'raised))
        (let ((h (make-hashtable equal-hash equal?))) (hashtable-set! h "x" 1) (hashtable-clear! h 32) (list (hashtable-size h) (hashtable-contains? h "x"))))
      '(0 #f))
(want 6
      (guard (c (#t 'raised))
        (let ((h (make-eqv-hashtable))) (hashtable-set! h 3 'c) (hashtable-set! h 1 'a) (hashtable-set! h 2 'b) (call-with-values (lambda () (hashtable-entries h)) (lambda (ks vs) (list-sort (lambda (x y) (< (car x) (car y))) (map cons (vector->list ks) (vector->list vs)))))))
      '((1 . a) (2 . b) (3 . c)))
(want 7
      (guard (c (#t 'raised))
        (call-with-values (lambda () (hashtable-entries (make-eq-hashtable))) (lambda (ks vs) (list ks vs))))
      '(#() #()))
(want 8
      (guard (c (#t 'raised))
        (let ((e (make-eq-hashtable)) (v (make-eqv-hashtable)) (s (make-hashtable string-hash string=?))) (list (eq? (hashtable-equivalence-function e) eq?) (eq? (hashtable-equivalence-function v) eqv?) (eq? (hashtable-equivalence-function s) string=?) (hashtable-hash-function e) (hashtable-hash-function v) (eq? (hashtable-hash-function s) string-hash))))
      '(#t #t #t #f #f #t))
(want 9
      (guard (c (#t 'raised))
        (list (integer? (symbol-hash 'abc)) (= (symbol-hash 'abc) (symbol-hash (string->symbol "abc"))) (integer? (string-ci-hash "Hello")) (= (string-ci-hash "HeLLo") (string-ci-hash "hello"))))
      '(#t #t #t #t))

(display (if (null? fails) #t (reverse fails)))
