;; goeteia compiler driver for the Chez Scheme host.
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.

(import (chezscheme))

;; the core calls (%abort) through errorf-compatible error reporting
(define (%abort) (error 'goeteia "compilation failed"))

;; errorf, with the SAME contract the goeteia runtime gives it: the
;; message is text, and the irritants are written after it.
;;
;; Chez has an errorf of its own, and the compiler sources used to get
;; that one here and the prelude's one when self-hosted.  The two do
;; not agree: Chez interprets `~s` in the message and drops arguments
;; the control string does not name, while the prelude ignores the
;; message's content and appends every irritant.  So the same errorf
;; call produced "unbound variable elf-3" under this host and
;; "unbound variable ~s elf-3" under the other -- a difference no test
;; could see, because nothing compared the two hosts' diagnostics.
;;
;; Defining it here makes the contract one contract.  The message
;; texts carry no format directives, and both hosts append.
(define (errorf who msg . irritants)
  (error who
         (apply string-append msg
                (map (lambda (x) (string-append " " (format "~s" x)))
                     irritants))))

(define here (path-parent (car (command-line))))
(load (string-append here "/compiler.ss"))
(load (string-append here "/js-backend.ss"))

(define (read-forms port)
  (let ((form (read port)))
    (if (eof-object? form)
        '()
        (cons form (read-forms port)))))

(define (read-file-forms path)
  ;; Source is DECODED as UTF-8 here, and every string and symbol in the
  ;; result is re-encoded to bytes before the compiler sees it.
  ;;
  ;; It used to be read as raw bytes -- one byte, one char -- so that a
  ;; literal written in UTF-8 survived verbatim.  That worked for raw
  ;; bytes and silently failed for escapes: `\x3bb;` in the same stream
  ;; produced the CODE POINT 955, and compile-datum, which takes each
  ;; char's integer as a byte, truncated it to 187.  The old comment
  ;; here named that truncation and guarded only half of it.
  ;;
  ;; The two cannot be told apart downstream -- one byte of a UTF-8
  ;; sequence and a code point below 256 are the same char -- so the
  ;; conversion belongs at this boundary, not in the emitter.  Decode
  ;; once, and the source is code points however it was spelled;
  ;; re-encode once, and the compiler sees the byte strings it sees on
  ;; the self-hosted host.  The compiler is not told which host it is
  ;; on, which is the point.
  ;;
  ;; Decoding also retires a hack.  Line endings inside string literals
  ;; are normalised by the reader, and NEL (U+0085) is one -- but 0x85
  ;; is also a UTF-8 continuation byte, so under a byte-wise reading a
  ;; NEL was indistinguishable from the tail of U+5185, and both were
  ;; escaped blind to protect the second.  Decoded, they are one
  ;; character each and the question does not arise.
  ;;
  ;; The start line of each top-level form, for diagnostics.
  ;;
  ;; This used to be a parenthesis counter walking the whole file, and
  ;; it was wrong in five ways at once -- it did not count newlines
  ;; inside strings or line comments (so every form after one was
  ;; attributed a line early), it counted parens inside block comments
  ;; and inside |bar symbols|, and it read `#;` as a line comment.
  ;;
  ;; None of that is needed.  A form starts at the first character that
  ;; is not whitespace and not a comment, and `read` finds the end by
  ;; itself; the port's own position says where it got to.  So the only
  ;; thing to skip is NOISE, and nothing inside a datum -- no strings,
  ;; no character literals, no bars, no depth -- which is why the five
  ;; failures cannot recur here.  The line counter advances with the
  ;; scan and never rescans, so this stays linear.
  (let* ((src (decode-source path))
         (n (string-length src))
         (port (open-string-input-port src)))
    (let loop ((pos 0) (line 1) (acc '()))
      (let* ((start (skip-noise src pos n))
             (line (+ line (count-newlines src pos start))))
        (if (>= start n)
            (reverse acc)
            (begin
              (set-port-position! port start)
              (let ((form (read port)))
                (if (eof-object? form)
                    (reverse acc)
                    (loop (port-position port) line
                          (cons (cons line (host-bytes form)) acc))))))))))

;; Whitespace, `;` to end of line, and nested `#| ... |#`.  A `#;` is
;; NOT skipped: `read` handles it and answers the datum after it, and
;; stopping here means the form is attributed to the line the comment
;; starts on, which is where a reader would look for it.
(define (skip-noise src i n)
  (cond
   ((>= i n) n)
   ((char-whitespace? (string-ref src i)) (skip-noise src (+ i 1) n))
   ((char=? (string-ref src i) #\;) (skip-noise src (skip-to-eol src i n) n))
   ((and (char=? (string-ref src i) #\#) (< (+ i 1) n)
         (char=? (string-ref src (+ i 1)) #\|))
    (skip-noise src (skip-block src (+ i 2) n 1) n))
   (else i)))

(define (skip-to-eol src i n)
  (cond ((>= i n) n)
        ((char=? (string-ref src i) #\newline) (+ i 1))
        (else (skip-to-eol src (+ i 1) n))))

(define (skip-block src i n depth)       ; past the opening #|
  (cond
   ((>= i n) n)                          ; unclosed: `read` will say so
   ((and (< (+ i 1) n) (char=? (string-ref src i) #\#)
         (char=? (string-ref src (+ i 1)) #\|))
    (skip-block src (+ i 2) n (+ depth 1)))
   ((and (< (+ i 1) n) (char=? (string-ref src i) #\|)
         (char=? (string-ref src (+ i 1)) #\#))
    (if (= depth 1) (+ i 2) (skip-block src (+ i 2) n (- depth 1))))
   (else (skip-block src (+ i 1) n depth))))

(define (count-newlines src from to)
  (let loop ((i from) (k 0))
    (cond ((>= i to) k)
          ((char=? (string-ref src i) #\newline) (loop (+ i 1) (+ k 1)))
          (else (loop (+ i 1) k)))))

;; Bytes -> code points, refusing anything that is not UTF-8.  The
;; default decoder SUBSTITUTES U+FFFD for a bad byte, which would turn
;; a corrupt source file into a program that compiles and is wrong.
(define (decode-source path)
  (let ((bv (call-with-port (open-file-input-port path) get-bytevector-all)))
    (guard (e (#t (errorf 'goeteia
                          "this source file is not valid UTF-8:" path)))
      (bytevector->string
       bv (make-transcoder (utf-8-codec) (eol-style none)
                           (error-handling-mode raise))))))

;; Skip past a string literal or a line comment, so the paren counter
;; does not see what is inside one.  These replace a character-by-
;; character state machine that also rewrote the text; nothing is
;; rewritten now.
(define (skip-string src i n)
  (cond ((>= i n) n)
        ((char=? (string-ref src i) #\\) (skip-string src (+ i 2) n))
        ((char=? (string-ref src i) #\") (+ i 1))
        (else (skip-string src (+ i 1) n))))
(define (skip-comment src i n)
  (cond ((>= i n) n)
        ((char=? (string-ref src i) #\newline) (+ i 1))
        (else (skip-comment src (+ i 1) n))))

;; The datum the compiler is given, in the representation it has on the
;; self-hosted host: a string is a sequence of BYTES.  Everything the
;; reader produced is code points, so strings and symbol names are
;; encoded here and nothing downstream needs to know which host read
;; the file.
;;
;; A character datum above 127 is refused rather than converted: a char
;; is one value and cannot become several bytes, and the self-hosted
;; reader has no spelling for it either.  Refusing keeps the two hosts
;; answering the same way instead of adding a form to only one of them.
(define (host-bytes d)
  (cond
   ((string? d) (utf8-bytes-of d))
   ((symbol? d) (string->symbol (utf8-bytes-of (symbol->string d))))
   ((char? d)
    (if (< (char->integer d) 128)
        d
        (errorf 'goeteia
                "a character literal above U+007F has no self-hosted spelling:"
                d)))
   ((pair? d) (cons (host-bytes (car d)) (host-bytes (cdr d))))
   ((vector? d) (vector-map host-bytes d))
   (else d)))

(define (utf8-bytes-of s)
  (let ((bv (string->utf8 s)))
    (let loop ((i 0) (acc '()))
      (if (= i (bytevector-length bv))
          (list->string (reverse acc))
          (loop (+ i 1) (cons (integer->char (bytevector-u8-ref bv i)) acc))))))


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
          (errorf 'goeteia "library not found:" spec)
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
;; mount-shaped DATA gets no import scope: quote suppresses it
;; outright, quasiquote by nesting depth with unquote resuming --
;; the same rule the compiler's embed-expand and rt/compile.mjs's
;; embedBlocks apply, and all three must agree
(define (embed-splice-imports form dirs) (embed-splice-imports* form dirs 0))
(define (embed-splice-imports* form dirs qq)
  (cond
   ((not (pair? form)) form)
   ((eq? (car form) 'quote) form)
   ((and (eq? (car form) 'quasiquote) (pair? (cdr form)) (null? (cddr form)))
    (list (car form) (embed-splice-imports* (cadr form) dirs (+ qq 1))))
   ((and (memq (car form) '(unquote unquote-splicing))
         (pair? (cdr form)) (null? (cddr form)) (> qq 0))
    (list (car form) (embed-splice-imports* (cadr form) dirs (- qq 1))))
   ((and (= qq 0)
         (memq (car form) '(conjure define-js define-wasm define-wasm-js)))
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
                             (cons (embed-splice-imports* (car bs) dirs 0)
                                   acc))))))))
      (set! visited saved)
      (cons (car form) (cons (cadr form) body))))
   (else (cons (embed-splice-imports* (car form) dirs qq)
               (embed-splice-imports* (cdr form) dirs qq)))))

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
