;; expect: #t
;; The green half of test/defect-reader-hash-is-not-a-delimiter.ss.
;; That cell pins the red -- `abc#|c|#` must read as the symbol abc --
;; and this one pins everything that must NOT change when it is fixed,
;; because the obvious repair breaks two of them.
;;
;; The filed reason for deferring it was wrong and is worth correcting
;; here so it is not re-derived: it said R6RS uses # as a digit
;; placeholder inside numbers.  R6RS REMOVED R5RS's digit placeholder.
;; Chez reads 2#|c|#3 as one token only because the token opens with a
;; digit, and Chez itself refuses a#b.
;;
;; The real collision is STACKED NUMBER PREFIXES.  %read-prefixed reads
;; the whole token and peels prefixes off afterwards, so the # of #x in
;; #e#x10 is INSIDE the token.  A reader that simply adds # to
;; %delimiter? passes the red cell and breaks every stacked prefix,
;; which is why the two token shapes have to be told apart rather than
;; one set widened.
(import (rnrs))
(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))

;; stacked radix and exactness prefixes: the # here is inside the token
(want 'stacked-exact-hex #e#x10 16)
(want 'stacked-octal-exact #o#e1e3 512)
(want 'single-prefix-still-reads #x1F 31)

;; a character literal NAMING the hash, which survives because the
;; reader takes the first byte unconditionally and only then asks
;; whether the NEXT one ends the name
(want 'char-literal-hash (char->integer #\#) 35)
(want 'char-literal-named (char->integer #\space) 32)

;; a symbol whose name contains a hash keeps both of its spellings, so
;; the fix removes no expressive power -- and test/symbol-quoting.ss
;; already asserts the WRITER escapes that name as a\x23;b, which is
;; the same claim from the other side: a bare # cannot sit in a symbol
(want 'pipe-quoted-hash (symbol->string '|a#b|) "a#b")
(want 'hex-escaped-hash (symbol->string '|a#b|) (symbol->string (string->symbol "a#b")))

;; datum and block comments still work where they already did
(want 'datum-comment '(a #;b c) '(a c))
(want 'block-comment-between (+ 1 #|c|# 2) 3)

(display (if (null? fails) #t fails))
