;; expect: #t
;; (web json), ported from Igropyr's json.sc: parse, serialize,
;; path access, escapes (incl. \uXXXX to UTF-8 and surrogate pairs),
;; hand-assembled numbers, hostile input.
(import (rnrs) (web json))

(define (parse-fails? s)
  (guard (e ((vector? e) (eq? (vector-ref e 0) 'json-error)))
    (string->json s)
    #f))
(define (near? v x) (and (< (- x 0.000001) v) (< v (+ x 0.000001))))

(and
 ;; scalars
 (equal? (string->json "42") 42)
 (equal? (string->json "-7") -7)
 (equal? (string->json "true") #t)
 (equal? (string->json "false") #f)
 (equal? (string->json "null") 'null)
 (equal? (string->json "\"hi\"") "hi")
 ;; numbers: fractions and exponents, assembled exactly
 (fl=? (string->json "0.5") 0.5)
 (fl=? (string->json "-2.25") -2.25)
 (fl=? (string->json "1e3") 1000.0)
 (fl=? (string->json "1.5e2") 150.0)
 (fl=? (string->json "25e-2") 0.25)
 (equal? (string->json "12345678901234567890123") 12345678901234567890123)
 ;; structures
 (equal? (string->json "{\"a\":1,\"b\":[2,3]}")
         '(("a" . 1) ("b" . #(2 3))))
 (equal? (string->json "[]") '#())
 (equal? (string->json "{}") '())
 (equal? (string->json " { \"k\" : [ true , null ] } ")
         '(("k" . #(#t null))))
 ;; string escapes; é is UTF-8 bytes in a Goeteia string
 (equal? (string->json "\"a\\n\\t\\\"b\\\\c\\/d\"")
         (string #\a #\newline #\tab #\" #\b #\\ #\c #\/ #\d))
 (equal? (string->json "\"\\u0041\"") "A")
 (= (string-length (string->json "\"\\u00e9\"")) 2)      ; é = 2 bytes
 (= (string-length (string->json "\"\\ud83d\\ude00\"")) 4) ; emoji = 4 bytes
 ;; writer: round trips through the text
 (equal? (string->json (json->string '(("x" . 1) ("y" . #("a" #t null)))))
         '(("x" . 1) ("y" . #("a" #t null))))
 (string=? (json->string '(("a" . 1) ("b" . 2))) "{\"a\":1,\"b\":2}")
 (string=? (json->string '#(1 "two" #t)) "[1,\"two\",true]")
 (string=? (json->string '()) "{}")
 (string=? (json->string 'null) "null")
 (string=? (json->string "q\"q") "\"q\\\"q\"")
 ;; ratios serialize as their inexact value
 (near? (string->json (json->string 1/4)) 0.25)
 ;; path access
 (= (json-ref (string->json "{\"user\":{\"id\":42,\"tags\":[\"a\",\"b\"]}}")
              "user" "id")
    42)
 (equal? (json-ref (string->json "{\"user\":{\"tags\":[\"a\",\"b\"]}}")
                   'user 'tags 1)
         "b")
 (not (json-ref (string->json "{\"a\":1}") "missing"))
 ;; hostile input fails loudly
 (parse-fails? "{\"a\":}")
 (parse-fails? "[1,]")
 (parse-fails? "\"unterminated")
 (parse-fails? "01x")
 (parse-fails? "1.5 garbage")
 (parse-fails? "\"\\ud800\"")            ; lone high surrogate
 (parse-fails? "\"\\q\"")
 (parse-fails? "tru")
 (parse-fails? ""))
