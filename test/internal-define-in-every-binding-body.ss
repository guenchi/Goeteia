;; expect: (7 7 7 7 7 7 7 7 7 7 7 7 7 7 7 7 7 7 7 (4 2 0))
;; Every binding form's body is an R6RS <body>, so it may open with
;; definitions.
;;
;; let, named let, lambda, let-values and let*-values accepted them;
;; let*, letrec and letrec* did not -- the definition's name was
;; reported unbound.  let* lowered its innermost level to a (begin ...)
;; in expression position, and letrec / letrec* placed the body after
;; the assignments that initialise the bindings, so in both the
;; definitions stood where the body's definitions are not collected.
;; The compiler's own source met this.
;;
;; Each element of the answer is one form; all must be 7.  The rows
;; that separate a correct fix from a near miss:
;;   let* with no bindings, and with one -- the innermost level is the
;;     whole body;
;;   let* whose second binding shadows its first -- the fix must keep
;;     let*'s sequential scope;
;;   a definition in a let* body that shadows a let* variable -- the
;;     body is a scope of its own;
;;   letrec with mutually recursive bindings the definition calls, and
;;     letrec* whose later binding reads an earlier one;
;;   a value definition followed by a function definition that reads it;
;;   two body definitions that call each other, in let*, letrec and
;;     letrec* -- body definitions bind recursively (letrec* scope), so
;;     a fix that lowered them as a sequence of nested lets would pass
;;     every other row and fail these three;
;;   the last, a list: a closure defined in a let* body inside a loop
;;     captures that iteration's binding, not a shared one.
;;
;; Inside a macro transformer no body accepts definitions at all (the
;; transformer interpreter is a smaller language); that is a different
;; item and no row here reads it.
;;
;; ON THE TREE BEFORE THE CHANGE this cell does not compile (unbound
;; variable: g).
(import (rnrs))

(display
 (list
  (let ((a 1) (b 2)) (define (g) (+ a b 4)) (g))
  (let* ((a 1) (b 2)) (define (g) (+ a b 4)) (g))
  (let* () (define (g) 7) (g))
  (let* ((a 3)) (define (g) (+ a 4)) (g))
  (let* ((a 1) (a (+ a 6))) (define (g) a) (g))
  (let* ((a 1)) (define a 7) a)
  (let* ((a 1)) (define x 6) (+ a x))
  (let* ((a 1)) (define x 2) (define (g) (+ a x 4)) (g))
  (letrec ((a 1)) (define (g) (+ a 6)) (g))
  (letrec ((ev? (lambda (n) (if (= n 0) #t (od? (- n 1)))))
           (od? (lambda (n) (if (= n 0) #f (ev? (- n 1))))))
    (define (g) (if (ev? 4) 7 0))
    (g))
  (letrec* ((a 1)) (define (g) (+ a 6)) (g))
  (letrec* ((a 1) (b (+ a 2))) (define c (+ b 4)) c)
  (let* ((a 1))
    (define (ev? n) (if (= n 0) #t (od? (- n 1))))
    (define (od? n) (if (= n 0) #f (ev? (- n 1))))
    (if (ev? 4) 7 0))
  (letrec ((a 1))
    (define (ev? n) (if (= n 0) #t (od? (- n 1))))
    (define (od? n) (if (= n 0) #f (ev? (- n 1))))
    (if (ev? 4) 7 0))
  (letrec* ((a 1))
    (define (ev? n) (if (= n 0) #t (od? (- n 1))))
    (define (od? n) (if (= n 0) #f (ev? (- n 1))))
    (if (ev? 4) 7 0))
  (let loop ((i 0)) (define (g) (+ i 7)) (g))
  ((lambda (a) (define (g) (+ a 6)) (g)) 1)
  (let-values (((a b) (values 1 2))) (define (g) (+ a b 4)) (g))
  (let*-values (((a b) (values 1 2))) (define (g) (+ a b 4)) (g))
  (let loop ((i 0) (acc '()))
    (if (= i 3)
        (map (lambda (f) (f)) acc)
        (let* ((j (* i 2)))
          (define (g) j)
          (loop (+ i 1) (cons g acc)))))))
