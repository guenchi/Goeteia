;; expect: #t
;; a procedure called with the wrong number of arguments raises &assertion
;; (R6RS 5.4; ledger R65, batch M54), on every path a call takes when
;; the callee's arity is not the call's: apply, a call through a
;; variable, a top-level procedure as a value, a primitive as a value,
;; map and for-each -- too many as well as too few.  Calls with the right
;; count still answer.
;;
;; Each row is an expression and the answer Chez 10 gives for it, compared
;; as a value; a row that raises answers `raised'.  A row marked OWN pins
;; goeteia's answer where R6RS leaves the matter open and Chez differs.
;;
;; ON THE TREE BEFORE THE CHANGE (8871123) an extra argument is dropped
;; and the call answers -- (apply (lambda (x) x) (quote (7 8))) is 7 --
;; and a missing one traps, which no handler catches.
(import (rnrs))

(define (g a b) (+ a b))
(define (h a b . rest) rest)
(define (kind thunk)
  (guard (e ((assertion-violation? e) 'assertion) (#t 'other)) (thunk) 'no-condition))

(define fails '())
(define (want row got expect)
  (unless (equal? got expect)
    (set! fails (cons (list row 'got got 'want expect) fails))))

(want 'apply-one
      (guard (c (#t 'raised))
        (apply (lambda (x) x) '(7)))
      '7)
(want 'var-two
      (guard (c (#t 'raised))
        (let ((f (lambda (x y) (+ x y)))) (f 1 2)))
      '3)
(want 'apply-defined
      (guard (c (#t 'raised))
        (apply g '(1 2)))
      '3)
(want 'apply-variadic
      (guard (c (#t 'raised))
        (apply (lambda (x y . r) r) '(1 2 3)))
      '(3))
(want 'apply-defined-variadic
      (guard (c (#t 'raised))
        (apply h '(1 2 3 4)))
      '(3 4))
(want 'map-cons
      (guard (c (#t 'raised))
        (map cons '(1 2) '(3 4)))
      '((1 . 3) (2 . 4)))
(want 'too-many-apply-lambda
      (guard (c (#t 'raised))
        (kind (lambda () (apply (lambda (x) x) '(7 8)))))
      'assertion)
(want 'too-many-var-lambda
      (guard (c (#t 'raised))
        (kind (lambda () (let ((f (lambda (x) x))) (f 7 8)))))
      'assertion)
(want 'too-many-apply-defined
      (guard (c (#t 'raised))
        (kind (lambda () (apply g '(1 2 3)))))
      'assertion)
(want 'too-many-var-defined
      (guard (c (#t 'raised))
        (kind (lambda () (let ((f g)) (f 1 2 3)))))
      'assertion)
(want 'too-many-apply-car
      (guard (c (#t 'raised))
        (kind (lambda () (apply car (list (list 1) 2)))))
      'assertion)
(want 'too-many-apply-cons
      (guard (c (#t 'raised))
        (kind (lambda () (apply cons '(1 2 3)))))
      'assertion)
(want 'too-many-map
      (guard (c (#t 'raised))
        (kind (lambda () (map (lambda (x) x) '(1) '(2)))))
      'assertion)
(want 'too-many-for-each
      (guard (c (#t 'raised))
        (kind (lambda () (for-each (lambda (x) x) '(1) '(2)))))
      'assertion)
(want 'too-few-apply-lambda
      (guard (c (#t 'raised))
        (kind (lambda () (apply (lambda (x y) x) '(7)))))
      'assertion)
(want 'too-few-var-lambda
      (guard (c (#t 'raised))
        (kind (lambda () (let ((f (lambda (x y) x))) (f 7)))))
      'assertion)
(want 'too-few-apply-defined
      (guard (c (#t 'raised))
        (kind (lambda () (apply g '(1)))))
      'assertion)
(want 'too-few-apply-variadic
      (guard (c (#t 'raised))
        (kind (lambda () (apply (lambda (x y . r) r) '(1)))))
      'assertion)
(want 'too-few-apply-defined-variadic
      (guard (c (#t 'raised))
        (kind (lambda () (apply h '(1)))))
      'assertion)
(want 'too-few-apply-cons
      (guard (c (#t 'raised))
        (kind (lambda () (apply cons '(1)))))
      'assertion)
(want 'too-few-map
      (guard (c (#t 'raised))
        (kind (lambda () (map (lambda (x y) x) '(1)))))
      'assertion)
(want 'caught-and-continued
      (guard (c (#t 'raised))
        (list (kind (lambda () (apply (lambda (x) x) '(1 2)))) (apply (lambda (x) x) '(3))))
      '(assertion 3))
(want 'too-many-var-shift-left
      (guard (c (#t 'raised))
        (kind (lambda () (let ((f bitwise-arithmetic-shift-left)) (f 1 2 3)))))
      'assertion)
(want 'too-few-apply-shift-right
      (guard (c (#t 'raised))
        (kind (lambda () (apply bitwise-arithmetic-shift-right '(1)))))
      'assertion)
(want 'too-few-apply-not
      (guard (c (#t 'raised))
        (kind (lambda () (apply not '()))))
      'assertion)
(want 'right-count-var-shift-left
      (guard (c (#t 'raised))
        (let ((f bitwise-arithmetic-shift-left)) (f 1 40)))
      '1099511627776)
(want 'right-count-apply-bitwise-and-none
      (guard (c (#t 'raised))
        (apply bitwise-and '()))
      '-1)

(display (if (null? fails) #t (reverse fails)))
