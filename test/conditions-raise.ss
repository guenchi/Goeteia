;; expect: #t
;; error, assertion-violation and assert make the conditions R6RS names;
;; handlers, values through them, and the shapes of guard's clauses
;; (ledger R20f).
;;
;; Each row is an expression and the answer Chez 10 gives for it, compared
;; as a value; a row that raises answers `raised'.  A row marked OWN pins
;; goeteia's answer where R6RS leaves the matter open and Chez differs.
;;
;; ON THE TREE BEFORE THE CHANGE this file does not compile: the names are
;; unbound.
(import (rnrs))

(define (kinds c)
  (list (error? c) (assertion-violation? c) (violation? c) (serious-condition? c)
        (who-condition? c) (message-condition? c) (irritants-condition? c)))
(define (caught thunk) (guard (c (#t c)) (thunk)))
(define n 0)

(define fails '())
(define (want row got expect)
  (unless (equal? got expect)
    (set! fails (cons (list row 'got got 'want expect) fails))))

(want 'error
      (guard (c (#t 'raised))
        (let ((c (caught (lambda () (error 'here "went wrong" 1 2))))) (list (kinds c) (condition-who c) (condition-message c) (condition-irritants c))))
      '((#t #f #f #t #t #t #t) here "went wrong" (1 2)))
(want 'error-with-no-who
      (guard (c (#t 'raised))
        (let ((c (caught (lambda () (error #f "m" 'x))))) (list (kinds c) (condition-message c) (condition-irritants c))))
      '((#t #f #f #t #f #t #t) "m" (x)))
(want 'error-with-a-string-who
      (guard (c (#t 'raised))
        (let ((c (caught (lambda () (error "where" "m"))))) (list (condition-who c) (condition-irritants c))))
      '("where" ()))
(want 'assertion-violation
      (guard (c (#t 'raised))
        (let ((c (caught (lambda () (assertion-violation 'f "bad" 'x 'y))))) (list (kinds c) (condition-who c) (condition-message c) (condition-irritants c))))
      '((#f #t #t #t #t #t #t) f "bad" (x y)))
(want 'assert
      (guard (c (#t 'raised))
        (let ((c (caught (lambda () (assert (= 1 2)))))) (list (error? c) (assertion-violation? c) (violation? c) (serious-condition? c) (message-condition? c))))
      '(#f #t #t #t #t))
(want 'assert-answers-its-value
      (guard (c (#t 'raised))
        (list (assert (+ 1 2)) (assert 'yes)))
      '(3 yes))
(want 'a-bad-who-or-message
      (guard (c (#t 'raised))
        (list (assertion-violation? (caught (lambda () (error 5 "m")))) (assertion-violation? (caught (lambda () (error 'w 5)))) (assertion-violation? (caught (lambda () (assertion-violation '(a) "m"))))))
      '(#t #t #t))
(want 'raise-of-any-object
      (guard (c (#t 'raised))
        (list (caught (lambda () (raise 42))) (caught (lambda () (raise (list 1 2)))) (caught (lambda () (raise "s"))) (condition? (caught (lambda () (raise (make-warning)))))))
      '(42 (1 2) "s" #t))
(want 'a-handler-that-is-not-a-procedure
      (guard (c (#t 'raised))
        (assertion-violation? (caught (lambda () (with-exception-handler 5 (lambda () 1))))))
      '#t)
(want 'a-thunk-that-is-not-a-procedure
      (guard (c (#t 'raised))
        (assertion-violation? (caught (lambda () (with-exception-handler (lambda (c) 0) 5)))))
      '#t)
(want 'raise-continuable-returns
      (guard (c (#t 'raised))
        (with-exception-handler (lambda (c) (* c 2)) (lambda () (+ 1 (raise-continuable 20)))))
      '41)
(want 'three-handlers-deep
      (guard (c (#t 'raised))
        (with-exception-handler (lambda (c) (list 'a c)) (lambda () (with-exception-handler (lambda (c) (list 'b (raise-continuable (list 'from-b c)))) (lambda () (with-exception-handler (lambda (c) (list 'c (raise-continuable (list 'from-c c)))) (lambda () (list 'body (raise-continuable 'x)))))))))
      '(body (c (b (a (from-b (from-c x)))))))
(want 'a-handler-returns-from-raise
      (guard (c (#t 'raised))
        (let ((log '())) (list (guard (e ((non-continuable-violation? e) 'non-continuable)) (with-exception-handler (lambda (c) (set! log (cons c log)) 'ignored) (lambda () (raise 'boom)))) log)))
      '(non-continuable (boom)))
(want 'the-handler-is-gone-afterwards
      (guard (c (#t 'raised))
        (guard (e (#t (list 'outer e))) (with-exception-handler (lambda (c) 0) (lambda () 'done)) (raise 'after)))
      '(outer after))
(want 'values-from-a-handler
      (guard (c (#t 'raised))
        (list (call-with-values (lambda () (with-exception-handler (lambda (c) (values 1 2)) (lambda () (raise-continuable 'v)))) list) (call-with-values (lambda () (with-exception-handler (lambda (c) (values)) (lambda () (raise-continuable 'v)))) list)))
      '((1 2) ()))
(want 'values-through-the-forms
      (guard (c (#t 'raised))
        (list (call-with-values (lambda () (with-exception-handler (lambda (c) 0) (lambda () (values 1 2 3)))) list) (call-with-values (lambda () (guard (e (#t 0)) (values 4 5))) list) (call-with-values (lambda () (guard (e (#t (values 7 8))) (raise 'x))) list) (call-with-values (lambda () (dynamic-wind (lambda () #f) (lambda () (values 1 2 3)) (lambda () #f))) list) (call-with-values (lambda () (guard (e (#f 0)) (values))) list)))
      '((1 2 3) (4 5) (7 8) (1 2 3) ()))
(want 'clause-shapes
      (guard (c (#t 'raised))
        (list (guard (e ((symbol? e) 'sym) ((string? e) 'str)) (raise "s")) (guard (e ((assq 'a e) => cdr) ((assq 'b e))) (raise (list (cons 'b 2)))) (guard (e ((memq e '(x y)) => length)) (raise 'x)) (guard (e (else (list 'else e))) (raise 1)) (guard (e ((number? e) (set! n (+ n 1)) (* e 2))) (raise 21)) n))
      '(str (b . 2) 2 (else 1) 42 1))
(want 'what-a-guard-returns
      (guard (c (#t 'raised))
        (list (guard (e (#t 0)) (cons 1 2)) (procedure? (guard (e (#t 0)) car)) (guard (e (#t 0)) 5) (guard (e ((string? e) 0)) 'no-raise)))
      '((1 . 2) #t 5 no-raise))
(want 'a-guard-in-a-loop
      (guard (c (#t 'raised))
        (let loop ((i 0) (acc 0)) (if (= i 100000) acc (loop (+ i 1) (+ acc (guard (e (#t 1)) (if (odd? i) (raise 'x) 2)))))))
      '150000)
(want 'raise-again-in-a-clause
      (guard (c (#t 'raised))
        (guard (outer (#t (list 'outer outer))) (guard (inner ((symbol? inner) (raise (list 'again inner)))) (raise 'first))))
      '(outer (again first)))
(want 'arrow-bound-locally
      (guard (c (#t 'raised))
        (let ((=> 5)) (guard (e ((symbol? e) => 'body)) (raise 'x))))
      'body)
(want 'raises-with-else-bound-locally
      (guard (c (#t 'raised))
        (let ((else #f)) (guard (e (else 'taken)) (raise 'x))))
      'raised)
(want 'syntax-violation
      (guard (c (#t 'raised))
        (let ((c (caught (lambda () (syntax-violation 'who "bad" '(form) 'sub))))) (list (syntax-violation? c) (violation? c) (condition-who c) (condition-message c) (syntax-violation-form c) (syntax-violation-subform c))))
      '(#t #t who "bad" (form) sub))
(want 'syntax-violation-without-who-or-subform
      (guard (c (#t 'raised))
        (let ((c (caught (lambda () (syntax-violation #f "bad" '(lam x)))))) (list (syntax-violation? c) (who-condition? c) (syntax-violation-form c) (syntax-violation-subform c))))
      '(#t #f (lam x) #f))

(display (if (null? fails) #t (reverse fails)))
