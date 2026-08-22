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
 ;; JSON names eight one-character escapes and the line above walks five
 ;; of them.  The other three are here: with \b untested its result could
 ;; be changed to form feed and nothing said so.
 (equal? (string->json "\"\\b\\f\\r\"")
         (string (integer->char 8) (integer->char 12) #\return))
 (equal? (string->json "\"\\u0041\"") "A")
 ;; THE BYTES, not the count.  Length alone says only that something
 ;; two bytes long came out: replacing the continuation byte with a
 ;; constant #x80 keeps é two bytes long and turns it into À, and every
 ;; length assertion stayed green.  A length is the weakest thing that
 ;; can be said about an encoding -- the encoding IS the bytes.
 (let ((bytes (lambda (s)
                (let loop ((i 0) (acc '()))
                  (if (= i (string-length s))
                      (reverse acc)
                      (loop (+ i 1)
                            (cons (char->integer (string-ref s i)) acc)))))))
   (and (equal? '(#xC3 #xA9) (bytes (string->json "\"\\u00e9\"")))      ; U+00E9
        (equal? '(#xC2 #x80) (bytes (string->json "\"\\u0080\"")))      ; 2-byte low end
        (equal? '(#xDF #xBF) (bytes (string->json "\"\\u07ff\"")))      ; 2-byte high end
        (equal? '(#xE0 #xA0 #x80) (bytes (string->json "\"\\u0800\"")))  ; 3-byte low end
        (equal? '(#xE4 #xB8 #xAD) (bytes (string->json "\"\\u4e2d\"")))
        (equal? '(#xEF #xBF #xBF) (bytes (string->json "\"\\uffff\"")))  ; 3-byte high end
        (equal? '(#xF0 #x90 #x80 #x80)                                  ; 4-byte low end
                (bytes (string->json "\"\\ud800\\udc00\"")))
        (equal? '(#xF0 #x9F #x98 #x80) (bytes (string->json "\"\\ud83d\\ude00\"")))
        (equal? '(#xF4 #x8F #xBF #xBF)                                  ; 4-byte high end
                (bytes (string->json "\"\\udbff\\udfff\"")))
        (equal? '(#x41) (bytes (string->json "\"\\u0041\"")))          ; 1-byte
        (equal? '(#x7F) (bytes (string->json "\"\\u007f\"")))))       ; 1-byte high end
 ;; writer: round trips through the text
 (equal? (string->json (json->string '(("x" . 1) ("y" . #("a" #t null)))))
         '(("x" . 1) ("y" . #("a" #t null))))
 (string=? (json->string '(("a" . 1) ("b" . 2))) "{\"a\":1,\"b\":2}")
 (string=? (json->string '#(1 "two" #t)) "[1,\"two\",true]")
 (string=? (json->string '()) "{}")
 ;; the OTHER half of the list rule, which the header states and nothing
 ;; asserted: a non-empty plain list is an array.  Without this line the
 ;; whole `list?` branch could be switched off and every test stayed green.
 (string=? (json->string '(1 2)) "[1,2]")
 (string=? (json->string '("a" #t)) "[\"a\",true]")
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
 (parse-fails? "1e999")
 (parse-fails? (string-append "1e" (make-string 10000 #\9)))
 (parse-fails? "")

 ;; ---- arrays are vectors, and there is a name that says so ----------
 ;; The trap first, because the helpers exist for it: `list?` is the
 ;; predicate a caller reaches for and it is wrong in BOTH directions --
 ;; #f for every array, #t for every object.  Pinned as a fact about
 ;; this data model rather than left as folklore.
 (not (list? (string->json "[1,2,3]")))
 (not (list? (string->json "[]")))
 (list? (string->json "{\"a\":1}"))
 (list? (string->json "{}"))

 ;; json-array? -- the whole truth table, so an implementation that
 ;; happened to use pair?, or non-emptiness, or where the value came
 ;; from, could not pass it
 (json-array? (string->json "[]"))
 (json-array? (string->json "[1,2]"))
 (json-array? (vector))                    ; not only parsed ones
 (json-array? (vector 1 2))
 (not (json-array? (string->json "{}")))          ; the empty object
 (not (json-array? (string->json "{\"a\":1}")))
 (not (json-array? '()))                          ; which is also '()
 (not (json-array? (list 1 2)))                   ; a plain list
 (not (json-array? 1))
 (not (json-array? "x"))
 (not (json-array? 'null))
 ;; BOTH booleans, parsed and native.  #t alone left `(or (vector? x)
 ;; (eq? x #f))` passing every line here -- the table was a table with
 ;; one leg of a pair on it.
 (not (json-array? #t))
 (not (json-array? #f))
 (not (json-array? (string->json "true")))
 (not (json-array? (string->json "false")))
 (not (json-array? (string->json "null")))
 (not (json-array? (string->json "0")))
 (not (json-array? (string->json "\"s\"")))

 ;; json-array->list, and the fact that it stops at one level
 (equal? '() (json-array->list (string->json "[]")))
 (equal? '(1 2 3) (json-array->list (string->json "[1,2,3]")))
 (equal? '("a" "b") (json-array->list (string->json "[\"a\",\"b\"]")))
 ;; SHALLOW: the nested array is still a vector afterwards, and still
 ;; answers json-array?.  A deep conversion would change what every
 ;; nested test says, which is not what the name promises.
 (let ((l (json-array->list (string->json "[[1,2],3]"))))
   (and (= 2 (length l))
        (json-array? (car l))
        (equal? '(1 2) (json-array->list (car l)))
        (= 3 (cadr l))))
 ;; a non-array is an error, not an empty list: answering '() would
 ;; turn the mistake this section is about into a loop that runs zero
 ;; times, which is the same silence one level over
 (guard (e (#t #t)) (json-array->list (string->json "{\"a\":1}")) #f)
 (guard (e (#t #t)) (json-array->list '()) #f)
 (guard (e (#t #t)) (json-array->list (list 1 2)) #f)
 (guard (e (#t #t)) (json-array->list "x") #f)
 (guard (e (#t #t)) (json-array->list 1) #f)
 ;; ...and it does answer for the thing it is for
 (equal? '(1) (json-array->list (vector 1)))

 ;; ---- the writer will not emit bytes that are not UTF-8 ----------
 ;; RFC 8259 section 8.1: JSON text shall be UTF-8.  A Goeteia string
 ;; is a byte string, so a caller can hold one that never was, and the
 ;; writer used to copy it out and call the result JSON text.
 ;;
 ;; Asymmetric on purpose: the READER still takes these.  Section 9
 ;; permits accepting non-JSON forms, and the reader this one is paired
 ;; with takes them too -- refusing on one side only would mean one
 ;; side rejects a document the other accepts, which is the thing the
 ;; pairing exists to prevent.  Narrow what you emit, not what you
 ;; accept.
 (let* ((u8 (lambda bs (apply string (map integer->char bs))))
        (refused? (lambda (x) (guard (e (#t #t)) (json->string x) #f))))
   (and (refused? (u8 #x80))                    ; a lone continuation byte
        (refused? (u8 #xFF))                    ; never a UTF-8 byte at all
        (refused? (u8 #xE4 #xB8))               ; two of a three-byte run
        (refused? (u8 #xC0 #x80))               ; overlong NUL
        (refused? (u8 #xED #xA0 #x80))          ; a surrogate half
        (refused? (list (cons "k" (u8 #x80))))  ; and nested, not just bare
        (refused? (vector (u8 #x80)))
        ;; ...and the should-GREEN half, or "refuse everything" passes
        (string=? "\"hi\"" (json->string "hi"))
        (string=? (u8 34 #xE4 #xB8 #xAD 34) (json->string (u8 #xE4 #xB8 #xAD)))
        (string? (json->string (u8 #xF0 #x9F #x98 #x80)))
        ;; the reader is deliberately unchanged
        (guard (e (#t #f))
          (string=? (u8 #x80)
                    (string->json (string-append "\"" (u8 #x80) "\""))))))

 ;; ---- the writer's control-character family, all 32 of it --------
 ;; RFC 8259 section 7 requires every character below %x20 to be
 ;; escaped.  The writer names three of them (\n \r \t) and sends the
 ;; other 29 through one `< code 32` test, and NOTHING used to reach
 ;; any of them: changing that test to `< code 31` left every suite
 ;; green while U+001F went out raw, i.e. the writer emitted text no
 ;; JSON reader may accept.
 ;;
 ;; This has to assert the OUTPUT TEXT.  The obvious round-trip check
 ;; -- write it, read it back, compare -- cannot see this defect at
 ;; all, because deviation A/C above means our own reader ACCEPTS the
 ;; bare control character the writer wrongly emitted.  A deliberate
 ;; looseness on the read side silently disqualifies the read side as
 ;; a witness for the write side, and that is general: every tolerance
 ;; costs whatever evidence used to run through it.
 ;; IDENTITY, not just escaping.  The loop below asks that nothing raw
 ;; survives; that alone is satisfied by escaping the wrong character,
 ;; and the hex digit table is one edit away from doing exactly that --
 ;; "0123456789abcdef" -> "0103456789abcdef" makes U+0002 come out as
 ;; \u0000 while every "is it escaped" question still answers yes.  So
 ;; each member's exact spelling is built HERE, from the code point,
 ;; and compared: an expected value assembled by the thing under test
 ;; is not an expected value.
 (let* ((hex "0123456789abcdef")
        (spelled
         (lambda (c)
           (cond ((= c 9) "\\t") ((= c 10) "\\n") ((= c 13) "\\r")
                 (else (string-append
                        "\\u00"
                        (string (string-ref hex (div c 16))
                                (string-ref hex (mod c 16)))))))))
   (let loop ((c 0))
     (or (= c 32)
         (and (string=? (string-append "\"" (spelled c) "\"")
                        (json->string (string (integer->char c))))
              (loop (+ c 1))))))
 (let ((clean?                       ; no raw control character survives
        (lambda (out)
          (let scan ((i 0))
            (or (= i (string-length out))
                (and (>= (char->integer (string-ref out i)) 32)
                     (scan (+ i 1))))))))
   (let loop ((c 0))
     (or (= c 32)
         (and (let ((out (json->string (string (integer->char c)))))
                ;; nothing raw survives, AND something was written --
                ;; "no control character in the output" alone is
                ;; satisfied by dropping the character entirely
                (and (clean? out) (> (string-length out) 3)))
              (loop (+ c 1))))))
 ;; the three named spellings, so a change from \n to \u000a is visible
 (string=? "\"\\n\"" (json->string (string (integer->char 10))))
 (string=? "\"\\r\"" (json->string (string (integer->char 13))))
 (string=? "\"\\t\"" (json->string (string (integer->char 9))))
 ;; the two that look like they would be named and are not
 (string=? "\"\\u0008\"" (json->string (string (integer->char 8))))
 (string=? "\"\\u000c\"" (json->string (string (integer->char 12))))
 ;; both ends of the range, and the first character past it: 0x1F is
 ;; the one a `< 31` boundary lets through, 0x20 must stay raw
 (string=? "\"\\u0000\"" (json->string (string (integer->char 0))))
 (string=? "\"\\u001f\"" (json->string (string (integer->char 31))))
 (string=? "\" \"" (json->string (string (integer->char 32))))
 ;; DEL is NOT in the family -- section 7 puts %x7F inside
 ;; unescaped's third range, so escaping it would be over-reach
 (string=? (string #\" (integer->char 127) #\") (json->string (string (integer->char 127))))
 ;; and the two characters that must be escaped from outside the range
 (string=? "\"\\\"\"" (json->string "\""))
 (string=? "\"\\\\\"" (json->string "\\"))

 ;; ---- numbers past the flonum range ------------------------------
 ;; These used to be ACCEPTED, and the value they produced was an
 ;; infinity, which the writer spells `null`.  So a NUMBER became NULL
 ;; across one round trip, silently, and in place inside arrays and
 ;; objects.  RFC 8259 section 6 lets a parser limit the range it
 ;; accepts; refusing is that limit, and it is the answer (igropyr
 ;; json) already gives, so the two readers agree about this input.
 (parse-fails? "1e309")
 (parse-fails? "-1e309")
 (parse-fails? "0.5e400")          ; overflows with a small exponent
 (parse-fails? "[1e309]")          ; and the refusal reaches inside
 (parse-fails? "{\"k\":1e309}")    ;   arrays and objects
 ;; The should-GREEN half of the same table.  A refusal that is merely
 ;; wider than intended reads exactly like a correct one from the red
 ;; side alone, and the boundary is where a range check is most likely
 ;; to be off: the largest finite double must still go through.
 ;; Written without exponent LITERALS, and that is a WORKAROUND, not a
 ;; style preference -- do not "tidy" it back to 1e308.  The
 ;; self-hosted reader refuses `1e308` outright ("exponent literals are
 ;; not supported ... write the constant out") while the Chez-hosted
 ;; stage accepts it, so the spelling decides whether this file builds
 ;; at all, depending on who compiled it.  That asymmetry is a known
 ;; defect against the compiler, not against this test.  So the green
 ;; direction is asserted as what it actually needs to say: these are
 ;; taken, they are positive, they are far above anything spellable
 ;; here, and the sign survives.
 (let ((v (string->json "1e308")))
   (and (> v 1000000.0) (= v (string->json "1e308"))))
 (let ((v (string->json "-1e308")))
   (and (< v -1000000.0) (= (- v) (string->json "1e308"))))
 (> (string->json "1.7976931348623157e308") (string->json "1e308"))
 ;; and just past it is refused -- the largest finite double is taken,
 ;; the next thing up is not, which is what makes the row above a
 ;; boundary rather than just another accepted number
 (parse-fails? "1.8e308")
 (= 0 (string->json "0"))
 (= 0 (string->json "-0"))
 ;; underflow is not overflow: it is accepted, and stays positive.
 ;; Written without a subnormal LITERAL on purpose -- the compiler
 ;; cannot encode one (see the note at the end of this file).
 (let ((v (string->json "1e-320"))) (and (> v 0.0) (< v 1.0)))

 ;; WHICH GATE REFUSED.  Three independent judges stand between the
 ;; text and the value -- how many digits, how big the exponent, and
 ;; whether the result is finite -- and a plain "it was refused" cannot
 ;; tell them apart.  That matters here because removing the exponent
 ;; bound entirely left every verdict row green: the finiteness check
 ;; catches the same inputs one step later.  What it does NOT catch is
 ;; the WORK -- pow10 of a million-digit exponent is built before any
 ;; value exists to test -- and that bound only became load-bearing
 ;; when the digit count was widened in this batch.  So these ask for
 ;; the reason by name.
 (let ((why (lambda (s)
              (guard (e ((vector? e) (vector-ref e 1)))
                (string->json s)
                'accepted))))
   (and (string=? "exponent out of range" (why "1e1000000"))
        (string=? "exponent out of range" (why "1e0000000000000001000000"))
        ;; the sign is a three-member family -- absent, +, - -- and the
        ;; oversized cases used to exercise only the first, so guarding
        ;; the bound with `(and (not esign) ...)` kept every row green
        ;; while a signed exponent walked past it
        (string=? "exponent out of range" (why "1e+1000000"))
        (string=? "exponent out of range" (why "1e-1000000"))
        (string=? "number out of range" (why "1e309"))
        (string=? "number out of range" (why "0.5e400"))
        ;; and the digit-count judge is not one of these two
        (string=? "number is too long"
                  (why (string-append "1e"
                                      (let loop ((k 5000) (a ""))
                                        (if (= k 0) a
                                            (loop (- k 1)
                                                  (string-append a "1")))))))))

 ;; A long spelling is the same number.  Verdict rows live in
 ;; test/json-rfc-surface.ss; these pin the VALUE, because "it was
 ;; accepted" would also be satisfied by accepting it as something
 ;; else -- the digit count was widened here, and a scan that widened
 ;; wrongly could accept "1e0001" as 1e1000 just as easily.
 (= (string->json "1e0001") (string->json "1e1"))
 (= (string->json "1e+0005") (string->json "1e5"))
 (= (string->json "1e-0001") (string->json "1e-1"))
 (= (string->json "1e000000000000000001") (string->json "1e1"))

 ;; The property behind all of the above, and the reason the cases
 ;; above are cases rather than the whole story: whatever this reader
 ;; accepts, the writer must spell so that reading it back gives the
 ;; same value.  Stating it as "the output is not `null`" -- which is
 ;; what the infinity bug produced -- would have been a stand-in for
 ;; the property rather than the property, and it passes for an output
 ;; that is not even JSON.  This asks for the value.
 (let loop ((xs '("0" "-0" "1" "-1" "1.5" "0.1" "1e0" "-0.5e01"
                  "12345678901234567890" "536870911" "-2.5e-3")))
   (or (null? xs)
       (and (let ((v (string->json (car xs))))
              (equal? v (string->json (json->string v))))
            (loop (cdr xs)))))

 ;; ...and the boundary that property stops at, pinned so it cannot be
 ;; mistaken for covered.  The runtime cannot turn a large flonum into
 ;; text at all: $display-flonum* in src/prelude.ss gives up above the
 ;; i31 fixnum range and writes `<big-flonum>`.  That is `display`, and
 ;; number->string is display into a string, so display, write,
 ;; number->string and every string-append built on them share the one
 ;; broken path -- (web json) is simply the first consumer anyone
 ;; noticed, not the place the defect lives.  DELIBERATELY NOT FIXED
 ;; HERE: the fix is a real dtoa in the runtime, which is neither this
 ;; codec nor this batch.
 ;; ROWS THAT EXIST TO BE DELETED.  Each one asserts a defect, so each
 ;; one goes RED the day the defect is fixed -- that failure is the
 ;; signal to remove the row and widen the property above, not to
 ;; update the expected text.  All three come from one place, the
 ;; runtime's float stringification in src/prelude.ss -- one path
 ;; behind display, write and number->string alike -- and none of them
 ;; is in this codec; fixing them means writing a real dtoa, which is
 ;; not this batch.  They are pinned here anyway, as a CONSUMER-side
 ;; sentinel: (web json) is where they reach a wire, and a gap with no
 ;; assertion has nothing to announce it.  When the runtime is fixed
 ;; these go red, and that red is what says the consumer side came
 ;; right too -- it is the signal to delete them and widen the property
 ;; above, never to update the expected text.
 ;;
 ;;   1. past the i31 fixnum range the printer gives up entirely and
 ;;      emits a placeholder, so json->string produces text that is
 ;;      not JSON -- worse than the infinity case fixed above, which
 ;;      at least produced a legal value of the wrong type
 (string=? "<big-flonum>" (json->string 1000000000.0))
 ;;   2. the fraction is truncated at twelve digits rather than being
 ;;      rounded to the shortest form that reads back, so an ordinary
 ;;      decimal changes value on the way out
 (string=? "3.141589999999" (json->string 3.14159))
 ;;   3. and the same truncation flattens anything smaller than the
 ;;      twelfth digit to zero, which is why the underflow row above
 ;;      asks only that the value be positive
 (string=? "0.000000000000" (json->string (string->json "1e-320")))
 ;; Just under the boundary it still round-trips, which is what says
 ;; the rows above are about the printer's RANGE and not about every
 ;; fractional value.  536870911.5 does NOT belong here: the printer
 ;; compares against 536870911.0 and gives up on anything greater, so
 ;; the half is already past it -- an assumed boundary, measured.
 (equal? (string->json "536870910.5")
         (string->json (json->string (string->json "536870910.5")))))
