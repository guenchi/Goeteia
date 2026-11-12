;; expect: #t
;; Inside a transformer a local binding shadows the transformer language's
;; own forms too: a let or lambda there that binds if, cond or quote makes
;; a variable, an else it binds is not cond's, and under a bound unquote a
;; quasiquote evaluates nothing.  A PATTERN variable of such a name is not
;; a binding of this kind and changes nothing.
;;
;; Every answer is the one Chez 10 gives, except the row marked pinned.
;;
;; ON THE TREE BEFORE THE CHANGE a transformer that binds if and calls it with three
;; values is refused as a malformed if, or takes the keyword's meaning.
(import (rnrs))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))
(define rows '())
(define (row! name thunk expect) (set! rows (cons (list name thunk expect) rows)))

(define-syntax t-let-if
  (lambda (stx)
    (syntax-case stx ()
      ((k) (let ((if (lambda (a b c) (list a b c))))
             (datum->syntax (syntax k) (list 'quote (if 1 2 3))))))))
(define-syntax t-lambda-if
  (lambda (stx)
    (syntax-case stx ()
      ((k) ((lambda (if) (datum->syntax (syntax k) (list 'quote (if 1 2 3))))
            (lambda (a b c) (list c b a)))))))
(define-syntax t-cond
  (lambda (stx)
    (syntax-case stx ()
      ((k) (let ((cond (lambda (x) (+ x 1))))
             (datum->syntax (syntax k) (cond 41)))))))
(define-syntax t-quote
  (lambda (stx)
    (syntax-case stx ()
      ((k) (let ((quote (lambda (x) (+ x 1))))
             (datum->syntax (syntax k) (quote 41)))))))
(define-syntax t-else-false
  (lambda (stx)
    (syntax-case stx ()
      ((k) (let ((else #f))
             (datum->syntax (syntax k) (cond (else 1) (#t 2))))))))
(define-syntax t-else-true
  (lambda (stx)
    (syntax-case stx ()
      ((k) (let ((else #t))
             (datum->syntax (syntax k) (cond (else 1) (#t 2))))))))
(define-syntax t-unquote
  (lambda (stx)
    (syntax-case stx ()
      ((k) (let ((unquote 5))
             (datum->syntax (syntax k) (list 'quote `(1 ,(+ 1 2)))))))))
(define-syntax t-plain
  (lambda (stx)
    (syntax-case stx ()
      ((k) (let ((other 5))
             (datum->syntax (syntax k) (list 'quote (list (if #t 1 2) (cond (else 3)) `(4 ,(+ other 1))))))))))

(row! 'let-if (lambda () (t-let-if)) '(1 2 3))
(row! 'lambda-if (lambda () (t-lambda-if)) '(3 2 1))
(row! 'cond (lambda () (t-cond)) '42)
(row! 'quote (lambda () (t-quote)) '42)
(row! 'else-false (lambda () (t-else-false)) '2)
(row! 'else-true (lambda () (t-else-true)) '1)
(row! 'unquote (lambda () (t-unquote)) '(1 (unquote (+ 1 2))))
(row! 'unbound-still-keywords (lambda () (t-plain)) '(1 3 (4 6)))
(define-syntax pattern-names (syntax-rules () ((_ syntax if else) (list syntax if else))))
;; pinned: goeteia's answer; Chez answers otherwise (ledger R43d)
(row! 'pattern-variables (lambda () (pattern-names 1 2 3)) '(1 2 3))

(for-each (lambda (r) (want (car r) (guard (c (#t 'raised)) ((cadr r))) (caddr r))) (reverse rows))
(display (if (null? fails) #t (reverse fails)))
