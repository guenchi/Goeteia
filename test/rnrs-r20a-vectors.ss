;; expect: #t
;; R6RS names goeteia did not bind (ledger R20, batch R20a):
;; vector-sort and vector-sort!.
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
        (list (vector-sort < '#(3 1 2)) (vector-sort < '#()) (vector-sort < '#(1)) (vector-sort > '#(3 1 2)) (vector-sort < '#(2 2 1 1 3 3))))
      '(#(1 2 3) #() #(1) #(3 2 1) #(1 1 2 2 3 3)))
(want 2
      (guard (c (#t 'raised))
        (vector-sort (lambda (a b) (< (car a) (car b))) '#((1 . a) (0 . b) (1 . c) (0 . d) (2 . e) (1 . f) (0 . g))))
      '#((0 . b) (0 . d) (0 . g) (1 . a) (1 . c) (1 . f) (2 . e)))
(want 3
      (guard (c (#t 'raised))
        (let ((v (vector 3 1 2))) (list (vector-sort < v) v)))
      '(#(1 2 3) #(3 1 2)))
(want 4
      (guard (c (#t 'raised))
        (let ((v (vector 3 1 2))) (vector-sort! < v) v))
      '#(1 2 3))
(want 5
      (guard (c (#t 'raised))
        (let ((v (vector 83 86 77 15 93 35 86 92 49 21 62 27 90 59 63 26 40 26 72 36 11 68 67 29 82 30 62 23 67 35 29 2 22 58 69 67 93 56 11 42 29 73 21 19 84 37 98 24 15 70))) (vector-sort! < v) v))
      '#(2 11 11 15 15 19 21 21 22 23 24 26 26 27 29 29 29 30 35 35 36 37 40 42 49 56 58 59 62 62 63 67 67 67 68 69 70 72 73 77 82 83 84 86 86 90 92 93 93 98))
(want 6
      (guard (c (#t 'raised))
        (let ((v (vector))) (vector-sort! < v) v))
      '#())
(want 7
      (guard (c (#t 'raised))
        (vector-sort < (vector 83 86 77 15 93 35 86 92 49 21 62 27 90 59 63 26 40 26 72 36 11 68 67 29 82 30 62 23 67 35 29 2 22 58 69 67 93 56 11 42 29 73 21 19 84 37 98 24 15 70)))
      '#(2 11 11 15 15 19 21 21 22 23 24 26 26 27 29 29 29 30 35 35 36 37 40 42 49 56 58 59 62 62 63 67 67 67 68 69 70 72 73 77 82 83 84 86 86 90 92 93 93 98))

(display (if (null? fails) #t (reverse fails)))
