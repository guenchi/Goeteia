;; Copyright 2026 guenchi
;;
;; Licensed under the Apache License, Version 2.0 (the "License");
;; you may not use this file except in compliance with the License.
;; You may obtain a copy of the License at
;;
;;     http://www.apache.org/licenses/LICENSE-2.0
;;
;; Unless required by applicable law or agreed to in writing, software
;; distributed under the License is distributed on an "AS IS" BASIS,
;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;; See the License for the specific language governing permissions and
;; limitations under the License.

;; goeteia compiler entry point for the self-hosted build: this file
;; is appended to compiler.ss and the result is compiled to wasm.
;; The input stream carries the forms of prelude+program; the wasm
;; bytes of the compiled module go to the output.
;;
;; The stream may carry (%loc "file" line) markers (rt/compile.mjs
;; inserts them at file boundaries): they map stream lines back to
;; source lines so compile errors can say file:line.  A marker-free
;; stream still gets stream line numbers.

(define (%compile-input)
  (let loop ((acc '()) (locs '()) (file "input") (offset 0))
    (let ((form (read)))
      (cond
       ((eof-object? form)
        (for-each (lambda (b) (%write-byte b))
                  (compile-program (reverse acc) (reverse locs))))
       ((and (pair? form) (eq? (car form) '%loc))
        ;; the next stream line is line (caddr form) of (cadr form)
        (let ((off (- (+ $reader-line 1) (caddr form))))
          ;; hand the same mapping to the reader: an error raised
          ;; while reading the NEXT form is reported before any of
          ;; the machinery below runs, so the reader has to be able
          ;; to name the file and line on its own
          (set! $reader-file (cadr form))
          (set! $reader-line-origin off)
          (loop acc locs (cadr form) off)))
       ((and (pair? form) (eq? (car form) '%opt))
        ;; (%opt 0) -- script mode: the optimization passes stand down
        (set! *opt-level* (cadr form))
        (loop acc locs file offset))
       ((and (pair? form) (eq? (car form) '%target))
        ;; (%target js) -- emit JavaScript instead of wasm
        (set! *target* (cadr form))
        (loop acc locs file offset))
       (else
        (loop (cons form acc)
              (cons (string-append
                     file ":"
                     (number->string (- $reader-datum-line offset)))
                    locs)
              file offset))))))

(%compile-input)
