;; expect: (#t #t #t #t #t #f #f #t #f #t #t #t #t #t #t #t #t #t)
;; A quoted pair or vector is one object: evaluating the same quote
;; twice gives the same object (R6RS 11.4.1: a quote evaluates to the
;; datum its text represents).
;;
;; Each quoted compound literal was rebuilt every time its expression
;; ran, so (eq? (f) (f)) was #f on both back ends where Chez answers #t.
;; It is now built once, as a constant, before the program starts.
;;
;; The rows, in order:
;;   1  a list returned by a function the inliner copies to both call
;;      sites -- identity must survive the copy;
;;   2  the same through a function the inliner refuses (its body holds a
;;      let), so the call itself returns the constant;
;;   3  a vector literal;
;;   4  an element of a nested literal (a vector of lists);
;;   5  a literal in a library's exported procedure;
;;   6  two textually equal literals are two objects (no coalescing);
;;   7  a quasiquote with nothing unquoted still builds a fresh list each
;;      time -- a template, not a constant;
;;   8  one macro expansion, called twice: one object;
;;   9  two expansions of one macro template: two objects;
;;  10  a literal inside a named-let loop body, across iterations;
;; and what the constants HOLD, against values built at run time, so
;; that a constant with the wrong contents cannot pass on identity alone:
;;  11  the list of row 1;
;;  12  the nested vector of row 4, element by element;
;;  13  a dotted literal: one object, and its contents;
;;  14  a literal whose parts need other constants -- a string, a flonum,
;;      a bignum, a ratio, an exact complex, a character, a symbol, a
;;      vector holding a string, the empty list, a boolean -- one object,
;;      and every part;
;;  15  a quasiquote with an unquote and a quoted part: the template is
;;      fresh each time, the quoted part inside it is one object;
;;  16  a conjure body compiles to the same text whether or not another
;;      body with literals of its own was compiled before it in the same
;;      program: each embedded compilation has its own constants;
;;  17  the same for a wasm-target conjure body, whose constants are
;;      globals with their own indices.
;;  18  a VARIABLE named quote is not a literal: bound by let, as a
;;      lambda formal, as a named let's binding and passed as an argument,
;;      (quote ...) there is a binding entry or an argument list, not a
;;      quote expression, and only a quote in expression position is a
;;      constant.
;; The embedded programs are not run here: they are compiled by the same
;; path as a whole program, whose constants rows 1-15 read on every
;; compiler; rows 16 and 17 read what is particular to an embedded
;; compilation, that one does not see another's table.
;;
;; The rows read the policy this compiler follows where R6RS leaves a
;; choice: equal literals are not merged (6), a quasiquote template is
;; built afresh (7), and two expansions of one macro template are two
;; occurrences (9).
;;
;; test/large-literal-stays-out-of-main.mjs reads this file's prepared
;; shape: lit-inlined's calls are inlined and lit-kept's are not, so rows
;; 1 and 2 reach the constant by both paths.
;;
;; ON THE TREE BEFORE THE CHANGE rows 1-5, 8, 10 and 13-15 are #f.
(import (rnrs))

(begin
  (library (lit one)
    (export lit)
    (import (rnrs))
    (define (lit) '(lib 1 2)))
  (import (lit one)))

(define (lit-inlined) '(1 2))
(define (lit-kept) (let ((x '(1 2))) x))
(define (v) '#(1 2))
(define (n) '#((1 2) (3)))
(define-syntax m (syntax-rules () ((_) '(7 8))))
(define (a) (m))
(define (b) (m))
(define (q) `(1 2))
(define (d) '(1 2 . 3))
(define (p) '("s" 1.5 123456789012345678901234567890 1/3 1+2i #\a sym #(1 "t") () #t))
(define (u x) `(a ,x ,'(k)))
(define sB0 (conjure js (import (rnrs)) (define (kb) '(b 1 #(2 "x"))) (display (car (kb)))))
(define sA (conjure js (import (rnrs)) (define (ka) '(a 9 9 9)) (display (car (ka)))))
(define sB1 (conjure js (import (rnrs)) (define (kb) '(b 1 #(2 "x"))) (display (car (kb)))))
(define sW0 (conjure wasm (import (rnrs)) (define (kw) '(w 1 #(2 "y"))) (display (car (kw)))))
(define sV (conjure wasm (import (rnrs)) (define (kv) '(v 8 8 8)) (display (car (kv)))))
(define sW1 (conjure wasm (import (rnrs)) (define (kw) '(w 1 #(2 "y"))) (display (car (kw)))))

(display
 (list (eq? (lit-inlined) (lit-inlined))
       (eq? (lit-kept) (lit-kept))
       (eq? (v) (v))
       (eq? (vector-ref (n) 0) (vector-ref (n) 0))
       (eq? (lit) (lit))
       (eq? '(1 2) '(1 2))
       (eq? (q) (q))
       (eq? (a) (a))
       (eq? (a) (b))
       (let loop ((i 0) (prev #f))
         (let ((x '(9 9)))
           (cond ((= i 3) #t)
                 ((and prev (not (eq? prev x))) #f)
                 (else (loop (+ i 1) x)))))
       (equal? (lit-inlined) (list 1 2))
       (equal? (n) (vector (list 1 2) (list 3)))
       (and (eq? (d) (d)) (equal? (d) (cons 1 (cons 2 3))))
       (and (eq? (p) (p))
            (equal? (p) (list (string #\s) (+ 1.0 0.5)
                              (+ (* 123456789012345 1000000000000000) 678901234567890)
                              (/ 1 3) (make-rectangular 1 2) (integer->char 97)
                              (string->symbol "sym") (vector 1 (string #\t)) '() #t)))
       (and (not (eq? (u 1) (u 1)))
            (eq? (caddr (u 1)) (caddr (u 1)))
            (equal? (u 1) (list 'a 1 (list 'k))))
       (string=? sB0 sB1)
       (string=? sW0 sW1)
       (equal? (list (let ((quote (cons 7 8))) (car quote))
                     ((lambda (quote) (car quote)) (cons 7 8))
                     (let loop ((quote (cons 7 8)) (i 0))
                       (if (= i 1) (car quote) (loop quote (+ i 1)))))
               (list 7 7 7))))
