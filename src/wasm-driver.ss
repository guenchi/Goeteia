;; goeteia compiler entry point for the self-hosted build: this file
;; is appended to compiler.ss and the result is compiled to wasm.
;; The input stream carries the forms of prelude+program; the wasm
;; bytes of the compiled module go to the output.
;;
;; The stream may carry (%loc "file" line) markers (rt/compile.mjs
;; inserts them at file boundaries): they map stream lines back to
;; source lines so compile errors can say file:line.  A marker-free
;; stream still gets stream line numbers.
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.

(define (%compile-input)
  (let loop ((acc '()) (locs '()) (file "input") (offset 0))
    (let ((form (read)))
      (cond
       ((eof-object? form)
        (for-each (lambda (b) (%write-byte b))
                  (compile-program (reverse acc) (reverse locs))))
       ((and (pair? form) (eq? (car form) '%loc))
        ;; the next stream line is line (caddr form) of (cadr form)
        (loop acc locs (cadr form)
              (- (+ $reader-line 1) (caddr form))))
       (else
        (loop (cons form acc)
              (cons (string-append
                     file ":"
                     (number->string (- $reader-datum-line offset)))
                    locs)
              file offset))))))

(%compile-input)
