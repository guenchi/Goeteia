;; s-expression wire codec: the browser half, byte-for-byte compatible
;; with Igropyr's (igropyr sexpr) EXTENDED mode. Replaces the native
;; read/write in (web rpc) so the RPC channel can carry the full wire
;; whitelist -- crucially, bytevectors, as #vu8"<base64>".
;;
;; Wire whitelist (both directions):
;;   lists (proper and dotted), (), symbols, strings, exact integers,
;;   exact ratios, #t / #f, vectors #(...), bytevectors #vu8"<base64>".
;; FLONUMS ARE NOT ON THE WIRE: this runtime cannot print a float that
;; reads back bit-identically, so exactness is the contract (the same
;; "no floating-point approximation" guarantee Igropyr's RPC advertises).
;;
;; A hand-written recursive-descent parser, NOT the host reader: no
;; #-syntax surprises, a depth limit, a token-length cap -- safe on a
;; reply from anywhere. Anything off the whitelist fails loudly.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web sexpr)
  (export sexpr->string string->sexpr)
  (import (rnrs) (web js))

  (define max-depth 64)
  (define max-token 65536)

  (define (sfail msg pos) (raise (list 'sexpr-error msg pos)))

  ;; ---- flonum <-> IEEE-754 base64, via a JS DataView --------------------
  ;; The full round trip lives in JS (hardware IEEE, little-endian fixed
  ;; there so no Scheme boolean crosses the FFI): flonum -> 8 LE bytes ->
  ;; base64, and back. Bit-exact for every double, inf and nan included,
  ;; and byte-identical to Chez's bytevector-ieee-double-* on the igropyr
  ;; side. (-0.0 reads back as 0.0 -- this runtime's floats carry no
  ;; signed zero.)
  (define _ig-f2b
    (js-eval "globalThis.__igf2b=(x)=>{const dv=new DataView(new ArrayBuffer(8));dv.setFloat64(0,x,true);let s='';const u=new Uint8Array(dv.buffer);for(let i=0;i<8;i++)s+=String.fromCharCode(u[i]);return btoa(s);}"))
  (define _ig-b2f
    (js-eval "globalThis.__igb2f=(s)=>{const b=atob(s);const dv=new DataView(new ArrayBuffer(8));for(let i=0;i<8;i++)dv.setUint8(i,b.charCodeAt(i));return dv.getFloat64(0,true);}"))
  (define __igf2b (js-get (js-global) "__igf2b"))
  (define __igb2f (js-get (js-global) "__igb2f"))
  (define (flonum->b64 x) (js->string (js-call __igf2b (js-undefined) x)))
  ;; getFloat64 hands an integer-valued double (1.0) back as a JS integer,
  ;; which js->number makes a fixnum -- force it back to a flonum so #f8
  ;; always decodes to a flonum, never an integer.
  (define (b64->flonum s)
    (exact->inexact (js->number (js-call __igb2f (js-undefined) s))))

  ;; ---- base64 (RFC 4648) -------------------------------------------------
  ;; Same bytes as Igropyr's; integer arithmetic in place of bit ops.

  (define b64-chars
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

  (define (b64-char? c)
    (or (and (char<=? #\A c) (char<=? c #\Z))
        (and (char<=? #\a c) (char<=? c #\z))
        (and (char<=? #\0 c) (char<=? c #\9))
        (char=? c #\+) (char=? c #\/) (char=? c #\=)))

  (define (b64-value ch)
    (cond
      ((and (char<=? #\A ch) (char<=? ch #\Z)) (- (char->integer ch) 65))
      ((and (char<=? #\a ch) (char<=? ch #\z)) (+ 26 (- (char->integer ch) 97)))
      ((and (char<=? #\0 ch) (char<=? ch #\9)) (+ 52 (- (char->integer ch) 48)))
      ((char=? ch #\+) 62)
      ((char=? ch #\/) 63)
      (else #f)))

  (define (pow2 k) (cond ((= k 0) 1) ((= k 2) 4) ((= k 4) 16) (else 1)))

  (define (base64-encode bv)
    (with-output-to-string
      (lambda ()
        (define (put k) (write-char (string-ref b64-chars k)))
        (let ((n (bytevector-length bv)))
          (let loop ((i 0))
            (let ((left (- n i)))
              (cond
                ((>= left 3)
                 (let ((b0 (bytevector-u8-ref bv i))
                       (b1 (bytevector-u8-ref bv (+ i 1)))
                       (b2 (bytevector-u8-ref bv (+ i 2))))
                   (put (quotient b0 4))
                   (put (+ (* (remainder b0 4) 16) (quotient b1 16)))
                   (put (+ (* (remainder b1 16) 4) (quotient b2 64)))
                   (put (remainder b2 64))
                   (loop (+ i 3))))
                ((= left 2)
                 (let ((b0 (bytevector-u8-ref bv i))
                       (b1 (bytevector-u8-ref bv (+ i 1))))
                   (put (quotient b0 4))
                   (put (+ (* (remainder b0 4) 16) (quotient b1 16)))
                   (put (* (remainder b1 16) 4))
                   (write-char #\=)))
                ((= left 1)
                 (let ((b0 (bytevector-u8-ref bv i)))
                   (put (quotient b0 4))
                   (put (* (remainder b0 4) 16))
                   (write-char #\=) (write-char #\=)))
                (else #t))))))))

  (define (base64-decode s)
    (let ((n (string-length s)))
      (let count ((i 0) (c 0))
        (if (< i n)
            (count (+ i 1) (if (b64-value (string-ref s i)) (+ c 1) c))
            (let ((out (make-bytevector (quotient (* c 6) 8) 0)))
              (let loop ((i 0) (acc 0) (bits 0) (oi 0))
                (if (= i n)
                    out
                    (let ((v (b64-value (string-ref s i))))
                      (if (not v)
                          (loop (+ i 1) acc bits oi)
                          (let ((acc2 (+ (* acc 64) v)) (bits2 (+ bits 6)))
                            (if (>= bits2 8)
                                (let ((keep (- bits2 8)))
                                  (bytevector-u8-set! out oi
                                    (remainder (quotient acc2 (pow2 keep)) 256))
                                  (loop (+ i 1) (remainder acc2 (pow2 keep)) keep (+ oi 1)))
                                (loop (+ i 1) acc2 bits2 oi))))))))))))

  ;; ---- writer ------------------------------------------------------------

  (define (wire-symbol? s)
    (let ((m (string-length s)))
      (and (> m 0)
           (let lp ((i 0))
             (or (= i m)
                 (and (symbol-char? (string-ref s i)) (lp (+ i 1))))))))

  (define (symbol-char? c)
    (or (and (char<=? #\a c) (char<=? c #\z))
        (and (char<=? #\A c) (char<=? c #\Z))
        (and (char<=? #\0 c) (char<=? c #\9))
        (memv c '(#\- #\+ #\* #\/ #\< #\> #\= #\? #\! #\. #\_
                  #\% #\& #\^ #\~ #\: #\@))))

  (define (emit x depth)
    (when (> depth max-depth) (sfail "nesting too deep (cyclic data?)" 0))
    (cond
      ((null? x) (write-char #\() (write-char #\)))
      ((pair? x)
       (write-char #\()
       (emit (car x) (+ depth 1))
       (let tail ((x (cdr x)) (k 0))
         (when (> k 1000000) (sfail "list too long (cyclic data?)" 0))
         (cond
           ((null? x) (write-char #\)))
           ((pair? x)
            (write-char #\space)
            (emit (car x) (+ depth 1))
            (tail (cdr x) (+ k 1)))
           (else
            (write-char #\space) (write-char #\.) (write-char #\space)
            (emit x (+ depth 1))
            (write-char #\))))))
      ((symbol? x)
       (let ((str (symbol->string x)))
         (unless (wire-symbol? str) (sfail "symbol not wire-safe" 0))
         (put-str str)))
      ((string? x)
       (write-char #\")
       (let lp ((i 0))
         (when (< i (string-length x))
           (let ((c (string-ref x i)))
             (when (or (char=? c #\") (char=? c #\\)) (write-char #\\))
             (write-char c))
           (lp (+ i 1))))
       (write-char #\"))
      ((eq? x #t) (put-str "#t"))
      ((eq? x #f) (put-str "#f"))
      ((and (integer? x) (exact? x)) (put-str (number->string x)))
      ((and (rational? x) (exact? x))
       (put-str (number->string (numerator x)))
       (write-char #\/)
       (put-str (number->string (denominator x))))
      ((vector? x)
       (write-char #\#) (write-char #\()
       (let ((m (vector-length x)))
         (let lp ((i 0))
           (when (< i m)
             (when (> i 0) (write-char #\space))
             (emit (vector-ref x i) (+ depth 1))
             (lp (+ i 1)))))
       (write-char #\)))
      ((bytevector? x)
       (put-str "#vu8\"") (put-str (base64-encode x)) (write-char #\"))
      ((flonum? x)
       (put-str "#f8\"") (put-str (flonum->b64 x)) (write-char #\"))
      (else (sfail "datum not in the wire whitelist" 0))))

  (define (put-str s)
    (let ((m (string-length s)))
      (let lp ((i 0)) (when (< i m) (write-char (string-ref s i)) (lp (+ i 1))))))

  (define (sexpr->string x)
    (with-output-to-string (lambda () (emit x 0))))

  ;; ---- parser (indexes the string; not the host reader) ------------------

  (define (string->sexpr s)
    (let ((n (string-length s)))
      (define (ws? c)
        (or (char=? c #\space) (char=? c #\newline)
            (char=? c #\tab) (char=? c #\return)))
      (define (skip i)
        (if (and (< i n) (ws? (string-ref s i))) (skip (+ i 1)) i))
      (define (delim? c)
        (or (ws? c) (char=? c #\() (char=? c #\)) (char=? c #\")))
      (define (parse-value i depth)
        (when (> depth max-depth) (sfail "nesting too deep" i))
        (let ((i (skip i)))
          (when (>= i n) (sfail "unexpected end of input" i))
          (let ((c (string-ref s i)))
            (cond
              ((char=? c #\() (parse-list (+ i 1) depth))
              ((char=? c #\)) (sfail "unexpected )" i))
              ((char=? c #\") (parse-string (+ i 1)))
              ((char=? c #\#) (parse-hash (+ i 1) depth))
              (else (parse-atom i))))))
      (define (parse-list i depth)
        (let loop ((i i) (acc '()))
          (let ((i (skip i)))
            (when (>= i n) (sfail "unterminated list" i))
            (cond
              ((char=? (string-ref s i) #\))
               (values (reverse acc) (+ i 1)))
              ((and (char=? (string-ref s i) #\.)
                    (or (>= (+ i 1) n) (delim? (string-ref s (+ i 1))))
                    (pair? acc))
               (let-values (((tail j) (parse-value (+ i 1) (+ depth 1))))
                 (let ((j (skip j)))
                   (unless (and (< j n) (char=? (string-ref s j) #\)))
                     (sfail "expected ) after dotted tail" j))
                   (values (append (reverse (cdr acc)) (cons (car acc) tail))
                           (+ j 1)))))
              (else
               (let-values (((v j) (parse-value i (+ depth 1))))
                 (loop j (cons v acc))))))))
      (define (parse-string i)
        (let loop ((i i) (acc '()))
          (when (>= i n) (sfail "unterminated string" i))
          (let ((c (string-ref s i)))
            (cond
              ((char=? c #\")
               (values (list->string (reverse acc)) (+ i 1)))
              ((char=? c #\\)
               (when (>= (+ i 1) n) (sfail "dangling escape" i))
               (let ((e (string-ref s (+ i 1))))
                 (loop (+ i 2)
                       (cons (cond
                               ((char=? e #\n) #\newline)
                               ((char=? e #\t) #\tab)
                               ((char=? e #\r) #\return)
                               ((or (char=? e #\") (char=? e #\\)) e)
                               (else (sfail "bad string escape" i)))
                             acc))))
              (else (loop (+ i 1) (cons c acc)))))))
      (define (parse-hash i depth)
        (when (>= i n) (sfail "dangling #" i))
        (let ((c (string-ref s i)))
          (cond
            ;; #f8"..." (a flonum) vs the #f boolean: lookahead decides
            ((and (char=? c #\f)
                  (< (+ i 2) n)
                  (char=? (string-ref s (+ i 1)) #\8)
                  (char=? (string-ref s (+ i 2)) #\"))
             (parse-flonum-b64 (+ i 3)))
            ((or (char=? c #\t) (char=? c #\f))
             (unless (or (>= (+ i 1) n) (delim? (string-ref s (+ i 1))))
               (sfail "bad # literal" i))
             (values (char=? c #\t) (+ i 1)))
            ((char=? c #\() (parse-vector (+ i 1) depth))
            ((char=? c #\v)
             (unless (and (< (+ i 3) n)
                          (char=? (string-ref s (+ i 1)) #\u)
                          (char=? (string-ref s (+ i 2)) #\8)
                          (char=? (string-ref s (+ i 3)) #\"))
               (sfail "bad # literal" i))
             (parse-bytevector-b64 (+ i 4)))
            (else (sfail "bad # literal" i)))))
      (define (parse-vector i depth)
        (let loop ((i i) (acc '()))
          (let ((i (skip i)))
            (when (>= i n) (sfail "unterminated vector" i))
            (cond
              ((char=? (string-ref s i) #\))
               (values (list->vector (reverse acc)) (+ i 1)))
              ((and (char=? (string-ref s i) #\.)
                    (or (>= (+ i 1) n) (delim? (string-ref s (+ i 1)))))
               (sfail "dot not allowed in vector" i))
              (else
               (let-values (((v j) (parse-value i (+ depth 1))))
                 (loop j (cons v acc))))))))
      (define (scan-b64 start what)         ; -> (values bytevector next-i)
        (let loop ((j start))
          (cond
            ((>= j n) (sfail (string-append "unterminated " what) start))
            ((char=? (string-ref s j) #\")
             (values (base64-decode (substring s start j)) (+ j 1)))
            ((b64-char? (string-ref s j)) (loop (+ j 1)))
            (else (sfail (string-append "bad base64 in " what) j)))))
      (define (parse-bytevector-b64 start) (scan-b64 start "bytevector"))
      (define (parse-flonum-b64 start)      ; 8 IEEE bytes = 12 base64 chars
        (let loop ((j start))
          (cond
            ((>= j n) (sfail "unterminated flonum" start))
            ((char=? (string-ref s j) #\")
             (unless (= (- j start) 12) (sfail "flonum wants 8 bytes" start))
             (values (b64->flonum (substring s start j)) (+ j 1)))
            ((b64-char? (string-ref s j)) (loop (+ j 1)))
            (else (sfail "bad base64 in flonum" j)))))
      (define (digits? str a b)
        (and (< a b)
             (let lp ((i a))
               (or (= i b)
                   (and (char<=? #\0 (string-ref str i))
                        (char<=? (string-ref str i) #\9)
                        (lp (+ i 1)))))))
      (define (token->number tok)
        (let* ((m (string-length tok))
               (a (if (and (> m 0) (char=? (string-ref tok 0) #\-)) 1 0))
               (slash (let lp ((i a))
                        (cond ((= i m) #f)
                              ((char=? (string-ref tok i) #\/) i)
                              (else (lp (+ i 1)))))))
          (cond
            ((and slash (digits? tok a slash) (digits? tok (+ slash 1) m))
             (let ((d (string->number (substring tok (+ slash 1) m))))
               (and d (not (= d 0))
                    (/ (let ((v (string->number (substring tok a slash))))
                         (if (= a 1) (- v) v))
                       d))))
            ((digits? tok a m)
             (let ((v (string->number (substring tok a m))))
               (and v (if (= a 1) (- v) v))))
            (else #f))))
      (define (valid-symbol? tok)
        (let ((m (string-length tok)))
          (and (> m 0)
               (let lp ((i 0))
                 (or (= i m)
                     (and (symbol-char? (string-ref tok i)) (lp (+ i 1))))))))
      (define (numeric-shape? tok)
        (let ((m (string-length tok)))
          (and (> m 0)
               (let ((c (string-ref tok 0)))
                 (or (and (char<=? #\0 c) (char<=? c #\9))
                     (and (char=? c #\-) (> m 1)
                          (char<=? #\0 (string-ref tok 1))
                          (char<=? (string-ref tok 1) #\9)))))))
      (define (parse-atom i)
        (let ((j (let lp ((j i))
                   (if (or (>= j n) (delim? (string-ref s j))) j (lp (+ j 1))))))
          (when (> (- j i) max-token) (sfail "token too long" i))
          (let* ((tok (substring s i j))
                 (num (token->number tok)))
            (cond
              (num (values num j))
              ((numeric-shape? tok) (sfail "bad number" i))
              ((valid-symbol? tok) (values (string->symbol tok) j))
              (else (sfail "bad token" i))))))
      (let-values (((v i) (parse-value 0 0)))
        (unless (= (skip i) n) (sfail "trailing data after datum" i))
        v)))
)
