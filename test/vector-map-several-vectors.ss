;; expect: #t
;; vector-map, vector-for-each and string-for-each take one or more
;; vectors or strings, which must all have the same length (R6RS 11.13,
;; 11.12; ledger R82).
;;
;; Each row is an expression and the answer Chez 10 gives for it, compared
;; as a value; a row that raises answers `raised'.  A row marked OWN pins
;; goeteia's answer where R6RS leaves the matter open and Chez differs.
;;
;; Each `site' row answers (kind error? violation? i/o-read? message?
;; irritants?) for what the expression raises.
;;
;; ON THE TREE BEFORE THE CHANGE the program stops on the first fixnum
;; division by zero, uncaught, or does not compile (vector-map takes one
;; vector).
(import (rnrs))

(define (caught thunk)
  (guard (c (#t (if (assertion-violation? c) 'assertion 'other))) (thunk)))

(define fails '())
(define (want row got expect)
  (unless (equal? got expect)
    (set! fails (cons (list row 'got got 'want expect) fails))))

(want 'vector-map-one
      (guard (c (#t 'raised))
        (vector-map (lambda (x) (* x x)) '#(1 2 3)))
      '#(1 4 9))
(want 'vector-map-two
      (guard (c (#t 'raised))
        (vector-map + '#(1 2 3) '#(10 20 30)))
      '#(11 22 33))
(want 'vector-map-three
      (guard (c (#t 'raised))
        (vector-map list '#(a b) '#(1 2) '#("x" "y")))
      '#((a 1 "x") (b 2 "y")))
(want 'vector-map-empty
      (guard (c (#t 'raised))
        (list (vector-map + '#() '#()) (vector-map list '#())))
      '(#() #()))
(want 'vector-for-each-order
      (guard (c (#t 'raised))
        (let ((acc '())) (vector-for-each (lambda (a b) (set! acc (cons (list a b) acc))) '#(1 2 3) '#(x y z)) (reverse acc)))
      '((1 x) (2 y) (3 z)))
(want 'string-for-each-two
      (guard (c (#t 'raised))
        (let ((acc '())) (string-for-each (lambda (a b) (set! acc (cons (string a b) acc))) "abc" "xyz") (reverse acc)))
      '("ax" "by" "cz"))
(want 'string-for-each-one
      (guard (c (#t 'raised))
        (let ((n 0)) (string-for-each (lambda (c) (set! n (+ n 1))) "hello") n))
      '5)
(want 'unequal-vectors
      (guard (c (#t 'raised))
        (list (caught (lambda () (vector-map + '#(1 2) '#(1 2 3)))) (caught (lambda () (vector-for-each + '#(1) '#())))))
      '(assertion assertion))
(want 'unequal-strings
      (guard (c (#t 'raised))
        (caught (lambda () (string-for-each (lambda (a b) a) "ab" "a"))))
      'assertion)
(want 'the-results-are-fresh
      (guard (c (#t 'raised))
        (let* ((v '#(1 2)) (w (vector-map + v v))) (list w (eq? w v) (vector-length w))))
      '(#(2 4) #f 2))

(display (if (null? fails) #t (reverse fails)))
