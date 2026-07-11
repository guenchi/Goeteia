;; schwasm compiler driver for the Chez Scheme host.
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.

(import (chezscheme))

;; the core calls (%abort) through errorf-compatible error reporting
(define (%abort) (error 'schwasm "compilation failed"))

(define here (path-parent (car (command-line))))
(load (string-append here "/compiler.ss"))

(define (read-forms port)
  (let ((form (read port)))
    (if (eof-object? form)
        '()
        (cons form (read-forms port)))))

(define (read-file-forms path)
  (call-with-input-file path read-forms))

(define (compile-file in out)
  ;; the prelude is prepended to every program; later definitions
  ;; shadow earlier ones, so user code can redefine prelude bindings
  (let* ((forms (append (read-file-forms (string-append here "/prelude.ss"))
                        (read-file-forms in)))
         (bytes (compile-program forms)))
    (when (file-exists? out) (delete-file out))
    (call-with-port (open-file-output-port out)
      (lambda (p) (put-bytevector p (u8-list->bytevector bytes))))))

(let ((args (cdr (command-line))))
  (if (or (null? args) (null? (cdr args)))
      (begin (display "usage: schwasmc <input.ss> <output.wasm>\n")
             (exit 1))
      (compile-file (car args) (cadr args))))
