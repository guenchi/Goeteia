;; goeteia compiler driver for the Chez Scheme host.
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.

(import (chezscheme))

;; the core calls (%abort) through errorf-compatible error reporting
(define (%abort) (error 'goeteia "compilation failed"))

(define here (path-parent (car (command-line))))
(load (string-append here "/compiler.ss"))
(load (string-append here "/js-backend.ss"))

(define (read-forms port)
  (let ((form (read port)))
    (if (eof-object? form)
        '()
        (cons form (read-forms port)))))

(define (read-file-forms path)
  ;; read the source as raw bytes (latin-1: one byte = one char) so
  ;; multi-byte UTF-8 in string literals survives verbatim, matching
  ;; the self-hosted byte reader -- otherwise Chez decodes UTF-8 to
  ;; code points and compile-datum truncates them, and the two hosts
  ;; disagree on every non-ASCII literal.
  ;;
  ;; One wrinkle: r6rs readers normalize line endings inside string
  ;; literals, and #x85 (NEL) and #x0D (CR) are line endings -- but
  ;; they are also UTF-8 continuation bytes (U+5185 "nei" ends in
  ;; #x85).  Escape them as hex escapes inside strings, and blank
  ;; them in line comments so a NEL cannot end a comment early.
  ;;
  ;; The same scan records each top-level form's start line; the
  ;; result is a list of (line . form).
  (let* ((bv (call-with-port (open-file-input-port path)
               get-bytevector-all))
         (n (bytevector-length bv))
         (out (open-output-string))
         (lines '()))
    (let scan ((i 0) (mode 'code) (line 1) (depth 0))
      (when (< i n)
        (let* ((b (bytevector-u8-ref bv i))
               (line (if (= b 10) (+ line 1) line)))
          (case mode
            ((code)
             (cond
              ((= b 34) (put-char out #\") (scan (+ i 1) 'str line depth))
              ((= b 59) (put-char out #\;) (scan (+ i 1) 'cmt line depth))
              ((and (= b 35) (< (+ i 1) n)
                    (= (bytevector-u8-ref bv (+ i 1)) 92))
               ;; #\x -- copy the literal char blindly so #\" or #\;
               ;; cannot flip the mode
               (put-char out #\#) (put-char out #\\)
               (when (< (+ i 2) n)
                 (put-char out (integer->char (bytevector-u8-ref bv (+ i 2)))))
               (scan (+ i 3) 'code line depth))
              ((= b 40)
               (when (= depth 0) (set! lines (cons line lines)))
               (put-char out #\()
               (scan (+ i 1) 'code line (+ depth 1)))
              ((= b 41)
               (put-char out #\))
               (scan (+ i 1) 'code line (- depth 1)))
              (else (put-char out (integer->char b))
                    (scan (+ i 1) 'code line depth))))
            ((str)
             (cond
              ((= b 92)                 ; copy an escape pair verbatim
               (put-char out #\\)
               (when (< (+ i 1) n)
                 (put-char out (integer->char (bytevector-u8-ref bv (+ i 1)))))
               (scan (+ i 2) 'str line depth))
              ((= b 34) (put-char out #\") (scan (+ i 1) 'code line depth))
              ((= b #x85) (put-string out "\\x85;") (scan (+ i 1) 'str line depth))
              ((= b #x0D) (put-string out "\\xD;") (scan (+ i 1) 'str line depth))
              (else (put-char out (integer->char b))
                    (scan (+ i 1) 'str line depth))))
            ((cmt)
             (cond
              ((= b 10) (put-char out #\newline) (scan (+ i 1) 'code line depth))
              ((or (= b #x85) (= b #x0D))
               (put-char out #\space) (scan (+ i 1) 'cmt line depth))
              (else (put-char out (integer->char b))
                    (scan (+ i 1) 'cmt line depth))))))))
    (let ((forms (call-with-port
                  (open-string-input-port (get-output-string out))
                  read-forms)))
      (let zip ((fs forms) (ls (reverse lines)) (acc '()))
        (if (null? fs)
            (reverse acc)
            (zip (cdr fs) (if (pair? ls) (cdr ls) '())
                 (cons (cons (if (pair? ls) (car ls) 0) (car fs)) acc)))))))

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
          (errorf 'goeteia "library not found: ~s" spec)
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
  (and (pair? spec) (memq (car spec) '(rnrs goeteia))))
(define (load-library spec dirs)
  (if (or (builtin-library? spec) (member spec visited))
      '()
      (begin
        (set! visited (cons spec visited))
        (let* ((path (library-file spec dirs))
               (lf (car (read-file-forms path))))
          (append (load-specs (library-imports (cdr lf)) dirs)
                  (list (cons (string-append path ":"
                                             (number->string (car lf)))
                              (cdr lf))))))))
(define (spec-target spec)
  ;; (only L ...) (except L ...) (rename L (old new) ...) -> L
  (if (memq (car spec) '(only except rename prefix))
      (cadr spec)
      spec))
(define (spec-aliases spec)
  ;; rename introduces top-level aliases; only/except are advisory in
  ;; the flat-splice model (dead code elimination prunes the unused)
  (if (eq? (car spec) 'rename)
      (map (lambda (pr) (cons "?:0" `(define ,(cadr pr) ,(car pr))))
           (cddr spec))
      '()))
(define (load-specs specs dirs)
  ;; explicitly sequenced: the order load-library marks `visited`
  ;; must be the structural order, not the host's argument order
  (if (null? specs)
      '()
      (let* ((lib (load-library (spec-target (car specs)) dirs))
             (aliases (spec-aliases (car specs)))
             (rest (load-specs (cdr specs) dirs)))
        (append lib aliases rest))))
(define (resolve-imports pairs file dirs)
  ;; pairs: (line . form); result: ("file:line" . form)
  (let loop ((fs pairs) (acc '()))
    (cond
     ((null? fs) (reverse acc))
     ((and (pair? (cdar fs)) (eq? (car (cdar fs)) '%opt))
      ;; (%opt 0) -- script mode: skip the optimization passes
      (set! *opt-level* (cadr (cdar fs)))
      (loop (cdr fs) acc))
     ((and (pair? (cdar fs)) (eq? (car (cdar fs)) 'import))
      (loop (cdr fs)
            (append (reverse (load-specs (cdr (cdar fs)) dirs)) acc)))
     (else
      (loop (cdr fs)
            (cons (cons (string-append file ":"
                                       (number->string (caar fs)))
                        (cdar fs))
                  acc))))))

;; expand the imports at the top level of conjure bodies, each
;; embed in a fresh import scope (the host program's libraries are
;; spliced into the host, not into the independently compiled embed
;; unit; nested embeds get their own scope too), mirroring
;; rt/compile.mjs's per-block text resolution
(define (embed-splice-imports form dirs)
  (cond
   ((not (pair? form)) form)
   ((eq? (car form) 'quote) form)
   ((memq (car form) '(conjure define-js define-wasm define-wasm-inline
                       define-wasm-js define-wasm-js-inline))
    (let* ((saved visited)
           (body (begin
                   (set! visited '())
                   (let loop ((bs (cddr form)) (acc '()))
                     (cond
                      ((null? bs) (reverse acc))
                      ((and (pair? (car bs)) (eq? (car (car bs)) 'import))
                       (loop (cdr bs)
                             (append (reverse (map cdr (load-specs
                                                        (cdr (car bs)) dirs)))
                                     acc)))
                      (else
                       (loop (cdr bs)
                             (cons (embed-splice-imports (car bs) dirs)
                                   acc))))))))
      (set! visited saved)
      (cons (car form) (cons (cadr form) body))))
   (else (cons (embed-splice-imports (car form) dirs)
               (embed-splice-imports (cdr form) dirs)))))

;; the runtime glue a conjure section inlines: jsbridge + web.mjs
;; with the module plumbing stripped, non-ASCII normalized -- must
;; produce the identical string to rt/compile.mjs's conjureGlue
(define (conjure-glue-text)
  (define (read-bytes path)
    (call-with-port (open-file-input-port path) get-bytevector-all))
  (define (import-line? bv i)
    ;; a line starting (after whitespace) with "import" and
    ;; containing "jsbridge"
    (let scan ((j i) (seen-import #f) (seen-bridge #f))
      (if (or (>= j (bytevector-length bv))
              (= (bytevector-u8-ref bv j) 10))
          (and seen-import seen-bridge)
          (let ((b (bytevector-u8-ref bv j)))
            (cond
             ((and (not seen-import)
                   (or (= b 32) (= b 9)))
              (scan (+ j 1) seen-import seen-bridge))
             ((and (not seen-import) (= b 105)  ; i
                   (< (+ j 5) (bytevector-length bv))
                   (= (bytevector-u8-ref bv (+ j 1)) 109)
                   (= (bytevector-u8-ref bv (+ j 2)) 112)
                   (= (bytevector-u8-ref bv (+ j 3)) 111)
                   (= (bytevector-u8-ref bv (+ j 4)) 114)
                   (= (bytevector-u8-ref bv (+ j 5)) 116))
              (scan (+ j 6) #t seen-bridge))
             ((not seen-import) #f)
             ((and (= b 106)                    ; j
                   (< (+ j 7) (bytevector-length bv))
                   (= (bytevector-u8-ref bv (+ j 1)) 115)
                   (= (bytevector-u8-ref bv (+ j 2)) 98)
                   (= (bytevector-u8-ref bv (+ j 3)) 114)
                   (= (bytevector-u8-ref bv (+ j 4)) 105)
                   (= (bytevector-u8-ref bv (+ j 5)) 100)
                   (= (bytevector-u8-ref bv (+ j 6)) 103)
                   (= (bytevector-u8-ref bv (+ j 7)) 101))
              (scan (+ j 8) seen-import #t))
             (else (scan (+ j 1) seen-import seen-bridge)))))))
  (define (line-start-of bv i)
    ;; is i at a line start followed by "export "?
    (and (< (+ i 6) (bytevector-length bv))
         (= (bytevector-u8-ref bv i) 101)
         (= (bytevector-u8-ref bv (+ i 1)) 120)
         (= (bytevector-u8-ref bv (+ i 2)) 112)
         (= (bytevector-u8-ref bv (+ i 3)) 111)
         (= (bytevector-u8-ref bv (+ i 4)) 114)
         (= (bytevector-u8-ref bv (+ i 5)) 116)
         (= (bytevector-u8-ref bv (+ i 6)) 32)))
  (define (process bv out at-line-start)
    (let ((n (bytevector-length bv)))
      (let loop ((i 0) (bol #t))
        (when (< i n)
          (cond
           ((and bol (import-line? bv i))
            ;; skip the whole line including its newline
            (let eat ((j i))
              (cond
               ((>= j n) (loop n #f))
               ((= (bytevector-u8-ref bv j) 10) (loop (+ j 1) #t))
               (else (eat (+ j 1))))))
           ((and bol (line-start-of bv i))
            (loop (+ i 7) #f))            ; drop "export "
           (else
            (let ((b (bytevector-u8-ref bv i)))
              (put-char out (integer->char (if (> b 126) 32 b)))
              (loop (+ i 1) (= b 10)))))))))
  (let ((out (open-output-string)))
    (process (read-bytes (string-append here "/../rt/jsbridge.mjs")) out #t)
    (put-char out #\newline)
    (process (read-bytes (string-append here "/../rt/web.mjs")) out #t)
    (get-output-string out)))

(define (compile-file in out)
  ;; the prelude is prepended to every program; later definitions
  ;; shadow earlier ones, so user code can redefine prelude bindings
  (let* ((in-dir (or (path-parent in) "."))
         (dirs (list in-dir
                     (string-append in-dir "/lib")
                     (string-append here "/../lib")))
         (prelude-path (string-append here "/prelude.ss"))
         (tagged (append
                  (map (lambda (lf)
                         (cons (string-append prelude-path ":"
                                              (number->string (car lf)))
                               (cdr lf)))
                       (read-file-forms prelude-path))
                  (list (cons "?:0" (list '%conjure-rt (conjure-glue-text)))
                        (cons "?:0" '(%prelude-end)))
                  (map (lambda (p)
                         (cons (car p)
                               (embed-splice-imports (cdr p) dirs)))
                       (resolve-imports (read-file-forms in) in dirs))))
         (bytes (compile-program (map cdr tagged) (map car tagged))))
    (when (file-exists? out) (delete-file out))
    (call-with-port (open-file-output-port out)
      (lambda (p) (put-bytevector p (u8-list->bytevector bytes))))))

(let* ((raw (cdr (command-line)))
       (args (filter (lambda (a) (not (string=? a "--js"))) raw)))
  (when (member "--js" raw) (set! *target* 'js))
  (if (or (null? args) (null? (cdr args)))
      (begin (display "usage: goeteiac [--js] <input.ss> <output.wasm|.js>\n")
             (exit 1))
      (compile-file (car args) (cadr args))))
