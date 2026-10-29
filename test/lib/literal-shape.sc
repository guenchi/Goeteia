;; Chez-hosted shape instrument for test/large-literal-stays-out-of-main.mjs.
;; Loads the compiler the way test/lib/c02-products.sc does, runs
;; prepare-program on one fixture, and prints how many call sites of each
;; named function survive into the prepared forms -- the shape a compiled
;; cell cannot see: whether the inliner copied a function's body to its
;; call sites or left the calls.  Usage:
;;   chez --script test/lib/literal-shape.sc <tree-root> <fixture.ss> name...
;; prints (calls (name . n) ...).
(define here (string-append (car (command-line-arguments)) "/src"))
(define (%abort) (error 'goeteia "compilation failed"))
(define (errorf who msg . irritants) (apply error who msg irritants))
(load (string-append here "/compiler.ss"))
(load (string-append here "/js-backend.ss"))
(define (read-all path)
  (call-with-input-file path
    (lambda (p) (let loop ((acc '())) (let ((f (read p))) (if (eof-object? f) (reverse acc) (loop (cons f acc))))))))
(define prelude (read-all (string-append here "/prelude.ss")))
(define user (read-all (cadr (command-line-arguments))))
(define names (map string->symbol (cddr (command-line-arguments))))
;; the whole pipeline once, for its side effects, as c02-products.sc does;
;; then prepare-program again on the split forms, and the prepared forms
;; are read before anything later can clear them
(compile-program (append prelude (list '(%prelude-end)) user)
                 (map (lambda (f) "?:0") (append prelude (list '(%prelude-end)) user)))
(set! *prelude-prefix-n* (length prelude))
(define prepared (prepare-program (append prelude user) (map (lambda (f) "?:0") (append prelude user))))
;; (list export-names forms fn-defs var-defs main-steps): count, in the
;; forms, the pairs whose head is the name -- quoted data and definition
;; heads excepted.  The prelude is in the forms too, so a fixture names its
;; functions with spellings the prelude does not use.
(define (count-calls name x)
  (cond ((not (pair? x)) 0)
        ((and (symbol? (car x)) (eq? (resolve-tag (car x)) 'quote)) 0)
        ;; a definition's head is not a call: count its body only
        ((and (symbol? (car x)) (eq? (resolve-tag (car x)) 'define) (pair? (cdr x)) (pair? (cadr x)))
         (let loop ((y (cddr x)) (n 0))
           (if (pair? y) (loop (cdr y) (+ n (count-calls name (car y)))) n)))
        (else (+ (if (and (symbol? (car x)) (eq? (strip-marks (car x)) name)) 1 0)
                 (let loop ((y x) (n 0))
                   (if (pair? y) (loop (cdr y) (+ n (count-calls name (car y)))) n))))))
(display (list 'calls (map (lambda (n) (cons n (count-calls n (cadr prepared)))) names)))
(newline)
