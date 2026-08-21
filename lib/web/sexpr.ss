;; s-expression wire codec: the browser half, byte-for-byte compatible
;; with Igropyr's (igropyr sexpr) EXTENDED mode. Replaces the native
;; read/write in (web rpc) so the RPC channel can carry the full wire
;; whitelist -- crucially, bytevectors, as #vu8"<base64>".
;;
;; Wire whitelist (both directions):
;;   lists (proper and dotted), (), symbols, strings, exact integers,
;;   exact ratios, #t / #f, vectors #(...), bytevectors #vu8"<base64>".
;; Flonums cross as #f8"<base64>": the eight IEEE-754 bytes, so every
;; double survives bit-exactly -- including a signed zero, which the
;; decimal text this format deliberately never uses could not carry.
;; That includes a NaN's PAYLOAD.  The format transports bits, so the
;; payload is carried; what this port adds is a trip through a host
;; double, and the JS spec does not require an engine to preserve a
;; NaN's payload across one.  Every engine measured here does, and
;; test/sexpr-anchors.ss pins three distinct NaN bit patterns -- quiet,
;; payload-bearing, and negative -- so an engine that began
;; canonicalising would arrive as a failing anchor rather than as
;; silently altered data.  Read that as "carried, and watched".  (This
;; used to say the payload was not promised at all, which the anchors
;; have since made false: they require it.)
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

  ;; `pos` indexes THIS runtime's strings, which are UTF-8 bytes -- so
  ;; after a non-ASCII character it is larger than the number the
  ;; authority reports, which counts code points (`"<emoji>" x` fails at
  ;; 6 here and at 3 there).  Deliberate, not drift: counting code
  ;; points would put a UTF-8 decode on the parser's hot path to sharpen
  ;; a diagnostic.  docs/sexpr.md carries the table; it is repeated here
  ;; because reading this function is where the divergence looks like a
  ;; bug.
  ;;
  ;; What IS the same everywhere is the VERDICT: the same inputs are
  ;; refused.  The message is the same too except where this codec
  ;; deliberately splits one of the authority's: `#vu8"AB"` is refused
  ;; by both, as "bad base64 in bytevector" there and "non-canonical
  ;; base64 tail in bytevector" here, because one message for two guards
  ;; meant a test pinning it could not tell which had fired (see
  ;; scan-b64).  A stronger claim than that -- "identical messages" --
  ;; stood in this comment and in the doc for a round after the split
  ;; made it false.
  (define (sfail msg pos) (raise (list 'sexpr-error msg pos)))

  ;; ---- flonum <-> IEEE-754 base64, via a JS DataView --------------------
  ;; The full round trip lives in JS (hardware IEEE, little-endian fixed
  ;; there so no Scheme boolean crosses the FFI): flonum -> 8 LE bytes ->
  ;; base64, and back. Bit-exact for every double, inf included (a NaN's
  ;; payload is the host's business -- see the note at the top),
  ;; and byte-identical to Chez's bytevector-ieee-double-* on the igropyr
  ;; side, -0.0 included: this runtime's flonums DO carry a signed zero
  ;; (see the note on b64->flonum for the one place it used to be lost,
  ;; and how it is recovered).
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
  ;;
  ;; That same integral path is where the sign of -0.0 goes: JS -0 is
  ;; integral, so js->number answers the FIXNUM 0 and the sign is gone
  ;; before any Scheme code sees it.  (The runtime's flonums do carry a
  ;; signed zero -- (fl/ 1.0 x) tells the two apart -- so this is the
  ;; bridge's integral shortcut, not a limit of the float type.)  The
  ;; decoded bytes still have the sign bit, so read it there and rebuild.
  (define (b64->flonum s)
    (exact->inexact (js->number (js-call __igb2f (js-undefined) s))))
  (define (bytes->flonum bv)
    (let ((v (b64->flonum (base64-encode bv))))
      (if (and (fl=? v 0.0) (>= (bytevector-u8-ref bv 7) 128))
          (fl* (fl- 0.0 1.0) 0.0)           ; -0.0, which the bridge dropped
          v)))

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

  ;; -> a bytevector, or #f when the payload is not canonical base64.
  ;; The bits left over after the last whole byte must be zero: that is
  ;; what makes #vu8"A" an empty bytevector (six leftover zero bits) but
  ;; #vu8"AB" an error (four leftover bits carrying a 1).  Igropyr's
  ;; decoder refuses the second, so a decoder here that quietly returned
  ;; one byte would put the two implementations a byte apart on an input
  ;; neither side would think to test.  The caller turns #f into the
  ;; documented sexpr-error, with the position.
  (define (base64-decode s)
    (let ((n (string-length s)))
      (let count ((i 0) (c 0))
        (if (< i n)
            (count (+ i 1) (if (b64-value (string-ref s i)) (+ c 1) c))
            (let ((out (make-bytevector (quotient (* c 6) 8) 0)))
              (let loop ((i 0) (acc 0) (bits 0) (oi 0))
                (if (= i n)
                    (and (= acc 0) out)      ; leftover bits must be zero
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

  ;; Is this byte string well-formed UTF-8?  The shortest-form and
  ;; surrogate-range rules are included: an overlong encoding or a
  ;; surrogate half is exactly the "accepted here, different there"
  ;; case this checks for.
  (define (utf8-cont? b) (and (>= b 128) (< b 192)))
  (define (utf8-well-formed? s)
    (let ((n (string-length s)))
      (let loop ((i 0))
        (if (>= i n)
            #t
            (let ((b (char->integer (string-ref s i))))
              (define (cont k) (and (< (+ i k) n)
                                    (utf8-cont? (char->integer
                                                 (string-ref s (+ i k))))))
              (define (b2 k) (char->integer (string-ref s (+ i k))))
              (cond
               ((< b 128) (loop (+ i 1)))
               ((< b 194) #f)                      ; continuation or overlong
               ((< b 224) (and (cont 1) (loop (+ i 2))))
               ((< b 240)
                (and (cont 1) (cont 2)
                     ;; no overlong, no surrogate half
                     (let ((cp (+ (* (- b 224) 4096)
                                  (* (- (b2 1) 128) 64)
                                  (- (b2 2) 128))))
                       (and (>= cp 2048) (not (and (>= cp 55296) (< cp 57344)))))
                     (loop (+ i 3))))
               ((< b 245)
                (and (cont 1) (cont 2) (cont 3)
                     (let ((cp (+ (* (- b 240) 262144)
                                  (* (- (b2 1) 128) 4096)
                                  (* (- (b2 2) 128) 64)
                                  (- (b2 3) 128))))
                       (and (>= cp 65536) (<= cp 1114111)))
                     (loop (+ i 4))))
               (else #f)))))))

  ;; Exact integers and ratios reach the wire as their printed numeral,
  ;; and the reader will not accept one past the token cap.  Same limit,
  ;; same constant, both ends -- a numeral that crossed would come back
  ;; as "token too long" at the far end.  A ratio is measured whole:
  ;; "num/den" is one token to the reader.
  (define (put-numeral str)
    (when (> (string-length str) max-token)
      (sfail "token too long for the wire -- carry a value this large as a bytevector (#vu8)" 0))
    (put-str str))

  ;; A name that reads back as something OTHER than this symbol cannot
  ;; cross: this grammar has no |escaped| symbol form, so the datum
  ;; would arrive deformed (a symbol becoming an integer, a three-element
  ;; list becoming a dotted pair) or not at all.  Two rules, matching
  ;; igropyr name for name:
  ;;   1. the name is a number to a Scheme reader -- 12, +1, .5, 1e3,
  ;;      1/2, +inf.0
  ;;   2. the name merely STARTS numeric without being a number in this
  ;;      grammar -- 0x10, 12abc -- which the reader refuses outright,
  ;;      so writing one produces a datum no peer can read
  ;; Rule 2 matches igropyr, which asks the same question.  It did not
  ;; always -- it used to ask the host reader, which does not call 0x10
  ;; a number, and so emitted five names its own parser refused.  That
  ;; is closed upstream, and the fixture regenerated against the source
  ;; records no such name; the golden tests assert that set stays
  ;; empty.
  (define (wire-symbol? s)
    (let ((m (string-length s)))
      (and (> m 0)
           (not (string=? s "."))
           ;; before the character walk, because it is one comparison
           ;; and the walk is not: a name past the reader's token cap
           ;; comes back as "token too long" at the far end
           (<= m max-token)
           (let lp ((i 0))
             (or (= i m)
                 (and (symbol-char? (string-ref s i)) (lp (+ i 1)))))
           (not (host-number-name? s))
           (not (numeric-shape? s)))))

  (define (digit-char? c) (and (char<=? #\0 c) (char<=? c #\9)))

  ;; "starts like a number": the reader refuses any such token that is
  ;; not one of this grammar's numbers
  (define (numeric-shape? s)
    (let ((m (string-length s)))
      (and (> m 0)
           (or (digit-char? (string-ref s 0))
               (and (char=? (string-ref s 0) #\-) (> m 1)
                    (digit-char? (string-ref s 1)))))))

  ;; "a Scheme reader would call this a number".  Built from the number
  ;; grammar, not guessed at: the shapes that get missed are the ones
  ;; nobody thinks of -- +i and -i are numbers, so are +1@2 (polar) and
  ;; +inf.0+inf.0i -- while a ratio with a zero denominator is NOT one,
  ;; so +1/0 may cross.  Each case is pinned against igropyr's own
  ;; verdict in the fixture's write_reject group.
  ;;
  ;; A tiny recursive-descent matcher rather than a regex, because this
  ;; runtime has none.  Each of these takes a string and a start index
  ;; and answers the index after what it matched, or #f.
  (define (m-digits s i)                       ; one or more
    (let loop ((k i))
      (if (and (< k (string-length s)) (digit-char? (string-ref s k)))
          (loop (+ k 1))
          (and (> k i) k))))
  (define (m-nonzero-digits s i)               ; digits, not all zero
    (let ((k (m-digits s i)))
      (and k
           (let scan ((j i))
             (cond ((= j k) #f)
                   ((char=? (string-ref s j) #\0) (scan (+ j 1)))
                   (else k))))))
  (define (m-char s i c)
    (and (< i (string-length s)) (char=? (string-ref s i) c) (+ i 1)))
  (define (m-lit s i lit)
    (let ((n (string-length s)) (m (string-length lit)))
      (and (<= (+ i m) n) (string=? (substring s i (+ i m)) lit) (+ i m))))
  (define (m-sign s i)                         ; required sign
    (or (m-char s i #\+) (m-char s i #\-)))
  (define (m-opt-sign s i) (or (m-sign s i) i))
  ;; the exponent marker is not just e: Scheme has s/f/d/l for the
  ;; short/single/double/long precisions, in either case
  (define (m-exp-marker s i)
    (and (< i (string-length s))
         (memv (string-ref s i)
               '(#\e #\E #\s #\S #\f #\F #\d #\D #\l #\L))
         (+ i 1)))
  (define (m-exponent s i)                     ; optional
    (let ((k (m-exp-marker s i)))
      (if k (m-digits s (m-opt-sign s k)) i)))
  (define (m-ureal s i)
    (or ;; a ratio, whose denominator may not be zero
        (let ((a (m-digits s i)))
          (and a (let ((b (m-char s a #\/)))
                   (and b (m-nonzero-digits s b)))))
        ;; digits [. digits] [exponent]
        (let ((a (m-digits s i)))
          (and a (let ((b (or (m-char s a #\.) a)))
                   (m-exponent s (or (m-digits s b) b)))))
        ;; . digits [exponent]
        (let ((a (m-char s i #\.)))
          (and a (let ((b (m-digits s a))) (and b (m-exponent s b)))))))
  ;; matched case-insensitively, because the host reader is: +NaN.0 and
  ;; +INF.0 are numbers there
  (define (m-ci-lit s i lit)
    (let ((n (string-length s)) (m (string-length lit)))
      (and (<= (+ i m) n)
           (let scan ((k 0))
             (cond ((= k m) (+ i m))
                   ((char=? (char-downcase (string-ref s (+ i k)))
                            (string-ref lit k))
                    (scan (+ k 1)))
                   (else #f))))))
  (define (m-infnan s i) (or (m-ci-lit s i "inf.0") (m-ci-lit s i "nan.0")))
  (define (m-real s i)
    (or (let ((a (m-sign s i))) (and a (m-infnan s a)))
        (m-ureal s (m-opt-sign s i))))
  (define (m-imaginary s i)                    ; [+-] [magnitude] i
    (let ((a (m-sign s i)))
      (and a (let ((b (or (m-ureal s a) (m-infnan s a) a)))
               ;; the suffix is case-insensitive too, like every other
               ;; alphabetic part of this grammar
               (and (< b (string-length s))
                    (memv (string-ref s b) '(#\i #\I))
                    (+ b 1))))))
  (define (host-number-name? s)
    (let ((n (string-length s)))
      (define (whole k) (and k (= k n)))
      (or (whole (let ((a (m-real s 0)))
                   (and a (or (m-imaginary s a) a))))
          (whole (m-imaginary s 0))
          (whole (let ((a (m-real s 0)))
                   (and a (let ((b (m-char s a #\@))) (and b (m-real s b)))))))))

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
       ;; This runtime's strings are UTF-8 BYTES, and nothing stops a
       ;; caller from building one that is not well-formed -- a lone
       ;; #xff, a truncated sequence.  Those bytes would go out between
       ;; the quotes and no peer could read them back as this string.
       ;; Same rule as the JS side's refusal of an unpaired surrogate:
       ;; if the product would not represent the value, do not accept
       ;; the value.
       (unless (utf8-well-formed? x)
         (sfail "string is not well-formed UTF-8" 0))
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
      ((and (integer? x) (exact? x)) (put-numeral (number->string x)))
      ((and (rational? x) (exact? x))
       (put-numeral (string-append (number->string (numerator x))
                                   "/"
                                   (number->string (denominator x)))))
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
      ;; The reader checks the same rule the writer does.  Without it a
      ;; wire carrying `" #xff "` parses into a malformed Scheme string
      ;; that this very implementation then refuses to write back: bytes
      ;; accepted here that no peer could have produced and none can
      ;; read.
      (define (parse-string i)
        (let loop ((i i) (acc '()))
          (when (>= i n) (sfail "unterminated string" i))
          (let ((c (string-ref s i)))
            (cond
              ((char=? c #\")
               (let ((str (list->string (reverse acc))))
                 (unless (utf8-well-formed? str)
                   (sfail "string is not well-formed UTF-8" i))
                 (values str (+ i 1))))
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
             (let ((bv (base64-decode (substring s start j))))
               ;; a DIFFERENT message from the one the character scan
               ;; raises: both used to say "bad base64 in X", so a test
               ;; pinning that phrase could not tell which guard fired
               ;; and a rejection moving from one to the other went
               ;; unnoticed
               (unless bv
                 (sfail (string-append "non-canonical base64 tail in " what)
                        start))
               (values bv (+ j 1))))
            ((b64-char? (string-ref s j)) (loop (+ j 1)))
            (else (sfail (string-append "bad base64 in " what) j)))))
      (define (parse-bytevector-b64 start) (scan-b64 start "bytevector"))
      ;; The length is checked in BYTES, after decoding: a payload may
      ;; carry padding anywhere, so counting base64 characters would
      ;; accept twelve characters that decode to seven bytes and refuse
      ;; a legal one that does not.
      (define (parse-flonum-b64 start)
        (let loop ((j start))
          (cond
            ((>= j n) (sfail "unterminated flonum" start))
            ((char=? (string-ref s j) #\")
             (let ((bv (base64-decode (substring s start j))))
               (unless bv (sfail "bad base64 in flonum" start))
               (unless (= (bytevector-length bv) 8)
                 (sfail "flonum wants exactly 8 bytes" start))
               (values (bytes->flonum bv) (+ j 1))))
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
