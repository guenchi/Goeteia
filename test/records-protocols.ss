;; expect: #t
;; the protocol clause: the constructor is what the protocol makes of `new';
;; a child's protocol receives a procedure that takes the parent's
;; constructor arguments and answers one taking the child's fields.
;;
;; Each row is an expression and the answer Chez 10 gives for it, compared
;; as a value; a row that raises answers `raised'.  A row marked OWN pins
;; goeteia's answer where R6RS leaves the matter open and Chez differs.
;;
;; ON THE TREE BEFORE THE CHANGE this file does not compile, or its rows are
;; red: every clause but `fields' was ignored.
(import (rnrs))

(define evals 0)
(define-record-type counter (fields (mutable n))
  (protocol (begin (set! evals (+ evals 1)) (lambda (new) (lambda () (new 0))))))
(define-record-type point (fields x y))
(define-record-type cpoint (parent point) (fields colour)
  (protocol (lambda (n) (lambda (x y c) ((n x y) (list 'rgb c))))))
(define-record-type cpoint+ (parent cpoint) (fields extra)
  (protocol (lambda (n) (lambda (x y c e) ((n x y c) (* 2 e))))))
(define-record-type origin (fields x y) (protocol (lambda (new) (lambda () (new 0 0)))))
(define-record-type labelled (parent origin) (fields label)
  (protocol (lambda (n) (lambda (l) ((n) l)))))
;; a protocol whose constructor takes any number of arguments
(define-record-type bag (fields items) (protocol (lambda (new) (lambda items (new items)))))
;; a protocol that keeps `new' and makes two records
(define-record-type twin (fields a)
  (protocol (lambda (new) (lambda (a) (cons (new a) (new (+ a 1)))))))
;; a protocol that reads a variable of the program
(define default-size 12)
(define-record-type box (fields size) (protocol (lambda (new) (lambda () (new default-size)))))
;; wrong counts handed to new, to n and to p
(define-record-type short (fields a b) (protocol (lambda (new) (lambda (a) (new a)))))
(define-record-type long (fields a) (protocol (lambda (new) (lambda (a) (new a a)))))
(define-record-type badn (parent point) (fields c)
  (protocol (lambda (n) (lambda (x) ((n x) 1)))))
(define-record-type badp (parent point) (fields c)
  (protocol (lambda (n) (lambda (x y) ((n x y) 1 2)))))

(define fails '())
(define (want row got expect)
  (unless (equal? got expect)
    (set! fails (cons (list row 'got got 'want expect) fails))))

(want 'at-the-root
      (guard (c (#t 'raised))
        (let ((c (make-counter))) (list (counter? c) (counter-n c))))
      '(#t 0))
(want 'expression-evaluated-once
      (guard (c (#t 'raised))
        (begin (make-counter) (make-counter) (make-counter) evals))
      '1)
(want 'child-over-a-plain-parent
      (guard (c (#t 'raised))
        (let ((p (make-cpoint 1 2 'red))) (list (point? p) (cpoint? p) (point-x p) (point-y p) (cpoint-colour p))))
      '(#t #t 1 2 (rgb red)))
(want 'three-levels
      (guard (c (#t 'raised))
        (let ((p (make-cpoint+ 1 2 'blue 21))) (list (point? p) (cpoint? p) (cpoint+? p) (point-x p) (point-y p) (cpoint-colour p) (cpoint+-extra p))))
      '(#t #t #t 1 2 (rgb blue) 42))
(want 'child-over-a-parent-with-one
      (guard (c (#t 'raised))
        (let ((l (make-labelled 'here))) (list (origin? l) (labelled? l) (origin-x l) (origin-y l) (labelled-label l))))
      '(#t #t 0 0 here))
(want 'any-number-of-arguments
      (guard (c (#t 'raised))
        (list (bag-items (make-bag 1 2 3)) (bag-items (make-bag))))
      '((1 2 3) ()))
(want 'new-used-twice
      (guard (c (#t 'raised))
        (let ((t (make-twin 5))) (list (twin? (car t)) (twin-a (car t)) (twin-a (cdr t)) (eq? (car t) (cdr t)))))
      '(#t 5 6 #f))
(want 'reads-a-variable
      (guard (c (#t 'raised))
        (box-size (make-box)))
      '12)
(want 'mutators-still-work
      (guard (c (#t 'raised))
        (let ((c (make-counter))) (counter-n-set! c 41) (counter-n-set! c (+ 1 (counter-n c))) (counter-n c)))
      '42)
(want 'first-class
      (guard (c (#t 'raised))
        (map (lambda (mk) (cpoint-colour (mk 1 2 'c))) (list make-cpoint)))
      '((rgb c)))
(want 'raises-too-few-to-new
      (guard (c (#t 'raised))
        (make-short 1))
      'raised)
(want 'raises-too-many-to-new
      (guard (c (#t 'raised))
        (make-long 1))
      'raised)
(want 'raises-too-few-to-n
      (guard (c (#t 'raised))
        (make-badn 1))
      'raised)
(want 'raises-too-many-to-p
      (guard (c (#t 'raised))
        (make-badp 1 2))
      'raised)
(want 'plain-parent-unaffected
      (guard (c (#t 'raised))
        (let ((p (make-point 3 4))) (list (point-x p) (point-y p) (cpoint? p))))
      '(3 4 #f))

(display (if (null? fails) #t (reverse fails)))
