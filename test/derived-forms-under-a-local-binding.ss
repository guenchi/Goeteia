;; expect: #t
;; A derived form means what it means whatever the program has bound locally:
;; the if a when becomes, the let a do becomes, are the expander's own, and
;; a local variable named if or let does not take them.  The same when the
;; local binding has the derived form's own name and the form is used to
;; make that binding.
;;
;; Every answer is the one Chez 10 gives.
;;
;; ON THE TREE BEFORE THE CHANGE the rows that bind let, lambda or set! do not compile, and
;; a let* that binds let* loses its later bindings.
(import (rnrs))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))
(define rows '())
(define (row! name thunk expect) (set! rows (cons (list name thunk expect) rows)))

(define (tag . args) (cons 'called args))
(define-record-type thing (fields if quote set! lambda define apply begin let))

(row! 'when (lambda () (let ((if tag) (begin tag)) (list (when #t 7) (when #t 1 2 3)))) '(7 3))
(row! 'unless (lambda () (let ((if tag) (begin tag)) (list (unless #f 7) (unless #f 1 2 3)))) '(7 3))
(row! 'do (lambda () (let ((let tag) (if tag) (begin tag) (lambda tag) (set! tag)) (do ((i 0 (+ i 1)) (acc 0 (+ acc i))) ((= i 4) acc)))) '6)
(row! 'let* (lambda () (let ((let tag)) (let* ((a 1) (b (+ a 1))) (list a b)))) '(1 2))
(row! 'let*-empty (lambda () (let ((let tag)) (let* () 7))) '7)
(row! 'letrec (lambda () (let ((let tag) (set! tag) (begin tag)) (letrec ((ev? (lambda (n) (if (= n 0) #t (od? (- n 1))))) (od? (lambda (n) (if (= n 0) #f (ev? (- n 1)))))) (ev? 10)))) '#t)
(row! 'letrec* (lambda () (let ((let tag) (set! tag) (begin tag)) (letrec* ((a 1) (b (+ a 1))) (list a b)))) '(1 2))
(row! 'named-let (lambda () (let ((lambda tag) (set! tag) (begin tag) (if tag)) (let loop ((i 0)) (cond ((< i 3) (loop (+ i 1))) (else i))))) '3)
(row! 'named-let-escapes (lambda () (let ((lambda tag) (set! tag) (begin tag)) (let loop ((i 0)) (cond ((< i 3) (let ((again loop)) (again (+ i 1)))) (else i))))) '3)
(row! 'case (lambda () (let ((if tag) (or tag) (begin tag) (quote tag) (let tag)) (case (+ 1 1) ((1) 10) ((2 3) 20) (else 30)))) '20)
(row! 'case-symbols (lambda () (let ((if tag) (or tag) (begin tag) (let tag)) (case 'b ((a) 1) ((b c) 2) (else 3)))) '2)
(row! 'cond (lambda () (let ((if tag) (begin tag) (let tag)) (cond ((= 1 2) 10) ((+ 1 1) => (lambda (v) (* v 10))) (else 30)))) '20)
(row! 'cond-test-only (lambda () (let ((if tag) (let tag)) (cond (#f) ((+ 1 1))))) '2)
(row! 'and-or (lambda () (let ((if tag) (let tag)) (list (and 1 2 3) (or #f 2) (and) (or) (and 1 #f 3)))) '(3 2 #t #f #f))
(row! 'guard (lambda () (let ((if tag) (let tag) (begin tag) (lambda tag)) (guard (e (#t (list 'caught e))) (raise 1)))) '(caught 1))
(row! 'assert (lambda () (let ((if tag) (begin tag)) (assert (= 1 1)))) '#t)
(row! 'let-values (lambda () (let ((lambda tag) (let tag)) (let-values (((a b) (values 1 2))) (list a b)))) '(1 2))
(row! 'quasiquote (lambda () (let ((cons tag) (append tag) (list tag)) `(1 ,(+ 1 1) ,@(vector->list (vector 3 4))))) '(1 2 3 4))
(row! 'own-let* (lambda () (let* ((let* tag) (y 2)) (list y (let* 1)))) '(2 (called 1)))
(row! 'own-letrec (lambda () (letrec ((letrec tag)) (letrec 1))) '(called 1))
(row! 'own-do (lambda () (do ((do tag) (i 0 (+ i 1))) ((= i 2) (do i)))) '(called 2))
(row! 'own-let (lambda () (let ((let tag)) (let 1))) '(called 1))
(row! 'own-lambda (lambda () ((lambda (lambda) (lambda 1)) tag)) '(called 1))
(row! 'own-named-let (lambda () (let let ((n 1)) (or (= n 0) (let (- n 1))))) '#t)
(row! 'record-fields (lambda () (let ((t (make-thing 1 2 3 4 5 6 7 8))) (list (thing-if t) (thing-quote t) (thing-set! t) (thing-lambda t) (thing-define t) (thing-apply t) (thing-begin t) (thing-let t)))) '(1 2 3 4 5 6 7 8))

(for-each (lambda (r) (want (car r) (guard (c (#t 'raised)) ((cadr r))) (caddr r))) (reverse rows))
(display (if (null? fails) #t (reverse fails)))
