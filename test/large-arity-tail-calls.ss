;; expect: #t
;; A tail call of 1000 or more arguments is still a tail call (ledger R50b).
;; From 1000 arguments on the arguments travel as a list and the call goes
;; through the callee's list-taking entry; in tail position that has to be a
;; tail call too, or a loop written as mutual recursion grows the stack.
;;
;; Rows, a hundred thousand iterations each, every iteration passing 1000
;; values on (the counter and 999 more, or the counter and 1000 more):
;;   closures   two procedures held in variables that call each other
;;   top-level  a top-level procedure of 1001 parameters that calls itself
;;   rest       a top-level procedure of 1000 fixed parameters and a rest
;; Each answers its first and last value after the loop.  Without the tail
;; call the stack would have to hold a hundred thousand frames.
;;
;; ON THE TREE BEFORE THE CHANGE the module does not instantiate: "param
;; count of 1001 exceeds internal limit of 1000".
(import (rnrs))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))

;; (define-hop name other n): name is a variable holding a lambda of a counter
;; and n values that calls OTHER, a variable, with the counter one lower
(define-syntax define-hop
  (lambda (stx)
    (syntax-case stx ()
      ((k name other n)
       (letrec ((count (lambda (i acc) (if (= i 0) acc (count (- i 1) (cons (- i 1) acc))))))
         (with-syntax (((t ...) (generate-temporaries (count (syntax->datum (syntax n)) '()))))
           (with-syntax ((first (car (syntax (t ...))))
                         (last (car (reverse (syntax (t ...))))))
             (syntax (define name
                       (lambda (c t ...)
                         (if (= c 0) (list first last) (other (- c 1) t ...))))))))))))

;; (define-spin name n rest?): a top-level procedure of a counter and n values
;; that calls itself
(define-syntax define-spin
  (lambda (stx)
    (syntax-case stx ()
      ((k name n)
       (letrec ((count (lambda (i acc) (if (= i 0) acc (count (- i 1) (cons (- i 1) acc))))))
         (with-syntax (((t ...) (generate-temporaries (count (syntax->datum (syntax n)) '()))))
           (with-syntax ((first (car (syntax (t ...))))
                         (last (car (reverse (syntax (t ...))))))
             (syntax (define (name c t ...)
                       (if (= c 0) (list first last) (name (- c 1) t ...)))))))))))

(define-syntax define-spin-rest
  (lambda (stx)
    (syntax-case stx ()
      ((k name n)
       (letrec ((count (lambda (i acc) (if (= i 0) acc (count (- i 1) (cons (- i 1) acc))))))
         (with-syntax (((t ...) (generate-temporaries (count (syntax->datum (syntax n)) '()))))
           (with-syntax ((first (car (syntax (t ...))))
                         (last (car (reverse (syntax (t ...))))))
             (syntax (define (name c t ... . r)
                       (if (= c 0) (list first last r) (name (- c 1) t ... 'more)))))))))))

;; (start f c n): (f c 0 1 ... n-1)
(define-syntax start
  (lambda (stx)
    (syntax-case stx ()
      ((k f c n)
       (letrec ((count (lambda (i acc) (if (= i 0) acc (count (- i 1) (cons (- i 1) acc))))))
         (with-syntax (((a ...) (count (syntax->datum (syntax n)) '())))
           (syntax (f c a ...))))))))

(define-hop ping pong 999)
(define-hop pong ping 999)
(define-spin spin 1000)
(define-spin-rest spin-rest 999)

(want 'closures (car (list (start ping 100000 999))) '(0 998))
(want 'top-level (car (list (start spin 100000 1000))) '(0 999))
(want 'rest (car (list (start spin-rest 100000 999))) '(0 998 (more)))

(display (if (null? fails) #t (reverse fails)))
