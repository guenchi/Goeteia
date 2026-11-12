;; expect: #t
;; else and => are the auxiliary keywords of cond, case and guard only where
;; they are not bound: under a local binding they are variables.  The same
;; for unquote, unquote-splicing and quasiquote inside a quasiquote: bound,
;; they are list structure and nothing is evaluated.
;;
;; Every answer is the one Chez 10 gives.
;;
;; ON THE TREE BEFORE THE CHANGE the bound else is taken for the keyword (kw), the bound
;; unquote still evaluates.
(import (rnrs))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))
(define rows '())
(define (row! name thunk expect) (set! rows (cons (list name thunk expect) rows)))

(define (tag . args) (cons 'called args))

(row! 'else-false (lambda () (let ((else #f)) (cond (else 'kw) (#t 'not-kw)))) 'not-kw)
(row! 'else-true (lambda () (let ((else #t)) (cond (else 'taken) (#t 'next)))) 'taken)
(row! 'else-value (lambda () (let ((else 5)) (cond (else) (#t 'next)))) '5)
(row! 'else-lambda (lambda () ((lambda (else) (cond (else 'kw) (#t 'not-kw))) #f)) 'not-kw)
(row! 'else-internal (lambda () (let () (define else #f) (cond (else 'kw) (#t 'not-kw)))) 'not-kw)
(row! 'else-still-keyword (lambda () (let ((other #f)) (cond (other 'no) (else 'kw)))) 'kw)
(row! 'arrow-variable (lambda () (let ((=> #f)) (procedure? (cond ((+ 1 1) => (lambda (v) (list 'received v))))))) '#t)
(row! 'arrow-still-keyword (lambda () (let ((other #f)) (cond ((+ 1 1) => (lambda (v) (list 'received v)))))) '(received 2))
(row! 'guard-else (lambda () (guard (c (#t 'reraised)) (let ((else #f)) (guard (e (else 'kw)) (raise 1))))) 'reraised)
(row! 'guard-else-true (lambda () (let ((else #t)) (guard (e (else 'taken)) (raise 1)))) 'taken)
(row! 'guard-arrow (lambda () (let ((=> #f)) (procedure? (guard (e ((+ e 1) => (lambda (v) (list 'received v)))) (raise 1))))) '#t)
(row! 'unquote (lambda () (let ((unquote (lambda (x) 'mine))) `(1 ,(+ 1 2)))) '(1 (unquote (+ 1 2))))
(row! 'unquote-vector (lambda () (let ((unquote 5)) `#(1 ,(+ 1 2)))) '#(1 (unquote (+ 1 2))))
(row! 'unquote-splicing (lambda () (let ((unquote-splicing 5)) `(1 ,@(list 2 3)))) '(1 (unquote-splicing (list 2 3))))
(row! 'unquote-only-one (lambda () (let ((unquote-splicing 5)) `(1 ,(+ 1 2)))) '(1 3))
(row! 'quasiquote (lambda () (let ((quasiquote (lambda (x) (list 'q x)))) `7)) '(q 7))
(row! 'unquote-still-keyword (lambda () (let ((other 5)) `(1 ,(+ 1 2) ,@(list 4 other)))) '(1 3 4 5))

(for-each (lambda (r) (want (car r) (guard (c (#t 'raised)) ((cadr r))) (caddr r))) (reverse rows))
(display (if (null? fails) #t (reverse fails)))
