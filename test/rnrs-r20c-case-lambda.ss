;; expect: #t
;; R6RS names goeteia did not bind (ledger R20, batch R20c):
;; case-lambda: the first clause whose formals take the arguments runs; no
;; clause, and the call raises.
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
        (let ((f (case-lambda ((x) (list 'one x)) ((x y) (list 'two x y)) ((x . r) (list 'many x r))))) (list (f 1) (f 1 2) (f 1 2 3) (f 1 2 3 4))))
      '((one 1) (two 1 2) (many 1 (2 3)) (many 1 (2 3 4))))
(want 2
      (guard (c (#t 'raised))
        (let ((f (case-lambda (() 'none) ((a) (list 'a a)) (r (list 'rest r))))) (list (f) (f 1) (f 1 2) (f 1 2 3))))
      '(none (a 1) (rest (1 2)) (rest (1 2 3))))
(want 3
      (guard (c (#t 'raised))
        (let ((f (case-lambda ((a . r) (list 'first a r)) ((a b) (list 'never a b))))) (list (f 1) (f 1 2))))
      '((first 1 ()) (first 1 (2))))
(want 4
      (guard (c (#t 'raised))
        (let ((f (case-lambda ((a) a) ((a b) (+ a b))))) (guard (c (#t 'raised)) (f 1 2 3))))
      'raised)
(want 5
      (guard (c (#t 'raised))
        (let ((f (case-lambda ((a) a)))) (guard (c (#t 'raised)) (f))))
      'raised)
(want 6
      (guard (c (#t 'raised))
        (let ((f (case-lambda (r (length r))))) (list (f) (f 1 2 3))))
      '(0 3))
(want 7
      (guard (c (#t 'raised))
        (letrec ((count (case-lambda ((n) (count n 0)) ((n acc) (if (= n 0) acc (count (- n 1) (+ acc 1))))))) (count 100000)))
      '100000)
(want 8
      (guard (c (#t 'raised))
        (let ((f (case-lambda ((x) (define y (* x 2)) (+ x y)) ((x y) (let ((z 1)) (+ x y z)))))) (list (f 3) (f 3 4))))
      '(9 8))
(want 9
      (guard (c (#t 'raised))
        (let ((f (case-lambda ((x) x)))) (list (procedure? f) (map f '(1 2 3)) (apply f '(9)))))
      '(#t (1 2 3) 9))
(want 10
      (guard (c (#t 'raised))
        (let ((mk (lambda (k) (case-lambda (() k) ((a) (+ a k)))))) (let ((g (mk 10))) (list (g) (g 5)))))
      '(10 15))

(display (if (null? fails) #t (reverse fails)))
