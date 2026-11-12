;; expect: #t
;; A local variable whose name is a core form's is an ordinary variable in
;; every other respect: it is assigned, captured, mutated through a closure,
;; passed on, and can name a loop.
;;
;; Every answer is the one Chez 10 gives.
;;
;; ON THE TREE BEFORE THE CHANGE this file does not compile.
(import (rnrs))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))
(define rows '())
(define (row! name thunk expect) (set! rows (cons (list name thunk expect) rows)))

(define (tag . args) (cons 'called args))

(row! 'loop-name (lambda () (let if ((i 0) (acc 0)) (cond ((< i 5) (if (+ i 1) (+ acc i))) (else acc)))) '10)
(row! 'loop-parameter (lambda () (let loop ((quote 0) (begin 0)) (cond ((< quote 5) (loop (+ quote 1) (+ begin quote))) (else begin)))) '10)
(row! 'captured-and-mutated (lambda () (let ((quote 0)) (let ((inc (lambda () (set! quote (+ quote 1)) quote))) (inc) (inc)))) '2)
(row! 'passed-on (lambda () (let ((lambda tag) (let 5)) (map lambda (list let)))) '((called 5)))
(row! 'assigned-to-another (lambda () (let ((if tag) (begin 0)) (set! begin if) (begin 1 2))) '(called 1 2))
(row! 'two-names (lambda () (let ((if tag) (quote list)) (list (if 1) (quote 2 3)))) '((called 1) (2 3)))
(row! 'shadow-then-restore (lambda () (let ((if tag)) (list (let ((if list)) (if 1 2)) (if 3)))) '((1 2) (called 3)))
(row! 'three-deep (lambda () (let ((set! tag)) (let ((set! list)) (let ((set! vector)) (set! 1 2))))) '#(1 2))
(row! 'formal-and-internal (lambda () ((lambda (apply) (define begin apply) (begin 1 2)) tag)) '(called 1 2))
(row! 'rest-is-a-list (lambda () ((lambda define (length define)) 1 2 3)) '3)

(for-each (lambda (r) (want (car r) (guard (c (#t 'raised)) ((cadr r))) (caddr r))) (reverse rows))
(display (if (null? fails) #t (reverse fails)))
