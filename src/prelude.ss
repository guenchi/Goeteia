;; schwasm prelude: the runtime library, written in schwasm's own
;; Scheme and compiled into every module.
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.

(define (newline) (%write-byte 10))

(define (display x)
  (cond
   ((number? x) (%display-number x))
   ((char? x) (%write-byte (char->integer x)))
   ((string? x) (%display-string x 0))
   ((symbol? x) (%display-string (symbol->string x) 0))
   ((null? x) (%write-byte 40) (%write-byte 41))
   ((eq? x #t) (%write-byte 35) (%write-byte 116))
   ((eq? x #f) (%write-byte 35) (%write-byte 102))
   ((pair? x)
    (%write-byte 40)
    (display (car x))
    (%display-tail (cdr x)))
   ((procedure? x) (%display-string "#<procedure>" 0))
   (else (%display-string "#<unknown>" 0))))

(define (%display-tail x)
  (cond
   ((null? x) (%write-byte 41))
   ((pair? x)
    (%write-byte 32)
    (display (car x))
    (%display-tail (cdr x)))
   (else
    (%write-byte 32) (%write-byte 46) (%write-byte 32)
    (display x)
    (%write-byte 41))))

(define (%display-string s i)
  (when (< i (string-length s))
    (%write-byte (char->integer (string-ref s i)))
    (%display-string s (+ i 1))))

(define (%display-number n)
  (if (< n 0)
      (begin (%write-byte 45) (%display-digits (- 0 n)))
      (%display-digits n)))

(define (%display-digits n)
  (if (< n 10)
      (%write-byte (+ 48 n))
      (begin
        (%display-digits (quotient n 10))
        (%write-byte (+ 48 (remainder n 10))))))

(define (string=? a b)
  (and (= (string-length a) (string-length b))
       (%string-eq-from a b 0)))

(define (%string-eq-from a b i)
  (or (= i (string-length a))
      (and (eq? (string-ref a i) (string-ref b i))
           (%string-eq-from a b (+ i 1)))))

(define (list . args) args)

(define (length ls)
  (%length ls 0))
(define (%length ls n)
  (if (null? ls) n (%length (cdr ls) (+ n 1))))

(define (append a b)
  (if (null? a)
      b
      (cons (car a) (append (cdr a) b))))

(define (reverse ls)
  (%reverse ls '()))
(define (%reverse ls acc)
  (if (null? ls) acc (%reverse (cdr ls) (cons (car ls) acc))))

(define (map f ls)
  (if (null? ls)
      '()
      (cons (f (car ls)) (map f (cdr ls)))))

(define (for-each f ls)
  (unless (null? ls)
    (f (car ls))
    (for-each f (cdr ls))))

(define (memq x ls)
  (cond
   ((null? ls) #f)
   ((eq? (car ls) x) ls)
   (else (memq x (cdr ls)))))

(define (assq x ls)
  (cond
   ((null? ls) #f)
   ((eq? (caar ls) x) (car ls))
   (else (assq x (cdr ls)))))

(define (caar p) (car (car p)))
(define (cadr p) (car (cdr p)))
(define (cdar p) (cdr (car p)))
(define (cddr p) (cdr (cdr p)))

(define (equal? a b)
  (cond
   ((pair? a) (and (pair? b)
                   (equal? (car a) (car b))
                   (equal? (cdr a) (cdr b))))
   ((string? a) (and (string? b) (string=? a b)))
   (else (eq? a b))))

;; Multiple values: a list tagged with a unique pair, collapsing to
;; the value itself in the single-value case.
(define $values-tag (cons 0 0))

(define (values . args)
  (if (and (pair? args) (null? (cdr args)))
      (car args)
      (cons $values-tag args)))

(define (call-with-values producer consumer)
  (let ((v (producer)))
    (if (and (pair? v) (eq? (car v) $values-tag))
        (apply consumer (cdr v))
        (consumer v))))

;; ---- strings <-> lists ----

(define (list->string ls)
  (let ((s (%make-string (length ls))))
    (%fill-string s ls 0)
    s))
(define (%fill-string s ls i)
  (unless (null? ls)
    (string-set! s i (car ls))
    (%fill-string s (cdr ls) (+ i 1))))

(define (string->list s)
  (%string->list s (- (string-length s) 1) '()))
(define (%string->list s i acc)
  (if (< i 0)
      acc
      (%string->list s (- i 1) (cons (string-ref s i) acc))))

;; ---- runtime symbol interning ----
;;
;; The table starts as the compile-time interned symbols (pulled
;; lazily from the module), so read and string->symbol agree with
;; symbol literals under eq?.

(define $symtab #f)

(define (string->symbol s)
  (when (eq? $symtab #f)
    (set! $symtab (%interned-symbols)))
  (%intern s $symtab))
(define (%intern s tab)
  (cond
   ((null? tab)
    (let ((sym (%make-symbol s)))
      (set! $symtab (cons sym $symtab))
      sym))
   ((string=? (symbol->string (car tab)) s) (car tab))
   (else (%intern s (cdr tab)))))

;; ---- input port (one byte of pushback) ----

(define $peeked -2)

(define (%peek-byte)
  (when (= $peeked -2)
    (set! $peeked (%read-byte)))
  $peeked)
(define (%next-byte)
  (let ((b (%peek-byte)))
    (set! $peeked -2)
    b))

(define (read-char)
  (let ((b (%next-byte)))
    (if (< b 0) (eof-object) (integer->char b))))
(define (peek-char)
  (let ((b (%peek-byte)))
    (if (< b 0) (eof-object) (integer->char b))))

;; ---- the reader ----

(define (read)
  (%skip-blanks)
  (let ((b (%peek-byte)))
    (cond
     ((< b 0) (eof-object))
     ((= b 40) (%next-byte) (%read-list))          ; (
     ((= b 39) (%next-byte) (list 'quote (read)))  ; '
     ((= b 34) (%next-byte) (%read-string '()))    ; "
     ((= b 35) (%next-byte) (%read-hash))          ; #
     (else (%finish-atom (%read-token '()))))))

(define (%delimiter? b)
  (or (< b 0) (= b 32) (= b 10) (= b 9) (= b 13)
      (= b 40) (= b 41) (= b 59) (= b 34)))

(define (%skip-blanks)
  (let ((b (%peek-byte)))
    (cond
     ((or (= b 32) (= b 10) (= b 9) (= b 13))
      (%next-byte)
      (%skip-blanks))
     ((= b 59)                                     ; ;
      (%skip-line)
      (%skip-blanks))
     (else #f))))
(define (%skip-line)
  (let ((b (%next-byte)))
    (unless (or (< b 0) (= b 10))
      (%skip-line))))

(define (%read-token acc)
  (if (%delimiter? (%peek-byte))
      (reverse acc)
      (%read-token (cons (%next-byte) acc))))

(define (%finish-atom bs)
  (if (%number-token? bs)
      (%parse-int bs)
      (string->symbol (%bytes->string bs))))

(define (%number-token? bs)
  (if (and (pair? bs) (= (car bs) 45))             ; leading -
      (and (pair? (cdr bs)) (%all-digits? (cdr bs)))
      (%all-digits? bs)))
(define (%all-digits? bs)
  (if (null? bs)
      #t
      (and (< 47 (car bs)) (< (car bs) 58)
           (%all-digits? (cdr bs)))))
(define (%parse-int bs)
  (if (= (car bs) 45)
      (- 0 (%digits->int (cdr bs) 0))
      (%digits->int bs 0)))
(define (%digits->int bs acc)
  (if (null? bs)
      acc
      (%digits->int (cdr bs) (+ (* acc 10) (- (car bs) 48)))))

(define (%bytes->string bs)
  (let ((s (%make-string (length bs))))
    (%fill-bytes s bs 0)
    s))
(define (%fill-bytes s bs i)
  (unless (null? bs)
    (string-set! s i (integer->char (car bs)))
    (%fill-bytes s (cdr bs) (+ i 1))))

(define (%read-list)
  (%skip-blanks)
  (let ((b (%peek-byte)))
    (cond
     ((= b 41) (%next-byte) '())                   ; )
     ((= b 46)                                     ; . -- dotted tail
      (%next-byte)                                 ;      or dot-initial
      (if (%delimiter? (%peek-byte))               ;      symbol
          (let ((d (read)))
            (%skip-blanks)
            (%next-byte)                           ; consume )
            d)
          (cons (%finish-atom (cons 46 (%read-token '())))
                (%read-list))))
     (else
      (let ((x (read)))
        (cons x (%read-list)))))))

(define (%read-string acc)
  (let ((b (%next-byte)))
    (cond
     ((= b 34) (%bytes->string (reverse acc)))
     ((= b 92) (%read-string (cons (%next-byte) acc))) ; backslash
     (else (%read-string (cons b acc))))))

(define (%read-hash)
  (let ((b (%next-byte)))
    (cond
     ((= b 116) #t)                                ; t
     ((= b 102) #f)                                ; f
     ((= b 92)                                     ; \ -- character
      (let ((first (%next-byte)))
        (if (%delimiter? (%peek-byte))
            (integer->char first)
            (%named-char (%bytes->string
                          (cons first (%read-token '())))))))
     (else (eof-object)))))

(define (%named-char name)
  (cond
   ((string=? name "space") #\space)
   ((string=? name "newline") #\newline)
   ((string=? name "tab") #\tab)
   (else (string-ref name 0))))

;; ---- write ----

(define (write x)
  (cond
   ((string? x)
    (%write-byte 34)
    (%write-escaped x 0)
    (%write-byte 34))
   ((char? x)
    (%write-byte 35) (%write-byte 92)
    (%write-char-name x))
   ((pair? x)
    (%write-byte 40)
    (write (car x))
    (%write-tail (cdr x)))
   (else (display x))))

(define (%write-tail x)
  (cond
   ((null? x) (%write-byte 41))
   ((pair? x)
    (%write-byte 32)
    (write (car x))
    (%write-tail (cdr x)))
   (else
    (%write-byte 32) (%write-byte 46) (%write-byte 32)
    (write x)
    (%write-byte 41))))

(define (%write-escaped s i)
  (when (< i (string-length s))
    (let ((c (char->integer (string-ref s i))))
      (when (or (= c 34) (= c 92))
        (%write-byte 92))
      (%write-byte c))
    (%write-escaped s (+ i 1))))

(define (%write-char-name c)
  (let ((n (char->integer c)))
    (cond
     ((= n 32) (%display-string "space" 0))
     ((= n 10) (%display-string "newline" 0))
     ((= n 9) (%display-string "tab" 0))
     (else (%write-byte n)))))
