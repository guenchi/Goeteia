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

(define (append . ls)
  (cond
   ((null? ls) '())
   ((null? (cdr ls)) (car ls))
   (else ($append2 (car ls) (apply append (cdr ls))))))
(define ($append2 a b)
  (if (null? a)
      b
      (cons (car a) ($append2 (cdr a) b))))

(define (filter pred ls)
  (cond
   ((null? ls) '())
   ((pred (car ls)) (cons (car ls) (filter pred (cdr ls))))
   (else (filter pred (cdr ls)))))

(define (reverse ls)
  (%reverse ls '()))
(define (%reverse ls acc)
  (if (null? ls) acc (%reverse (cdr ls) (cons (car ls) acc))))

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
     ((= b 96) (%next-byte) (list 'quasiquote (read))) ; `
     ((= b 44)                                     ; , or ,@
      (%next-byte)
      (if (= (%peek-byte) 64)
          (begin (%next-byte) (list 'unquote-splicing (read)))
          (list 'unquote (read))))
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
     ((= b 39) (list 'syntax (read)))              ; ' -- #'x
     ((= b 120) (%read-hex 0))                     ; x -- hex literal
     ((= b 92)                                     ; \ -- character
      (let ((first (%next-byte)))
        (if (%delimiter? (%peek-byte))
            (integer->char first)
            (%named-char (%bytes->string
                          (cons first (%read-token '())))))))
     (else (eof-object)))))

(define (%read-hex acc)
  (let ((b (%peek-byte)))
    (cond
     ((and (< 47 b) (< b 58))                      ; 0-9
      (%next-byte)
      (%read-hex (+ (* acc 16) (- b 48))))
     ((and (< 96 b) (< b 103))                     ; a-f
      (%next-byte)
      (%read-hex (+ (* acc 16) (+ 10 (- b 97)))))
     ((and (< 64 b) (< b 71))                      ; A-F
      (%next-byte)
      (%read-hex (+ (* acc 16) (+ 10 (- b 65)))))
     (else acc))))

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

;; ---- additions for self-hosting ----

(define (void) (begin))

(define (> a b) (< b a))
(define (<= a b) (if (< b a) #f #t))
(define (>= a b) (if (< a b) #f #t))
(define (max a b) (if (< a b) b a))
(define (min a b) (if (< a b) a b))

(define (list? x)
  (if (null? x) #t (and (pair? x) (list? (cdr x)))))

(define (memv x ls) (memq x ls))
(define (assv x ls) (assq x ls))
(define (member x ls)
  (cond
   ((null? ls) #f)
   ((equal? (car ls) x) ls)
   (else (member x (cdr ls)))))
(define (assoc x ls)
  (cond
   ((null? ls) #f)
   ((equal? (caar ls) x) (car ls))
   (else (assoc x (cdr ls)))))

(define (list-tail ls n)
  (if (zero? n) ls (list-tail (cdr ls) (- n 1))))
(define (list-ref ls n)
  (car (list-tail ls n)))

(define (fold-left f init ls)
  (if (null? ls)
      init
      (fold-left f (f init (car ls)) (cdr ls))))
(define (fold-right f init ls)
  (if (null? ls)
      init
      (f (car ls) (fold-right f init (cdr ls)))))

(define (caddr p) (car (cddr p)))
(define (cdddr p) (cdr (cddr p)))
(define (cadddr p) (car (cdddr p)))
(define (cdadr p) (cdr (cadr p)))
(define (caadr p) (car (cadr p)))

(define (make-list n x)
  (if (zero? n) '() (cons x (make-list (- n 1) x))))

(define (string-append a b)
  (let* ((la (string-length a))
         (lb (string-length b))
         (s (%make-string (+ la lb))))
    (%blit! s a 0 la 0)
    (%blit! s b 0 lb la)
    s))
(define (%blit! dst src i n at)
  (when (< i n)
    (string-set! dst (+ at i) (string-ref src i))
    (%blit! dst src (+ i 1) n at)))

(define (number->string n)
  (if (< n 0)
      (string-append "-" (number->string (- 0 n)))
      (%bytes->string (%digits n '()))))
(define (%digits n acc)
  (let ((acc (cons (+ 48 (remainder n 10)) acc)))
    (if (< n 10) acc (%digits (quotient n 10) acc))))

;; gensyms: fresh uninterned symbol structs; identity comes from the
;; struct allocation, so even same-named gensyms are distinct
(define $gensym-count 0)
(define (gensym prefix)
  (set! $gensym-count (+ $gensym-count 1))
  (%make-symbol (string-append prefix (number->string $gensym-count))))

(define (%abort) (%unreachable))

;; compatible with the host Chez errorf; format directives print as-is
(define (errorf who msg . irritants)
  (display who) (display ": ") (display msg)
  (for-each (lambda (x) (display " ") (write x)) irritants)
  (newline)
  (%abort))

(define (eqv? a b) (eq? a b))
(define (integer? x) (number? x))
(define (exact? x) (number? x))
(define (cadar p) (car (cdar p)))

;; ---- derived binding forms (macros live in the prelude too) ----

;; both bind sequentially
(define-syntax let-values
  (syntax-rules ()
    ((_ () body1 body2 ...) (let () body1 body2 ...))
    ((_ ((formals expr) rest ...) body1 body2 ...)
     (call-with-values (lambda () expr)
       (lambda formals (let-values (rest ...) body1 body2 ...))))))
(define-syntax let*-values
  (syntax-rules ()
    ((_ bindings body1 body2 ...) (let-values bindings body1 body2 ...))))

(define-syntax assert
  (syntax-rules ()
    ((_ e) (let ((t e)) (if t t (errorf 'assert "assertion failed"))))))

(define (cons* a . rest) ($cons* a rest))
(define ($cons* a rest)
  (if (null? rest) a (cons a ($cons* (car rest) (cdr rest)))))

;; n-ary map and for-each
(define (map f ls . more)
  (if (null? more) ($map1 f ls) ($mapn f (cons ls more))))
(define ($map1 f ls)
  (if (null? ls) '() (cons (f (car ls)) ($map1 f (cdr ls)))))
(define ($mapn f lists)
  (if ($any-null? lists)
      '()
      (cons (apply f ($heads lists)) ($mapn f ($tails lists)))))
(define ($any-null? ls)
  (and (pair? ls) (or (null? (car ls)) ($any-null? (cdr ls)))))
(define ($heads ls) (if (null? ls) '() (cons (caar ls) ($heads (cdr ls)))))
(define ($tails ls) (if (null? ls) '() (cons (cdar ls) ($tails (cdr ls)))))
(define (for-each f ls . more)
  (if (null? more) ($for-each1 f ls) ($for-eachn f (cons ls more))))
(define ($for-each1 f ls)
  (unless (null? ls)
    (f (car ls))
    ($for-each1 f (cdr ls))))
(define ($for-eachn f lists)
  (unless ($any-null? lists)
    (apply f ($heads lists))
    ($for-eachn f ($tails lists))))

;; ---- dynamic-wind ----
;;
;; $winders holds (before . after) frames.  Escaping continuations
;; capture the winder stack; $escape runs the after thunks of every
;; frame being exited, then throws to the matching call/cc.

(define $winders '())

(define (dynamic-wind before thunk after)
  (before)
  (set! $winders (cons (cons before after) $winders))
  (let ((r (thunk)))
    (set! $winders (cdr $winders))
    (after)
    r))

(define ($escape tok saved v)
  ($unwind-to saved)
  (%throw-k tok v))
(define ($unwind-to saved)
  (unless (eq? $winders saved)
    (let ((w (car $winders)))
      (set! $winders (cdr $winders))
      ((cdr w))
      ($unwind-to saved))))
