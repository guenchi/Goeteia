;; Chez-hosted product instrument.  Loads the compiler the way chez-driver
;; does and prints, for one fixture, the compiler PRODUCTS a compiled cell
;; cannot see: which parameters *fn-specs* classified as f64.  Used by
;; test/c02-product-fn-specs.mjs.  Usage:
;;   chez --script test/lib/c02-products.sc <tree-root> <fixture.ss>
;;
;; Its known answer on test/c02-products-fixture.ss is (run #f #t);
;; disabling compute-fn-specs! makes it (), and both were seen before
;; this was trusted.  It reads *fn-specs* after prepare-program, because
;; compile-program-wasm clears the table at its end.
(define here (string-append (car (command-line-arguments)) "/src"))
(define (%abort) (error 'goeteia "compilation failed"))
(define (errorf who msg . irritants) (apply error who msg irritants))
(load (string-append here "/compiler.ss"))
(load (string-append here "/js-backend.ss"))
(define (read-all path)
  (call-with-input-file path (lambda (p) (let loop ((acc '())) (let ((f (read p))) (if (eof-object? f) (reverse acc) (loop (cons f acc))))))))
(define prelude (read-all (string-append here "/prelude.ss")))
(define user (cdr (read-all (cadr (command-line-arguments)))))
(define forms (append prelude (list '(%prelude-end)) user))
(define locs (map (lambda (f) "?:0") forms))
;; run the whole pipeline once for its side effects (prelude marker, embed state),
;; then run the analysis seam again on the prepared forms and read the products
;; BEFORE compile-program-wasm's final reset clears them.
(define bytes (compile-program forms locs))
(display (list 'wasm-bytes (length bytes))) (newline)
(define prep (prepare-program forms locs))
(display (list 'prepared-fn-defs (map (lambda (d) (car (cadr d))) (filter (lambda (d) (and (pair? d) (eq? (car d) 'define) (pair? (cadr d)))) (caddr prep))))) (newline)
(display (list 'fn-specs-after-prepare (filter (lambda (e) (memq (car e) '(norm twice run))) *fn-specs*))) (newline)
