;; Safe JSON parser and writer, ported from Igropyr's (igropyr json).
;;
;; A recursive-descent parser over the input string: no reader tricks,
;; safe for untrusted input. Full string escape handling including
;; \uXXXX and surrogate pairs -- decoded code points are written as
;; UTF-8 bytes (Goeteia strings are UTF-8 byte strings).
;;
;; Data model (identical to the server side):
;;   object -> alist with string keys      {"a":1}   -> (("a" . 1))
;;   array  -> vector                      [1,2]     -> #(1 2)
;;   string -> string, number -> number
;;   true/false -> #t/#f, null -> 'null
;;
;; (string->json s)   parse; raises #(json-error msg pos) on bad input
;; (json->string x)   serialize (alists -> objects, vectors -> arrays;
;;                    plain lists also serialize as arrays)
;; (json-ref x k ...) path access: string/symbol key for objects,
;;                    integer index for arrays; #f when absent
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web json)
  (export string->json json->string json-ref)
  (import (rnrs))

  (define (jfail msg pos)
    (raise (vector 'json-error msg pos)))

  (define (pow10 k)
    (let loop ((k k) (acc 1))
      (if (<= k 0) acc (loop (- k 1) (* acc 10)))))

  ;; ---- parser -----------------------------------------------------------

  (define (string->json s)
    (let ((n (string-length s)))
      (define (skip-ws i)
        (if (and (< i n) (memv (string-ref s i)
                               '(#\space #\tab #\newline #\return)))
            (skip-ws (+ i 1))
            i))
      (define (expect ch i)
        (if (and (< i n) (char=? (string-ref s i) ch))
            (+ i 1)
            (jfail (string-append "expected " (string ch)) i)))
      (define (parse-value i)
        (let ((i (skip-ws i)))
          (when (>= i n) (jfail "unexpected end of input" i))
          (let ((ch (string-ref s i)))
            (cond
             ((char=? ch #\{) (parse-object (+ i 1)))
             ((char=? ch #\[) (parse-array (+ i 1)))
             ((char=? ch #\") (parse-string (+ i 1)))
             ((char=? ch #\t) (parse-literal i "true" #t))
             ((char=? ch #\f) (parse-literal i "false" #f))
             ((char=? ch #\n) (parse-literal i "null" 'null))
             ((or (char=? ch #\-) (char-numeric? ch)) (parse-number i))
             (else (jfail "unexpected character" i))))))
      (define (parse-literal i word value)
        (let ((end (+ i (string-length word))))
          (if (and (<= end n) (string=? (substring s i end) word))
              (values value end)
              (jfail "bad literal" i))))
      (define (parse-object i)
        (let ((i (skip-ws i)))
          (if (and (< i n) (char=? (string-ref s i) #\}))
              (values '() (+ i 1))
              (let loop ((i i) (acc '()))
                (let ((i (skip-ws i)))
                  (unless (and (< i n) (char=? (string-ref s i) #\"))
                    (jfail "expected object key" i))
                  (let-values (((key i) (parse-string (+ i 1))))
                    (let ((i (expect #\: (skip-ws i))))
                      (let-values (((val i) (parse-value i)))
                        (let ((i (skip-ws i)))
                          (cond
                           ((and (< i n) (char=? (string-ref s i) #\,))
                            (loop (+ i 1) (cons (cons key val) acc)))
                           ((and (< i n) (char=? (string-ref s i) #\}))
                            (values (reverse (cons (cons key val) acc))
                                    (+ i 1)))
                           (else (jfail "expected , or } in object" i))))))))))))
      (define (parse-array i)
        (let ((i (skip-ws i)))
          (if (and (< i n) (char=? (string-ref s i) #\]))
              (values (vector) (+ i 1))
              (let loop ((i i) (acc '()))
                (let-values (((val i) (parse-value i)))
                  (let ((i (skip-ws i)))
                    (cond
                     ((and (< i n) (char=? (string-ref s i) #\,))
                      (loop (+ i 1) (cons val acc)))
                     ((and (< i n) (char=? (string-ref s i) #\]))
                      (values (list->vector (reverse (cons val acc)))
                              (+ i 1)))
                     (else (jfail "expected , or ] in array" i)))))))))
      (define (hex-digit c)
        (let ((v (char->integer c)))
          (cond
           ((and (<= 48 v) (<= v 57)) (- v 48))          ; 0-9
           ((and (<= 97 v) (<= v 102)) (- v 87))         ; a-f
           ((and (<= 65 v) (<= v 70)) (- v 55))          ; A-F
           (else #f))))
      (define (hex4 i)
        (unless (<= (+ i 4) n) (jfail "bad \\u escape" i))
        (let loop ((j i) (acc 0))
          (if (= j (+ i 4))
              acc
              (let ((d (hex-digit (string-ref s j))))
                (unless d (jfail "bad \\u escape" i))
                (loop (+ j 1) (+ (* acc 16) d))))))
      ;; Goeteia strings are UTF-8 byte strings: a decoded code point
      ;; is written as its UTF-8 bytes
      (define (utf8-write! p cp)
        (define (b! v) (write-char (integer->char v) p))
        (cond
         ((< cp #x80) (b! cp))
         ((< cp #x800)
          (b! (bitwise-ior #xC0 (bitwise-arithmetic-shift-right cp 6)))
          (b! (bitwise-ior #x80 (bitwise-and cp #x3F))))
         ((< cp #x10000)
          (b! (bitwise-ior #xE0 (bitwise-arithmetic-shift-right cp 12)))
          (b! (bitwise-ior #x80 (bitwise-and (bitwise-arithmetic-shift-right cp 6) #x3F)))
          (b! (bitwise-ior #x80 (bitwise-and cp #x3F))))
         (else
          (b! (bitwise-ior #xF0 (bitwise-arithmetic-shift-right cp 18)))
          (b! (bitwise-ior #x80 (bitwise-and (bitwise-arithmetic-shift-right cp 12) #x3F)))
          (b! (bitwise-ior #x80 (bitwise-and (bitwise-arithmetic-shift-right cp 6) #x3F)))
          (b! (bitwise-ior #x80 (bitwise-and cp #x3F))))))
      (define (parse-string i)          ; i points after the opening quote
        (let ((p (open-output-string)))
          (let loop ((i i))
            (when (>= i n) (jfail "unterminated string" i))
            (let ((ch (string-ref s i)))
              (cond
               ((char=? ch #\") (values (get-output-string p) (+ i 1)))
               ((char=? ch #\\)
                (when (>= (+ i 1) n) (jfail "bad escape" i))
                (let ((e (string-ref s (+ i 1))))
                  (case e
                    ((#\") (write-char #\" p) (loop (+ i 2)))
                    ((#\\) (write-char #\\ p) (loop (+ i 2)))
                    ((#\/) (write-char #\/ p) (loop (+ i 2)))
                    ((#\b) (write-char (integer->char 8) p) (loop (+ i 2)))
                    ((#\f) (write-char (integer->char 12) p) (loop (+ i 2)))
                    ((#\n) (write-char #\newline p) (loop (+ i 2)))
                    ((#\r) (write-char #\return p) (loop (+ i 2)))
                    ((#\t) (write-char #\tab p) (loop (+ i 2)))
                    ((#\u)
                     (let ((v (hex4 (+ i 2))))
                       (if (and (>= v #xD800) (<= v #xDBFF))
                           ;; high surrogate: expect \uDC00-\uDFFF
                           (begin
                             (unless (and (<= (+ i 12) n)
                                          (char=? (string-ref s (+ i 6)) #\\)
                                          (char=? (string-ref s (+ i 7)) #\u))
                               (jfail "lone high surrogate" i))
                             (let ((lo (hex4 (+ i 8))))
                               (unless (and (>= lo #xDC00) (<= lo #xDFFF))
                                 (jfail "bad low surrogate" i))
                               (utf8-write! p (+ #x10000
                                                 (* (- v #xD800) #x400)
                                                 (- lo #xDC00)))
                               (loop (+ i 12))))
                           (begin
                             (when (and (>= v #xDC00) (<= v #xDFFF))
                               (jfail "lone low surrogate" i))
                             (utf8-write! p v)
                             (loop (+ i 6))))))
                    (else (jfail "bad escape" i)))))
               (else (write-char ch p) (loop (+ i 1))))))))
      ;; JSON numbers by hand: string->number has no exponents, so the
      ;; value is assembled exactly (digits / 10^frac * 10^exp as an
      ;; exact ratio) and rounded once to a flonum when fractional
      (define (digit v) (and (<= 48 v) (<= v 57) (- v 48)))
      (define (scan-digits i)
        (let loop ((j i) (acc 0) (k 0))
          (if (< j n)
              (let ((d (digit (char->integer (string-ref s j)))))
                (if d (loop (+ j 1) (+ (* acc 10) d) (+ k 1))
                    (values acc k j)))
              (values acc k j))))
      (define (parse-number i)
        (let* ((neg (char=? (string-ref s i) #\-))
               (start (if neg (+ i 1) i)))
          (let-values (((ip ik j0) (scan-digits start)))
            (when (= ik 0) (jfail "bad number" i))
            (let ((dot? (and (< j0 n) (char=? (string-ref s j0) #\.))))
              (let-values (((fp fk j)
                            (if dot? (scan-digits (+ j0 1)) (values 0 0 j0))))
                (when (and dot? (= fk 0)) (jfail "bad number" i))
                (if (and (< j n) (memv (string-ref s j) '(#\e #\E)))
                    (let* ((k0 (+ j 1))
                           (esign (and (< k0 n)
                                       (memv (string-ref s k0) '(#\+ #\-))
                                       (string-ref s k0)))
                           (k (if esign (+ k0 1) k0)))
                      (let-values (((ep ek j2) (scan-digits k)))
                        (when (= ek 0) (jfail "bad number" i))
                        (let* ((m0 (/ (+ (* ip (pow10 fk)) fp) (pow10 fk)))
                               (mant (if neg (- m0) m0))
                               (v (if (and esign (char=? esign #\-))
                                      (/ mant (pow10 ep))
                                      (* mant (pow10 ep)))))
                          (values (exact->inexact v) j2))))
                    (let ((v (if dot?
                                 (exact->inexact
                                  (let ((m (/ (+ (* ip (pow10 fk)) fp)
                                              (pow10 fk))))
                                    (if neg (- m) m)))
                                 (if neg (- ip) ip))))
                      (values v j))))))))
      ;; top level: one value, then only whitespace
      (let-values (((v end) (parse-value 0)))
        (unless (= (skip-ws end) n) (jfail "trailing characters" end))
        v)))

  ;; ---- writer ------------------------------------------------------------

  (define (hex-char v)
    (string-ref "0123456789abcdef" v))

  (define (json-escape s)
    (let ((p (open-output-string)))
      (string-for-each
       (lambda (ch)
         (let ((code (char->integer ch)))
           (cond
            ((char=? ch #\") (display "\\\"" p))
            ((char=? ch #\\) (display "\\\\" p))
            ((char=? ch #\newline) (display "\\n" p))
            ((char=? ch #\return) (display "\\r" p))
            ((char=? ch #\tab) (display "\\t" p))
            ((< code 32)
             (display "\\u00" p)
             (write-char (hex-char (quotient code 16)) p)
             (write-char (hex-char (remainder code 16)) p))
            (else (write-char ch p)))))
       s)
      (get-output-string p)))

  (define (fl-nan? v) (not (fl=? v v)))
  (define (fl-inf? v) (and (fl=? v (fl* v 2.0)) (not (fl=? v 0.0))))

  (define (number->json v)
    (cond
     ((and (integer? v) (exact? v)) (number->string v))
     ((flonum? v)
      (if (or (fl-nan? v) (fl-inf? v)) "null" (number->string v)))
     ((exact? v) (number->string (exact->inexact v)))   ; ratio
     (else (error 'json->string "JSON numbers must be real" v))))

  (define (json->string x)
    (cond
     ((eq? x #t) "true")
     ((eq? x #f) "false")
     ((eq? x 'null) "null")
     ((number? x) (number->json x))
     ((string? x) (string-append "\"" (json-escape x) "\""))
     ((symbol? x) (string-append "\"" (json-escape (symbol->string x)) "\""))
     ((vector? x)
      (string-append
       "["
       (let loop ((i 0) (acc ""))
         (if (= i (vector-length x))
             acc
             (loop (+ i 1)
                   (if (string=? acc "")
                       (json->string (vector-ref x i))
                       (string-append acc "," (json->string (vector-ref x i)))))))
       "]"))
     ((null? x) "{}")
     ((and (list? x) (pair? (car x)))              ; alist -> object
      (string-append
       "{"
       (fold-right
        (lambda (kv acc)
          (let ((entry (string-append
                        "\"" (json-escape
                              (if (symbol? (car kv))
                                  (symbol->string (car kv))
                                  (car kv)))
                        "\":" (json->string (cdr kv)))))
            (if (string=? acc "") entry (string-append entry "," acc))))
        "" x)
       "}"))
     ((list? x)                                    ; plain list -> array
      (string-append
       "["
       (fold-right
        (lambda (v acc)
          (if (string=? acc "")
              (json->string v)
              (string-append (json->string v) "," acc)))
        "" x)
       "]"))
     (else "null")))

  ;; ---- path access -------------------------------------------------------

  (define (ref1 x k)
    (cond
     ((and (vector? x) (integer? k))
      (and (>= k 0) (< k (vector-length x)) (vector-ref x k)))
     ((and (list? x) (or (string? k) (symbol? k)))
      (let ((key (if (symbol? k) (symbol->string k) k)))
        (let loop ((l x))
          (cond
           ((null? l) #f)
           ((and (pair? (car l)) (equal? (caar l) key)) (cdar l))
           (else (loop (cdr l)))))))
     (else #f)))

  (define (json-ref x . keys)
    (fold-left (lambda (acc k) (and acc (ref1 acc k))) x keys)))
