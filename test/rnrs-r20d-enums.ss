;; expect: #t
;; R6RS names goeteia did not bind (ledger R20, batch R20d):
;; the enumeration types: make-enumeration and the enum-set procedures, and
;; define-enumeration.
;;
;; Each row is an expression and the answer Chez 10 gives for it in (rnrs),
;; compared as a value.  A row that raises here answers `raised'.  An
;; enum-set is compared through enum-set->list, whose order is the
;; universe's.
;;
;; ON THE TREE BEFORE THE CHANGE this file does not compile: the names are
;; unbound.
(import (rnrs))

(define-enumeration color (black white purple maroon) color-set)

(define fails '())
(define (want row got expect)
  (unless (equal? got expect)
    (set! fails (cons (list row 'got got 'want expect) fails))))

(want 1
      (guard (c (#t 'raised))
        (let ((e (make-enumeration '(red green blue)))) (list (enum-set->list e) (enum-set->list (enum-set-universe e)))))
      '((red green blue) (red green blue)))
(want 2
      (guard (c (#t 'raised))
        (enum-set->list (make-enumeration '(a b a c b))))
      '(a b c))
(want 3
      (guard (c (#t 'raised))
        (enum-set->list (make-enumeration '())))
      '())
(want 4
      (guard (c (#t 'raised))
        (let* ((e (make-enumeration '(a b c))) (i (enum-set-indexer e))) (list (i 'a) (i 'b) (i 'c) (i 'z))))
      '(0 1 2 #f))
(want 5
      (guard (c (#t 'raised))
        (let* ((e (make-enumeration '(a b c d))) (c (enum-set-constructor e))) (list (enum-set->list (c '(d b))) (enum-set->list (c '())) (enum-set->list (c '(c c a))) (enum-set->list (enum-set-universe (c '(a)))))))
      '((b d) () (a c) (a b c d)))
(want 6
      (guard (c (#t 'raised))
        (let* ((e (make-enumeration '(a b c d))) (c (enum-set-constructor e))) (guard (x (#t 'raised)) (c '(a z)))))
      'raised)
(want 7
      (guard (c (#t 'raised))
        (let* ((e (make-enumeration '(a b c))) (s ((enum-set-constructor e) '(a c)))) (list (enum-set-member? 'a s) (enum-set-member? 'b s) (enum-set-member? 'z s))))
      '(#t #f #f))
(want 8
      (guard (c (#t 'raised))
        (let* ((e (make-enumeration '(a b c d))) (c (enum-set-constructor e))) (list (enum-set-subset? (c '(a)) (c '(a b))) (enum-set-subset? (c '(a b)) (c '(a))) (enum-set-subset? (c '()) (c '(a))) (enum-set=? (c '(a b)) (c '(b a))) (enum-set=? (c '(a)) (c '(b))))))
      '(#t #f #t #t #f))
(want 9
      (guard (c (#t 'raised))
        (let* ((c1 (enum-set-constructor (make-enumeration '(a b c)))) (c2 (enum-set-constructor (make-enumeration '(a b c d))))) (list (enum-set-subset? (c1 '(a)) (c2 '(a b))) (enum-set-subset? (c2 '(a)) (c1 '(a b))) (enum-set=? (c1 '(a)) (c2 '(a))))))
      '(#t #f #f))
(want 10
      (guard (c (#t 'raised))
        (let* ((c (enum-set-constructor (make-enumeration '(a b c d e))))) (list (enum-set->list (enum-set-union (c '(a c)) (c '(b c)))) (enum-set->list (enum-set-intersection (c '(a b c)) (c '(b c d)))) (enum-set->list (enum-set-difference (c '(a b c)) (c '(b)))) (enum-set->list (enum-set-complement (c '(a e)))))))
      '((a b c) (b c) (a c) (b c d)))
(want 11
      (guard (c (#t 'raised))
        (let* ((c1 (enum-set-constructor (make-enumeration '(a b c)))) (c2 (enum-set-constructor (make-enumeration '(a b c))))) (list (guard (x (#t 'raised)) (enum-set->list (enum-set-union (c1 '(a)) (c2 '(b))))) (guard (x (#t 'raised)) (enum-set->list (enum-set-intersection (c1 '(a)) (c2 '(b))))))))
      '(raised raised))
(want 12
      (guard (c (#t 'raised))
        (let* ((c1 (enum-set-constructor (make-enumeration '(a b c d)))) (c2 (enum-set-constructor (make-enumeration '(d c x))))) (let ((p (enum-set-projection (c1 '(a c d)) (c2 '(x))))) (list (enum-set->list p) (enum-set->list (enum-set-universe p))))))
      '((d c) (d c x)))
(want 13
      (guard (c (#t 'raised))
        (list (color black) (color maroon) (enum-set->list (color-set maroon white)) (enum-set->list (color-set)) (enum-set->list (enum-set-universe (color-set purple))) (enum-set-member? 'purple (color-set purple white))))
      '(black maroon (white maroon) () (black white purple maroon) #t))
(want 14
      (guard (c (#t 'raised))
        (let ((s (color-set black purple))) (list (enum-set-subset? s (enum-set-universe s)) (enum-set->list (enum-set-complement s)))))
      '(#t (white maroon)))

(display (if (null? fails) #t (reverse fails)))
