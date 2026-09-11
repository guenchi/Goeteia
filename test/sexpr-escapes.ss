;; expect: #t
;; The reader must accept every string escape a conforming R6RS writer
;; emits.  It took \n \t \r \" \\ and nothing else, so \a \b \v \f,
;; \x<hex>; in a string and \x<hex>; in a symbol were all refused --
;; output a standard writer produces could not be read back, and a form
;; feed inside a stored value made that value permanently unreadable to
;; a consumer with nothing reporting a problem.
;;
;; ACCEPT SIDE ONLY: the writer and test/sexpr-vectors.json are
;; deliberately untouched, so not one golden can change colour.
;;
;; The table is test/sexpr-escape-vectors.json and it is read by this
;; cell AND by test/sexpr-escapes.mjs.  One table held against two
;; implementations cannot drift; two tables would, and the drift would
;; stay invisible until a consumer met the shape only one of them took.
;; The comparison column is UTF-8 BYTES rather than code points,
;; because a Goeteia string holds one character per byte -- bytes are
;; the one representation both readers can be held to.
(import (rnrs) (web fs) (web json) (web sexpr))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))
(define (raises? thunk)
  (guard (e (#t #t)) (thunk) #f))

(define TABLE "test/sexpr-escape-vectors.json")
(define doc (string->json (fs-slurp-string TABLE)))

(define (string-bytes s)
  (let loop ((i 0) (acc '()))
    (if (>= i (string-length s))
        (reverse acc)
        (loop (+ i 1) (cons (char->integer (string-ref s i)) acc)))))

;; every accepted shape reads back to the bytes the table names
(for-each
 (lambda (row)
   (let ((src (json-ref row "src"))
         (bytes (json-array->list (json-ref row "bytes"))))
     (want (string->symbol (json-ref row "want"))
           (guard (e (#t 'refused)) (string-bytes (cadr (string->sexpr src))))
           bytes)))
 (json-array->list (json-ref doc "accept")))

;; a hex escape inside a SYMBOL, which is where a writer puts one when a
;; name would otherwise be unreadable
(for-each
 (lambda (row)
   (let ((src (json-ref row "src"))
         (idx (json-ref row "sym_index")))
     (want 'symbol-hex-escape
           (guard (e (#t 'refused))
             (symbol->string (list-ref (string->sexpr src) idx)))
           (json-ref row "want_symbol"))))
 (json-array->list (json-ref doc "symbols")))

;; THE CONTROL, and it is the half that keeps the widening honest: a
;; malformed or unknown escape must still be refused.  A reader that
;; simply stopped checking after a backslash would pass every row above.
(for-each
 (lambda (row)
   (want (string->symbol (json-ref row "why"))
         (raises? (lambda () (string->sexpr (json-ref row "src"))))
         #t))
 (json-array->list (json-ref doc "reject")))

(display (if (null? fails) #t fails))
