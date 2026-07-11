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

;; ---- library resolution ----
;; (import (math utils)) reads math/utils.ss -- a single (library ...)
;; form -- resolving its own imports first; each library inlines once.

(define visited '())
(define (library-file spec dirs)
  (let ((rel (fold-left (lambda (acc part)
                          (string-append acc (if (string=? acc "") "" "/")
                                         (symbol->string part)))
                        "" spec)))
    (let scan ((ds dirs))
      (if (null? ds)
          (errorf 'schwasm "library not found: ~s" spec)
          (let ((path (string-append (car ds) "/" rel ".ss")))
            (if (file-exists? path) path (scan (cdr ds))))))))
(define (library-imports lib)
  (let scan ((cs (cddr lib)))
    (cond
     ((null? cs) '())
     ((and (pair? (car cs)) (eq? (car (car cs)) 'import)) (cdr (car cs)))
     (else (scan (cdr cs))))))
(define (builtin-library? spec)
  ;; provided by the prelude, compiled into every module
  (and (pair? spec) (memq (car spec) '(rnrs schwasm))))
(define (load-library spec dirs)
  (if (or (builtin-library? spec) (member spec visited))
      '()
      (begin
        (set! visited (cons spec visited))
        (let ((form (car (read-file-forms (library-file spec dirs)))))
          (append (load-specs (library-imports form) dirs)
                  (list form))))))
(define (spec-target spec)
  ;; (only L ...) (except L ...) (rename L (old new) ...) -> L
  (if (memq (car spec) '(only except rename prefix))
      (cadr spec)
      spec))
(define (spec-aliases spec)
  ;; rename introduces top-level aliases; only/except are advisory in
  ;; the flat-splice model (dead code elimination prunes the unused)
  (if (eq? (car spec) 'rename)
      (map (lambda (pr) `(define ,(cadr pr) ,(car pr))) (cddr spec))
      '()))
(define (load-specs specs dirs)
  (if (null? specs)
      '()
      (append (load-library (spec-target (car specs)) dirs)
              (spec-aliases (car specs))
              (load-specs (cdr specs) dirs))))
(define (resolve-imports forms dirs)
  (let loop ((fs forms) (acc '()))
    (cond
     ((null? fs) (reverse acc))
     ((and (pair? (car fs)) (eq? (car (car fs)) 'import))
      (loop (cdr fs)
            (append (reverse (load-specs (cdr (car fs)) dirs)) acc)))
     (else (loop (cdr fs) (cons (car fs) acc))))))

(define (compile-file in out)
  ;; the prelude is prepended to every program; later definitions
  ;; shadow earlier ones, so user code can redefine prelude bindings
  (let* ((in-dir (or (path-parent in) "."))
         (dirs (list in-dir
                     (string-append in-dir "/lib")
                     (string-append here "/../lib")))
         (forms (append (read-file-forms (string-append here "/prelude.ss"))
                        (resolve-imports (read-file-forms in) dirs)))
         (bytes (compile-program forms)))
    (when (file-exists? out) (delete-file out))
    (call-with-port (open-file-output-port out)
      (lambda (p) (put-bytevector p (u8-list->bytevector bytes))))))

(let ((args (cdr (command-line))))
  (if (or (null? args) (null? (cdr args)))
      (begin (display "usage: schwasmc <input.ss> <output.wasm>\n")
             (exit 1))
      (compile-file (car args) (cadr args))))
