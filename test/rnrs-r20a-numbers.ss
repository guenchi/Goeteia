;; expect: #t
;; R6RS names goeteia did not bind (ledger R20, batch R20a):
;; the number predicates, rounding, integer square root, the div pairs, boolean=?,
;; symbol=? and the fixnum limits.
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
        (list (positive? 1) (positive? 0) (positive? -1) (positive? 2.5) (positive? -2.5) (positive? (/ 1 2)) (positive? (/ -1 2))))
      '(#t #f #f #t #f #t #f))
(want 2
      (guard (c (#t 'raised))
        (list (negative? 1) (negative? 0) (negative? -1) (negative? 2.5) (negative? -2.5) (negative? (/ -1 2)) (negative? 0.0)))
      '(#f #f #t #f #t #t #f))
(want 3
      (guard (c (#t 'raised))
        (list (positive? (* 65536 65536 65536)) (negative? (* -65536 65536 65536)) (positive? (* -65536 65536 65536))))
      '(#t #t #f))
(want 4
      (guard (c (#t 'raised))
        (list (odd? 1) (odd? 2) (odd? 0) (odd? -1) (odd? -2) (even? 1) (even? 2) (even? 0) (even? -1) (even? -2)))
      '(#t #f #f #t #f #f #t #t #f #t))
(want 5
      (guard (c (#t 'raised))
        (list (odd? 3.0) (even? 3.0) (odd? 4.0) (even? 4.0) (even? -2.0)))
      '(#t #f #f #t #t))
(want 6
      (guard (c (#t 'raised))
        (list (odd? (+ 1 (* 65536 65536 65536))) (even? (+ 1 (* 65536 65536 65536))) (even? (* 65536 65536 65536)) (odd? (- (* 65536 65536 65536)))))
      '(#t #f #t #f))
(want 7
      (guard (c (#t 'raised))
        (list (round 2.5) (round 3.5) (round -2.5) (round -3.5) (round 2.4) (round 2.6) (round -2.4) (round -2.6) (round 0.5) (round 1.5)))
      '(2.0 4.0 -2.0 -4.0 2.0 3.0 -2.0 -3.0 0.0 2.0))
(want 8
      (guard (c (#t 'raised))
        (list (round 7) (round -7) (round (/ 7 2)) (round (/ 5 2)) (round (/ -7 2)) (round (/ -5 2)) (round (/ 7 3)) (round (/ 8 3))))
      '(7 -7 4 2 -4 -2 2 3))
(want 9
      (guard (c (#t 'raised))
        (list (exact? (round (/ 7 2))) (exact? (round 2.5)) (round (* 65536 65536 65536))))
      '(#t #f 281474976710656))
(want 10
      (guard (c (#t 'raised))
        (list (ceiling 2.1) (ceiling 2.0) (ceiling -2.1) (ceiling -2.9) (ceiling 0.5) (ceiling 7) (ceiling (/ 7 2)) (ceiling (/ -7 2)) (ceiling (/ 1 3))))
      '(3.0 2.0 -2.0 -2.0 1.0 7 4 -3 1))
(want 11
      (guard (c (#t 'raised))
        (list (finite? 1.5) (finite? 0) (finite? (/ 1 3)) (finite? (/ 1.0 0.0)) (finite? (/ -1.0 0.0)) (finite? (- (/ 1.0 0.0) (/ 1.0 0.0))) (finite? (* 65536 65536 65536))))
      '(#t #t #t #f #f #f #t))
(want 12
      (guard (c (#t 'raised))
        (list (infinite? 1.5) (infinite? 0) (infinite? (/ 1.0 0.0)) (infinite? (/ -1.0 0.0)) (infinite? (- (/ 1.0 0.0) (/ 1.0 0.0)))))
      '(#f #f #t #t #f))
(want 13
      (guard (c (#t 'raised))
        (list (nan? 1.5) (nan? 0) (nan? (/ 1.0 0.0)) (nan? (- (/ 1.0 0.0) (/ 1.0 0.0))) (nan? (/ 1 3))))
      '(#f #f #f #t #f))
(want 14
      (guard (c (#t 'raised))
        (list (integer-valued? 2.0) (integer-valued? 2.5) (integer-valued? 3) (integer-valued? (/ 1 2)) (integer-valued? (/ 1.0 0.0)) (integer-valued? 'a) (integer-valued? "2")))
      '(#t #f #t #f #f #f #f))
(want 15
      (guard (c (#t 'raised))
        (list (rational-valued? 2.5) (rational-valued? 3) (rational-valued? (/ 1 2)) (rational-valued? (/ 1.0 0.0)) (rational-valued? (- (/ 1.0 0.0) (/ 1.0 0.0))) (rational-valued? 'a)))
      '(#t #t #t #f #f #f))
(want 16
      (guard (c (#t 'raised))
        (list (real-valued? 2.5) (real-valued? 3) (real-valued? (/ 1 2)) (real-valued? (/ 1.0 0.0)) (real-valued? 'a) (real-valued? #t)))
      '(#t #t #t #t #f #f))
(want 17
      (guard (c (#t 'raised))
        (map (lambda (n) (call-with-values (lambda () (exact-integer-sqrt n)) list)) (list 0 1 2 3 4 15 16 17 99 100 1000000 999999)))
      '((0 0) (1 0) (1 1) (1 2) (2 0) (3 6) (4 0) (4 1) (9 18) (10 0) (1000 0) (999 1998)))
(want 18
      (guard (c (#t 'raised))
        (call-with-values (lambda () (exact-integer-sqrt (+ 5 (* 65536 65536 65536 65536)))) list))
      '(4294967296 5))
(want 19
      (guard (c (#t 'raised))
        (call-with-values (lambda () (exact-integer-sqrt (* 3 65536 65536 65536 65536 65536))) list))
      '(1904410002820 3015116166128))
(want 20
      (guard (c (#t 'raised))
        (map (lambda (p) (call-with-values (lambda () (div-and-mod (car p) (cdr p))) list)) '((7 . 2) (-7 . 2) (7 . -2) (-7 . -2) (6 . 3) (0 . 5) (1 . 5) (-1 . 5))))
      '((3 1) (-4 1) (-3 1) (4 1) (2 0) (0 0) (0 1) (-1 4)))
(want 21
      (guard (c (#t 'raised))
        (map (lambda (p) (call-with-values (lambda () (div0-and-mod0 (car p) (cdr p))) list)) '((7 . 2) (-7 . 2) (7 . -2) (-7 . -2) (6 . 3) (0 . 5) (5 . 10) (-5 . 10) (9 . 4) (-9 . 4))))
      '((4 -1) (-3 -1) (-4 -1) (3 -1) (2 0) (0 0) (1 -5) (0 -5) (2 1) (-2 -1)))
;; row 22 is goeteia's answer, not Chez's: goeteia's div family takes exact integers only (docs/limits.md); R6RS and Chez take any real
(want 22
      (guard (c (#t 'raised))
        (call-with-values (lambda () (div-and-mod 7.5 2.0)) list))
      'raised)
;; row 23 is goeteia's answer, not Chez's: goeteia's div family takes exact integers only (docs/limits.md); R6RS and Chez take any real
(want 23
      (guard (c (#t 'raised))
        (call-with-values (lambda () (div-and-mod -7.5 2.0)) list))
      'raised)
;; row 24 is goeteia's answer, not Chez's: goeteia's div family takes exact integers only (docs/limits.md); R6RS and Chez take any real
(want 24
      (guard (c (#t 'raised))
        (call-with-values (lambda () (div0-and-mod0 7.5 2.0)) list))
      'raised)
;; row 25 is goeteia's answer, not Chez's: goeteia's div family takes exact integers only (docs/limits.md); R6RS and Chez take any real
(want 25
      (guard (c (#t 'raised))
        (call-with-values (lambda () (div-and-mod (/ 7 2) 2)) list))
      'raised)
(want 26
      (guard (c (#t 'raised))
        (list (boolean=? #t #t) (boolean=? #f #f) (boolean=? #t #f) (boolean=? #f #t) (boolean=? #t #t #t) (boolean=? #f #f #t) (boolean=? #f #f #f)))
      '(#t #t #f #f #t #f #t))
(want 27
      (guard (c (#t 'raised))
        (list (symbol=? 'a 'a) (symbol=? 'a 'b) (symbol=? 'a 'a 'a) (symbol=? 'a 'a 'b) (symbol=? 'abc (string->symbol "abc"))))
      '(#t #f #t #f #t))
(want 28
      (guard (c (#t 'raised))
        (list (fixnum? (greatest-fixnum)) (fixnum? (least-fixnum)) (fixnum? (+ (greatest-fixnum) 1)) (fixnum? (- (least-fixnum) 1))))
      '(#t #t #f #f))
(want 29
      (guard (c (#t 'raised))
        (list (= (least-fixnum) (- (- (greatest-fixnum)) 1)) (exact? (fixnum-width)) (> (fixnum-width) 8)))
      '(#t #t #t))
(want 30
      (guard (c (#t 'raised))
        (let loop ((i 1) (p 2)) (if (= i (- (fixnum-width) 1)) (= (greatest-fixnum) (- p 1)) (loop (+ i 1) (* p 2)))))
      '#t)

(display (if (null? fails) #t (reverse fails)))
