;; expect: #t
;; a record type with a parent: an instance holds the ancestors' fields
;; first, an ancestor's accessors and mutators work on a descendant's
;; instance, and a predicate accepts its own type and every descendant
;; (ledger R74: the parent clause used to be dropped without a word).
;;
;; Each row is an expression and the answer Chez 10 gives for it, compared
;; as a value; a row that raises answers `raised'.  A row marked OWN pins
;; goeteia's answer where R6RS leaves the matter open and Chez differs.
;;
;; ON THE TREE BEFORE THE CHANGE this file does not compile, or its rows are
;; red: every clause but `fields' was ignored.
(import (rnrs))

(define-record-type point (fields x (mutable y)))
(define-record-type (point3 make-point3 point3?) (parent point) (fields z))
(define-record-type point4 (parent point3) (fields (mutable w point4-w set-point4-w!)))
;; a second family, and types that only share a field count with the first
(define-record-type shape (fields name))
(define-record-type circle (parent shape) (fields r))
(define-record-type pair2 (fields a b))
(define-record-type triple (fields a b c))
;; a child with no fields of its own, and a parent with none
(define-record-type marked-point (parent point))
(define-record-type base)
(define-record-type leaf (parent base) (fields v))
;; a field name the parent also has
(define-record-type named (fields x))
(define-record-type renamed (parent named) (fields x))
;; a child produced by a macro: its parent must still accept it
(define-record-type animal (fields legs))
(define-syntax define-animal
  (syntax-rules ()
    ((_ name make pred extra) (define-record-type (name make pred) (parent animal) (fields extra)))))
(define-animal bird make-bird bird? wings)
(define p2 (make-point 1 2))
(define p3 (make-point3 1 2 3))
(define p4 (make-point4 1 2 3 4))

(define fails '())
(define (want row got expect)
  (unless (equal? got expect)
    (set! fails (cons (list row 'got got 'want expect) fails))))

(want 'fields-in-order
      (guard (c (#t 'raised))
        (list (point-x p4) (point-y p4) (point3-z p4) (point4-w p4)))
      '(1 2 3 4))
(want 'ancestor-accessors
      (guard (c (#t 'raised))
        (list (point-x p3) (point-y p3) (point3-z p3)))
      '(1 2 3))
(want 'predicates-up
      (guard (c (#t 'raised))
        (list (point? p2) (point? p3) (point? p4) (point3? p3) (point3? p4) (point4? p4)))
      '(#t #t #t #t #t #t))
(want 'predicates-down
      (guard (c (#t 'raised))
        (list (point3? p2) (point4? p2) (point4? p3)))
      '(#f #f #f))
(want 'predicates-across
      (guard (c (#t 'raised))
        (list (point? (make-circle 'c 1)) (shape? p3) (circle? p4) (point? (make-pair2 1 2)) (point3? (make-triple 1 2 3)) (pair2? p2) (triple? p3)))
      '(#f #f #f #f #f #f #f))
(want 'predicates-on-others
      (guard (c (#t 'raised))
        (list (point? 5) (point? "s") (point? '(1 2)) (point? (vector 1 2)) (point? point?) (point3? #f) (point? 1.5) (point? 1000000000000000000000000000000)))
      '(#f #f #f #f #f #f #f #f))
(want 'ancestor-mutator-on-descendant
      (guard (c (#t 'raised))
        (let ((q (make-point4 1 2 3 4))) (point-y-set! q 20) (set-point4-w! q 40) (list (point-x q) (point-y q) (point3-z q) (point4-w q))))
      '(1 20 3 40))
(want 'mutation-is-per-instance
      (guard (c (#t 'raised))
        (let ((a (make-point3 1 2 3)) (b (make-point3 1 2 3))) (point-y-set! a 9) (list (point-y a) (point-y b))))
      '(9 2))
(want 'descendant-accessor-on-ancestor
      (guard (c (#t 'raised))
        (list (guard (c (#t 'raised)) (point3-z p2)) (guard (c (#t 'raised)) (point4-w p3))))
      '(raised raised))
(want 'accessor-on-a-stranger
      (guard (c (#t 'raised))
        (list (guard (c (#t 'raised)) (point-x (make-pair2 1 2))) (guard (c (#t 'raised)) (point3-z (make-triple 1 2 3))) (guard (c (#t 'raised)) (point-x 7))))
      '(raised raised raised))
(want 'second-family
      (guard (c (#t 'raised))
        (let ((c (make-circle 'round 5))) (list (shape? c) (circle? c) (shape-name c) (circle-r c) (circle? (make-shape 'plain)))))
      '(#t #t round 5 #f))
(want 'child-without-fields
      (guard (c (#t 'raised))
        (let ((m (make-marked-point 7 8))) (list (point? m) (marked-point? m) (point-x m) (point-y m) (marked-point? p2))))
      '(#t #t 7 8 #f))
(want 'parent-without-fields
      (guard (c (#t 'raised))
        (let ((l (make-leaf 3)) (b (make-base))) (list (base? l) (leaf? l) (leaf-v l) (base? b) (leaf? b))))
      '(#t #t 3 #t #f))
(want 'repeated-field-name
      (guard (c (#t 'raised))
        (let ((r (make-renamed 1 2))) (list (named-x r) (renamed-x r))))
      '(1 2))
(want 'child-from-a-macro
      (guard (c (#t 'raised))
        (let ((b (make-bird 2 2))) (list (animal? b) (bird? b) (animal-legs b) (bird-wings b) (bird? (make-animal 4)))))
      '(#t #t 2 2 #f))
(want 'through-first-class-procedures
      (guard (c (#t 'raised))
        (let ((mk make-point3) (acc point-x) (pred point?)) (let ((r (mk 4 5 6))) (list (pred r) (acc r) (map point-y (list p2 p3 p4))))))
      '(#t 4 (2 2 2)))
(want 'equal-and-eqv
      (guard (c (#t 'raised))
        (list (equal? p3 p3) (equal? p3 (make-point3 1 2 3)) (eqv? p3 p3)))
      '(#t #f #t))

(display (if (null? fails) #t (reverse fails)))
