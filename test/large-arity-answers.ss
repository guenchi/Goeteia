;; expect: #t
;; Calls of 1000 or more arguments and procedures of 1000 or more fixed
;; parameters answer on wasm as they do on JS and on Chez (ledger R50b).
;; The engine takes at most 1000 parameters in a function type, and a
;; closure's fast entry spends one on the closure, so 999 is the last arity
;; that has typed entries; from 1000 on the arguments travel as a list.
;;
;; Every large form is written by a macro, so no line of this file holds a
;; thousand arguments.  N is 999, 1000, 1001, 2000; n-ary + only at 999, 1000, 1001, because each of its
;; operands costs two locals and the engine's memory for that grows fast.
;;
;; Rows, for each N:
;;   list vector +     the n-ary primitives
;;   variadic          a user procedure with a rest parameter, 0 and 2 fixed
;;   fixed             a top-level procedure of N parameters: called directly,
;;                     through a variable holding it, and applied; eq? to
;;                     itself
;;   dotted            a top-level procedure of N fixed parameters and a rest
;;   lambda            a lambda of N parameters applied where it is written,
;;                     and one called through a variable; one with a rest
;;   loop noloop       a named let of N parameters whose name only recurs,
;;                     and one whose name escapes
;;   values            a consumer of N values
;;   order             the callee is evaluated first and the arguments left
;;                     to right (goeteia's order; R6RS leaves it open)
;; And once:
;;   nested            a lambda of 37 parameters inside a 1000-argument call
;;                     -- an arity nothing else in the program uses -- still
;;                     gets its type
;;   surplus           a procedure of 1000 parameters applied to 1001 values
;;                     answers as if the last were absent.  That is the
;;                     missing argument-count check of every generic entry
;;                     (ledger R65), pinned here as it is; Chez raises.
;;
;; Two things this file is careful about, both older than the change it tests:
;;   - each large form is the body of a procedure of its own and is never in
;;     tail position.  On arm64 the engine this suite runs on dies compiling a
;;     tail call of 518 or more arguments through a typed entry (ledger R68),
;;     and the top level is one function whose locals the engine bounds;
;;   - for the same reason, at 999 only the rows that engine compiles today
;;     are taken (the n-ary primitives, a direct call of a top-level
;;     procedure, eq?, a lambda with a rest, the loop, the order); every row
;;     is taken from N = 1000 on, where the list convention's two-parameter
;;     calls are used.
;;
;; ON THE TREE BEFORE THE CHANGE the module does not instantiate: "param
;; count of 1001 exceeds internal limit of 1000".
(import (rnrs))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))

(define (upto n)
  (let loop ((i n) (acc '())) (if (= i 0) acc (loop (- i 1) (cons (- i 1) acc)))))
(define (tri n) (div (* n (- n 1)) 2))
(define (count-args . xs) (length xs))
(define (two-and-rest a b . r) (list a b (length r)))
(define trace '())
(define (note! x) (set! trace (cons x trace)) x)
(define (traced thunk)
  (set! trace '())
  (let ((r (thunk))) (list r (reverse trace))))

;; Each row's large form sits in a procedure of its own: the top level is one
;; function, and a function's locals are a resource the engine bounds.
(define rows '())
(define (row! name thunk expect) (set! rows (cons (list name thunk expect) rows)))

(define-syntax call-n
  (lambda (stx)
    (syntax-case stx ()
      ((k f n)
       (letrec ((count (lambda (i acc) (if (= i 0) acc (count (- i 1) (cons (- i 1) acc))))))
         (with-syntax (((a ...) (count (syntax->datum (syntax n)) '()))) (syntax (f a ...))))))))

(define-syntax nested-n
  (lambda (stx)
    (syntax-case stx ()
      ((k f n inner)
       (letrec ((count (lambda (i acc) (if (= i 0) acc (count (- i 1) (cons (- i 1) acc))))))
         (with-syntax (((a ...) (cdr (count (syntax->datum (syntax n)) '())))) (syntax (f a ... inner))))))))

(define-syntax order-n
  (lambda (stx)
    (syntax-case stx ()
      ((k f n)
       (letrec ((count (lambda (i acc) (if (= i 0) acc (count (- i 1) (cons (- i 1) acc))))))
         (with-syntax (((a ...) (count (syntax->datum (syntax n)) '()))) (syntax ((begin (note! 'callee) f) (note! a) ...))))))))

(define-syntax fixed-n
  (lambda (stx)
    (syntax-case stx ()
      ((k n)
       (letrec ((count (lambda (i acc) (if (= i 0) acc (count (- i 1) (cons (- i 1) acc))))))
         (with-syntax (((t ...) (generate-temporaries (count (syntax->datum (syntax n)) '()))))
           (with-syntax ((first (car (syntax (t ...))))
                         (last (car (reverse (syntax (t ...)))))
                         ((u ...) (cdr (syntax (t ...)))))
             (syntax (lambda (t ...) (list first last))))))))))

(define-syntax dotted-n
  (lambda (stx)
    (syntax-case stx ()
      ((k n)
       (letrec ((count (lambda (i acc) (if (= i 0) acc (count (- i 1) (cons (- i 1) acc))))))
         (with-syntax (((t ...) (generate-temporaries (count (syntax->datum (syntax n)) '()))))
           (with-syntax ((first (car (syntax (t ...))))
                         (last (car (reverse (syntax (t ...)))))
                         ((u ...) (cdr (syntax (t ...)))))
             (syntax (lambda (t ... . r) (list first last r))))))))))

(define-syntax define-fixed
  (lambda (stx)
    (syntax-case stx ()
      ((k name n)
       (letrec ((count (lambda (i acc) (if (= i 0) acc (count (- i 1) (cons (- i 1) acc))))))
         (with-syntax (((t ...) (generate-temporaries (count (syntax->datum (syntax n)) '()))))
           (with-syntax ((first (car (syntax (t ...))))
                         (last (car (reverse (syntax (t ...)))))
                         ((u ...) (cdr (syntax (t ...)))))
             (syntax (define (name t ...) (list first last))))))))))

(define-syntax define-dotted
  (lambda (stx)
    (syntax-case stx ()
      ((k name n)
       (letrec ((count (lambda (i acc) (if (= i 0) acc (count (- i 1) (cons (- i 1) acc))))))
         (with-syntax (((t ...) (generate-temporaries (count (syntax->datum (syntax n)) '()))))
           (with-syntax ((first (car (syntax (t ...))))
                         (last (car (reverse (syntax (t ...)))))
                         ((u ...) (cdr (syntax (t ...)))))
             (syntax (define (name t ... . r) (list first last r))))))))))

(define-syntax apply-direct
  (lambda (stx)
    (syntax-case stx ()
      ((k n)
       (letrec ((count (lambda (i acc) (if (= i 0) acc (count (- i 1) (cons (- i 1) acc))))))
         (with-syntax (((a ...) (count (syntax->datum (syntax n)) '()))
                       ((t ...) (generate-temporaries (count (syntax->datum (syntax n)) '()))))
           (with-syntax ((first (car (syntax (t ...))))
                         (last (car (reverse (syntax (t ...)))))
                         ((u ...) (cdr (syntax (t ...)))))
             (syntax ((lambda (t ...) (list first last)) a ...)))))))))

(define-syntax loop-n
  (lambda (stx)
    (syntax-case stx ()
      ((k n)
       (letrec ((count (lambda (i acc) (if (= i 0) acc (count (- i 1) (cons (- i 1) acc))))))
         (with-syntax (((a ...) (count (syntax->datum (syntax n)) '()))
                       ((t ...) (generate-temporaries (count (syntax->datum (syntax n)) '()))))
           (with-syntax ((first (car (syntax (t ...))))
                         (last (car (reverse (syntax (t ...)))))
                         ((u ...) (cdr (syntax (t ...)))))
             (syntax (let loop ((t a) ...) (if (< first 3) (loop (+ first 1) u ...) (list first last)))))))))))

(define-syntax noloop-n
  (lambda (stx)
    (syntax-case stx ()
      ((k n)
       (letrec ((count (lambda (i acc) (if (= i 0) acc (count (- i 1) (cons (- i 1) acc))))))
         (with-syntax (((a ...) (count (syntax->datum (syntax n)) '()))
                       ((t ...) (generate-temporaries (count (syntax->datum (syntax n)) '()))))
           (with-syntax ((first (car (syntax (t ...))))
                         (last (car (reverse (syntax (t ...)))))
                         ((u ...) (cdr (syntax (t ...)))))
             (syntax (let loop ((t a) ...) (if (< first 3) (let ((again loop)) (car (list (again (+ first 1) u ...)))) (list first last)))))))))))


;; ---- N = 999

(row! '(list 999) (lambda () (list (call-n list 999))) (upto 999))
(row! '(vector 999) (lambda () (list (let ((v (call-n vector 999))) (list (vector-length v) (vector-ref v 0) (vector-ref v 998))))) '(999 0 998))
(row! '(+ 999) (lambda () (list (call-n + 999))) (tri 999))
(row! '(variadic 999) (lambda () (list (call-n count-args 999))) 999)
(row! '(variadic-2 999) (lambda () (list (call-n two-and-rest 999))) '(0 1 997))
(define-fixed fixed-999 999)
(row! '(fixed direct 999) (lambda () (list (call-n fixed-999 999))) '(0 998))
(row! '(fixed eq 999) (lambda () (list (let ((a fixed-999) (b fixed-999)) (list (eq? a b) (eq? fixed-999 fixed-999) (procedure? a))))) '(#t #t #t))
(define-dotted dotted-999 999)
(row! '(lambda rest 999) (lambda () (list (let ((g (dotted-n 999))) (list (call-n g 999) (apply g (upto 1001)))))) '((0 998 ()) (0 998 (999 1000))))
(row! '(loop 999) (lambda () (list (loop-n 999))) '(3 998))
(row! '(order 999) (lambda () (list (traced (lambda () (car (list (order-n count-args 999))))))) (list 999 (cons 'callee (upto 999))))

;; ---- N = 1000

(row! '(list 1000) (lambda () (list (call-n list 1000))) (upto 1000))
(row! '(vector 1000) (lambda () (list (let ((v (call-n vector 1000))) (list (vector-length v) (vector-ref v 0) (vector-ref v 999))))) '(1000 0 999))
(row! '(+ 1000) (lambda () (list (call-n + 1000))) (tri 1000))
(row! '(variadic 1000) (lambda () (list (call-n count-args 1000))) 1000)
(row! '(variadic-2 1000) (lambda () (list (call-n two-and-rest 1000))) '(0 1 998))
(define-fixed fixed-1000 1000)
(row! '(fixed direct 1000) (lambda () (list (call-n fixed-1000 1000))) '(0 999))
(row! '(fixed value 1000) (lambda () (list (let ((g fixed-1000)) (call-n g 1000)))) '(0 999))
(row! '(fixed apply 1000) (lambda () (list (apply fixed-1000 (upto 1000)))) '(0 999))
(row! '(fixed eq 1000) (lambda () (list (let ((a fixed-1000) (b fixed-1000)) (list (eq? a b) (eq? fixed-1000 fixed-1000) (procedure? a))))) '(#t #t #t))
(define-dotted dotted-1000 1000)
(row! '(dotted exact 1000) (lambda () (list (call-n dotted-1000 1000))) '(0 999 ()))
(row! '(dotted more 1000) (lambda () (list (apply dotted-1000 (upto 1002)))) '(0 999 (1000 1001)))
(row! '(dotted value 1000) (lambda () (list (let ((g dotted-1000)) (apply g (upto 1001))))) '(0 999 (1000)))
(row! '(lambda direct 1000) (lambda () (list (apply-direct 1000))) '(0 999))
(row! '(lambda value 1000) (lambda () (list (let ((g (fixed-n 1000))) (call-n g 1000)))) '(0 999))
(row! '(lambda apply 1000) (lambda () (list (apply (fixed-n 1000) (upto 1000)))) '(0 999))
(row! '(lambda rest 1000) (lambda () (list (let ((g (dotted-n 1000))) (list (call-n g 1000) (apply g (upto 1002)))))) '((0 999 ()) (0 999 (1000 1001))))
(row! '(loop 1000) (lambda () (list (loop-n 1000))) '(3 999))
(row! '(noloop 1000) (lambda () (list (noloop-n 1000))) '(3 999))
(row! '(values 1000) (lambda () (list (call-with-values (lambda () (apply values (upto 1000))) (fixed-n 1000)))) '(0 999))
(row! '(order 1000) (lambda () (list (traced (lambda () (car (list (order-n count-args 1000))))))) (list 1000 (cons 'callee (upto 1000))))

;; ---- N = 1001

(row! '(list 1001) (lambda () (list (call-n list 1001))) (upto 1001))
(row! '(vector 1001) (lambda () (list (let ((v (call-n vector 1001))) (list (vector-length v) (vector-ref v 0) (vector-ref v 1000))))) '(1001 0 1000))
(row! '(+ 1001) (lambda () (list (call-n + 1001))) (tri 1001))
(row! '(variadic 1001) (lambda () (list (call-n count-args 1001))) 1001)
(row! '(variadic-2 1001) (lambda () (list (call-n two-and-rest 1001))) '(0 1 999))
(define-fixed fixed-1001 1001)
(row! '(fixed direct 1001) (lambda () (list (call-n fixed-1001 1001))) '(0 1000))
(row! '(fixed value 1001) (lambda () (list (let ((g fixed-1001)) (call-n g 1001)))) '(0 1000))
(row! '(fixed apply 1001) (lambda () (list (apply fixed-1001 (upto 1001)))) '(0 1000))
(row! '(fixed eq 1001) (lambda () (list (let ((a fixed-1001) (b fixed-1001)) (list (eq? a b) (eq? fixed-1001 fixed-1001) (procedure? a))))) '(#t #t #t))
(define-dotted dotted-1001 1001)
(row! '(dotted exact 1001) (lambda () (list (call-n dotted-1001 1001))) '(0 1000 ()))
(row! '(dotted more 1001) (lambda () (list (apply dotted-1001 (upto 1003)))) '(0 1000 (1001 1002)))
(row! '(dotted value 1001) (lambda () (list (let ((g dotted-1001)) (apply g (upto 1002))))) '(0 1000 (1001)))
(row! '(lambda direct 1001) (lambda () (list (apply-direct 1001))) '(0 1000))
(row! '(lambda value 1001) (lambda () (list (let ((g (fixed-n 1001))) (call-n g 1001)))) '(0 1000))
(row! '(lambda apply 1001) (lambda () (list (apply (fixed-n 1001) (upto 1001)))) '(0 1000))
(row! '(lambda rest 1001) (lambda () (list (let ((g (dotted-n 1001))) (list (call-n g 1001) (apply g (upto 1003)))))) '((0 1000 ()) (0 1000 (1001 1002))))
(row! '(loop 1001) (lambda () (list (loop-n 1001))) '(3 1000))
(row! '(noloop 1001) (lambda () (list (noloop-n 1001))) '(3 1000))
(row! '(values 1001) (lambda () (list (call-with-values (lambda () (apply values (upto 1001))) (fixed-n 1001)))) '(0 1000))
(row! '(order 1001) (lambda () (list (traced (lambda () (car (list (order-n count-args 1001))))))) (list 1001 (cons 'callee (upto 1001))))

;; ---- N = 2000

(row! '(list 2000) (lambda () (list (call-n list 2000))) (upto 2000))
(row! '(vector 2000) (lambda () (list (let ((v (call-n vector 2000))) (list (vector-length v) (vector-ref v 0) (vector-ref v 1999))))) '(2000 0 1999))
(row! '(variadic 2000) (lambda () (list (call-n count-args 2000))) 2000)
(row! '(variadic-2 2000) (lambda () (list (call-n two-and-rest 2000))) '(0 1 1998))
(define-fixed fixed-2000 2000)
(row! '(fixed direct 2000) (lambda () (list (call-n fixed-2000 2000))) '(0 1999))
(row! '(fixed value 2000) (lambda () (list (let ((g fixed-2000)) (call-n g 2000)))) '(0 1999))
(row! '(fixed apply 2000) (lambda () (list (apply fixed-2000 (upto 2000)))) '(0 1999))
(row! '(fixed eq 2000) (lambda () (list (let ((a fixed-2000) (b fixed-2000)) (list (eq? a b) (eq? fixed-2000 fixed-2000) (procedure? a))))) '(#t #t #t))
(define-dotted dotted-2000 2000)
(row! '(dotted exact 2000) (lambda () (list (call-n dotted-2000 2000))) '(0 1999 ()))
(row! '(dotted more 2000) (lambda () (list (apply dotted-2000 (upto 2002)))) '(0 1999 (2000 2001)))
(row! '(dotted value 2000) (lambda () (list (let ((g dotted-2000)) (apply g (upto 2001))))) '(0 1999 (2000)))
(row! '(lambda direct 2000) (lambda () (list (apply-direct 2000))) '(0 1999))
(row! '(lambda value 2000) (lambda () (list (let ((g (fixed-n 2000))) (call-n g 2000)))) '(0 1999))
(row! '(lambda apply 2000) (lambda () (list (apply (fixed-n 2000) (upto 2000)))) '(0 1999))
(row! '(lambda rest 2000) (lambda () (list (let ((g (dotted-n 2000))) (list (call-n g 2000) (apply g (upto 2002)))))) '((0 1999 ()) (0 1999 (2000 2001))))
(row! '(loop 2000) (lambda () (list (loop-n 2000))) '(3 1999))
(row! '(noloop 2000) (lambda () (list (noloop-n 2000))) '(3 1999))
(row! '(values 2000) (lambda () (list (call-with-values (lambda () (apply values (upto 2000))) (fixed-n 2000)))) '(0 1999))
(row! '(order 2000) (lambda () (list (traced (lambda () (car (list (order-n count-args 2000))))))) (list 2000 (cons 'callee (upto 2000))))

;; ---- once

(row! 'nested (lambda () (list (nested-n count-args 1000 (apply-direct 37)))) 1000)
(row! 'surplus (lambda () (list (guard (c (#t 'raised)) (apply (fixed-n 1000) (upto 1001))))) '(0 999))

(for-each (lambda (r) (want (car r) ((cadr r)) (list (caddr r)))) (reverse rows))
(display (if (null? fails) #t (reverse fails)))
