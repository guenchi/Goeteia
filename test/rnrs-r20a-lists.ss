;; expect: #t
;; R6RS names goeteia did not bind (ledger R20, batch R20a):
;; exists, for-all, find, memp, assp, remp, remove, remv, partition, list-sort and the
;; three- and four-level accessors.
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
        (list (exists even? '(1 3 4)) (exists even? '(1 3 5)) (exists even? '()) (exists (lambda (x) (and (> x 2) x)) '(1 2 3 4))))
      '(#t #f #f 3))
(want 2
      (guard (c (#t 'raised))
        (list (exists < '(1 2) '(2 1)) (exists > '(1 2) '(2 3)) (exists (lambda (a b c) (and (= (+ a b) c) (list a b c))) '(1 2 3) '(1 2 3) '(3 4 7))))
      '(#t #f (2 2 4)))
(want 3
      (guard (c (#t 'raised))
        (let ((seen '())) (exists (lambda (x) (set! seen (cons x seen)) (even? x)) '(1 2 3 4)) (reverse seen)))
      '(1 2))
(want 4
      (guard (c (#t 'raised))
        (list (for-all even? '(2 4)) (for-all even? '(2 3 4)) (for-all even? '()) (for-all (lambda (x) (and (even? x) x)) '(2 4 6))))
      '(#t #f #t 6))
(want 5
      (guard (c (#t 'raised))
        (list (for-all < '(1 2) '(2 3)) (for-all < '(1 5) '(2 3)) (for-all (lambda (a b) (+ a b)) '(1 2) '(10 20))))
      '(#t #f 22))
(want 6
      (guard (c (#t 'raised))
        (let ((seen '())) (for-all (lambda (x) (set! seen (cons x seen)) (even? x)) '(2 3 4 6)) (reverse seen)))
      '(2 3))
(want 7
      (guard (c (#t 'raised))
        (list (find even? '(1 3 4 5 6)) (find even? '(1 3)) (find even? '()) (find (lambda (x) (eq? x #f)) '(1 #f 2))))
      '(4 #f #f #f))
(want 8
      (guard (c (#t 'raised))
        (list (memp even? '(1 3 4 5)) (memp even? '(1)) (memp even? '()) (memp odd? '(1 2))))
      '((4 5) #f #f (1 2)))
(want 9
      (guard (c (#t 'raised))
        (list (assp even? '((1 . a) (2 . b) (4 . c))) (assp even? '((1 . a))) (assp even? '())))
      '((2 . b) #f #f))
(want 10
      (guard (c (#t 'raised))
        (list (remp even? '(1 2 3 4)) (remp even? '()) (remp even? '(2 4)) (remp odd? '(2 4))))
      '((1 3) () () (2 4)))
(want 11
      (guard (c (#t 'raised))
        (list (remove 2 '(1 2 3 2)) (remove '(a) '((a) (b) (a))) (remove "x" '("x" "y")) (remove 9 '(1 2))))
      '((1 3) ((b)) ("y") (1 2)))
(want 12
      (guard (c (#t 'raised))
        (list (remv 2 '(1 2 3 2)) (remv 2.5 '(1 2.5 3)) (remv #\a '(#\a #\b)) (remv 'x '())))
      '((1 3) (1 3) (#\b) ()))
(want 13
      (guard (c (#t 'raised))
        (call-with-values (lambda () (partition even? '(1 2 3 4 5))) list))
      '((2 4) (1 3 5)))
(want 14
      (guard (c (#t 'raised))
        (call-with-values (lambda () (partition even? '())) list))
      '(() ()))
(want 15
      (guard (c (#t 'raised))
        (call-with-values (lambda () (partition symbol? '(a 1 b 2 c))) list))
      '((a b c) (1 2)))
(want 16
      (guard (c (#t 'raised))
        (list (list-sort < '(3 1 2)) (list-sort < '()) (list-sort < '(1)) (list-sort > '(3 1 2)) (list-sort < '(2 2 1 1 3 3))))
      '((1 2 3) () (1) (3 2 1) (1 1 2 2 3 3)))
(want 17
      (guard (c (#t 'raised))
        (list-sort (lambda (a b) (< (car a) (car b))) '((1 . a) (0 . b) (1 . c) (0 . d) (2 . e) (1 . f) (0 . g))))
      '((0 . b) (0 . d) (0 . g) (1 . a) (1 . c) (1 . f) (2 . e)))
(want 18
      (guard (c (#t 'raised))
        (list-sort < '(83 86 77 15 93 35 86 92 49 21 62 27 90 59 63 26 40 26 72 36 11 68 67 29 82 30 62 23 67 35 29 2 22 58 69 67 93 56 11 42 29 73 21 19 84 37 98 24 15 70)))
      '(2 11 11 15 15 19 21 21 22 23 24 26 26 27 29 29 29 30 35 35 36 37 40 42 49 56 58 59 62 62 63 67 67 67 68 69 70 72 73 77 82 83 84 86 86 90 92 93 93 98))
(want 19
      (guard (c (#t 'raised))
        (let ((l (list 3 1 2))) (list (list-sort < l) l)))
      '((1 2 3) (3 1 2)))
(want 20
      (guard (c (#t 'raised))
        (let ((t '((((1 . 2) . (3 . 4)) . ((5 . 6) . (7 . 8))) . (((9 . 10) . (11 . 12)) . ((13 . 14) . (15 . 16)))))) (list (caaar t) (caadr t) (cadar t) (cdaar t) (cdadr t) (cddar t))))
      '((1 . 2) (9 . 10) (5 . 6) (3 . 4) (11 . 12) (7 . 8)))
(want 21
      (guard (c (#t 'raised))
        (let ((t '((((1 . 2) . (3 . 4)) . ((5 . 6) . (7 . 8))) . (((9 . 10) . (11 . 12)) . ((13 . 14) . (15 . 16)))))) (list (caaaar t) (caaadr t) (caadar t) (caaddr t) (cadaar t) (cadadr t) (caddar t))))
      '(1 9 5 13 3 11 7))
(want 22
      (guard (c (#t 'raised))
        (let ((t '((((1 . 2) . (3 . 4)) . ((5 . 6) . (7 . 8))) . (((9 . 10) . (11 . 12)) . ((13 . 14) . (15 . 16)))))) (list (cdaaar t) (cdaadr t) (cdadar t) (cdaddr t) (cddaar t) (cddadr t) (cdddar t) (cddddr t))))
      '(2 10 6 14 4 12 8 16))

(display (if (null? fails) #t (reverse fails)))
