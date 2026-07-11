;; schwasm compiler entry point for the self-hosted build: this file
;; is appended to compiler.ss and the result is compiled to wasm.
;; The input stream carries the forms of prelude+program; the wasm
;; bytes of the compiled module go to the output.
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.

(define (%compile-input)
  (let loop ((acc '()))
    (let ((form (read)))
      (if (eof-object? form)
          (for-each (lambda (b) (%write-byte b))
                    (compile-program (reverse acc)))
          (loop (cons form acc))))))

(%compile-input)
