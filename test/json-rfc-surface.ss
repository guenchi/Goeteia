;; expect: #t
;; (web json) read-side acceptance surface, pinned row by row, with the
;; RFC clause each row comes from.
;;
;; LOCKSTEP CONTRACT.  This reader has a wire counterpart, the
;; server-side (igropyr json), each parsing what the other's writer --
;; or the same third-party client -- produced.  The two share a small
;; set of DELIBERATE deviations from RFC 8259's read grammar, and
;; tightening one of them on ONE side manufactures a wire asymmetry:
;; input one side takes and the other refuses.  So every row below is
;; pinned, the deviations included.  A "fix" that flips a deviation row
;; goes red on purpose, and the answer is not to update the row but to
;; coordinate the change with the counterpart first.  The counterpart
;; holds the same table under the same row names (its
;; test/json-rfc-surface.sc), so the two files diff against each other.
;;
;; HOW THIS TABLE WAS BUILT, and why it is built this way.  An earlier
;; note in lib/web/json.ss claimed a closed set of exactly TWO
;; deviations, measured by walking RFC 8259's read side as 19
;; constraints.  It was wrong, and the way it was wrong is the reason
;; for the third column: lone surrogates had been filed under
;; "correctly rejected" because rejecting them FEELS right, not because
;; any clause was consulted.  Section 8.2 names "\uDEAD" as a text the
;; ABNF allows, and section 9 says a parser MUST accept every text the
;; grammar allows -- so refusing is a deviation, in the direction the
;; old survey had no column for.
;;
;; Hence the rule this table is written under: EVERY ROW CARRIES THE
;; CLAUSE IT COMES FROM.  A row whose clause cannot be written down is
;; a row that was filled in from intuition, which is exactly the defect
;; above.  And where a row cites a production with ranges, every
;; ENDPOINT of those ranges gets its own row -- writing the anchors for
;; `unescaped` is what turned up x1F and x7F, two characters no earlier
;; row had ever touched.
;;
;; SELF-DESTRUCT CLAUSE, shared with the counterpart: if a deviating
;; row is ever found outside families A, C and D below, the survey that
;; produced this table has failed and BOTH sides re-survey whole.  Do
;; not append the find -- one more escaping the method is evidence
;; about the method, not about the row.

;; WHY THE ALL-GREEN STRUCTURAL ROWS ARE HERE.  Most rows below have
;; never caught anything and are expected never to: the range
;; endpoints, the whitespace non-members, the escape set.  Their reason
;; for existing is the PRODUCTION, not a defect they once caught -- the
;; deliverable is that "nobody ever walked this boundary" has become
;; "it was walked and it was right", so the covered edge can be stated
;; instead of assumed.  Do not thin them out by hit rate on the next
;; pass: hit rate is what a row has caught, and these were written to
;; answer what a row COVERS.

(import (rnrs) (web json))

(define fails 0)
(define (fail name got anchor)
  (set! fails (+ fails 1))
  (display "FAIL ") (display name)
  (display " -- got ") (display got)
  (display " -- ") (display anchor) (newline))

(define (status s) (guard (e (#t 'REJECT)) (string->json s) 'ACCEPT))

;; name / input / expected verdict / the clause it comes from
(define (row name input want anchor)
  (let ((got (status input)))
    (unless (eq? got want) (fail name got anchor))))

(define (qc c) (string #\" (integer->char c) #\"))

;; ---- deviation A: leading zeros (accepted; grammar forbids) ---------
;; section 6: `int = zero / (digit1-9 *DIGIT)` -- "01" is neither.
;; Shared with the counterpart, which reaches it by handing the digit
;; run to string->number.
(define A "DEVIATION A (accept where RFC rejects) -- section 6, int = zero / (digit1-9 *DIGIT)")
(row "A/01"    "01"    'ACCEPT A)
(row "A/-01"   "-01"   'ACCEPT A)
(row "A/00"    "00"    'ACCEPT A)
(row "A/01.5"  "01.5"  'ACCEPT A)
(row "A/-00"   "-00"   'ACCEPT A)

;; ---- deviation C: bare control characters (accepted; forbidden) -----
;; section 7: `unescaped = %x20-21 / %x23-5B / %x5D-10FFFF`.  Anything
;; below %x20 is outside every range, so it must be escaped.
(define C "DEVIATION C (accept where RFC rejects) -- section 7, unescaped starts at %x20")
(row "C/newline" (qc 10) 'ACCEPT C)
(row "C/tab"     (qc 9)  'ACCEPT C)
(row "C/nul"     (qc 0)  'ACCEPT C)
(row "C/x1F"     (qc 31) 'ACCEPT C)   ; the range's lower neighbour

;; ---- deviation D: lone surrogates (rejected; grammar allows) --------
;; section 7 spells the escape as `%x75 4HEXDIG` with no pairing
;; requirement; section 8.2 names "\uDEAD" as a text the ABNF allows;
;; section 9: "A JSON parser MUST accept all texts that conform to the
;; JSON grammar."  We refuse anyway, and the cost of not refusing is
;; the reason: Goeteia strings are UTF-8 byte strings, and a lone
;; surrogate has no UTF-8 encoding -- accepting would mean emitting
;; WTF-8 and calling it a string.  So this is a deliberate refusal to
;; conform, not an oversight, and the counterpart makes the same one.
(define D "DEVIATION D (reject where RFC requires accept) -- sections 7, 8.2, 9")
(row "D/uDEAD"     "\"\\uDEAD\""         'REJECT D)
(row "D/uD800"     "\"\\uD800\""         'REJECT D)
(row "D/uDFFF"     "\"\\uDFFF\""         'REJECT D)
(row "D/high+char" "\"\\uD800\\u0041\""  'REJECT D)

;; ---- section 7, `unescaped`: every endpoint of every range ---------
(define U7 "section 7, unescaped = %x20-21 / %x23-5B / %x5D-10FFFF")
(row "U/x20-low"    (qc 32)      'ACCEPT U7)  ; first range, lower end
(row "U/x21-high"   (qc 33)      'ACCEPT U7)  ; first range, upper end
(row "U/x22-gap"    (qc 34)      'REJECT U7)  ; the quote: ends the string
(row "U/x23-low"    (qc 35)      'ACCEPT U7)  ; second range, lower end
(row "U/x5B-high"   (qc 91)      'ACCEPT U7)  ; second range, upper end
(row "U/x5C-gap"    (qc 92)      'REJECT U7)  ; the backslash: starts an escape
(row "U/x5D-low"    (qc 93)      'ACCEPT U7)  ; third range, lower end
(row "U/x7F-del"    (qc 127)     'ACCEPT U7)  ; inside the third range,
                                              ; and the should-GREEN half
                                              ; of deviation C: we must not
                                              ; be refusing DEL along with
                                              ; the real control characters
;; ⚠ FROM HERE ON THE INPUT IS BUILT BYTE BY BYTE, and the four rows
;; below used to be built with `(qc code-point)` like the ones above.
;; That works up to 127 and is a LIE past it: a Goeteia string is a
;; UTF-8 BYTE string, so `(integer->char 55295)` in one is the single
;; byte 55295 mod 256 = 0xFF.  Measured, before this was fixed:
;;
;;   row               claimed to send   actually sent
;;   U/xD7FF           U+D7FF            one byte 0xFF   (not UTF-8 at all)
;;   U/xE000           U+E000            one byte 0x00   (a NUL -- which is
;;                                       deviation C, not this production)
;;   U/x10FFFF         U+10FFFF          one byte 0xFF
;;
;; All three passed, and their anchors were correct: the clause they
;; cite really does say what they say it says.  An anchor establishes
;; what a row MEANS to test; it cannot establish that the input
;; realizes it.  Those are two different questions and this table had
;; only been asking the first.
(define (u8 . bs) (apply string (map integer->char bs)))
(define (qbytes . bs) (string-append "\"" (apply u8 bs) "\""))
(row "U/x80"     (qbytes #xC2 #x80)          'ACCEPT U7)  ; U+0080
(row "U/xD7FF"   (qbytes #xED #x9F #xBF)     'ACCEPT U7)  ; last before surrogates
(row "U/xE000"   (qbytes #xEE #x80 #x80)     'ACCEPT U7)  ; first after them
(row "U/x10FFFF" (qbytes #xF4 #x8F #xBF #xBF) 'ACCEPT U7) ; third range, upper end

;; ---- bytes that are not UTF-8 at all ------------------------------
;; RFC 8259 section 8.1 requires JSON text exchanged between systems to
;; be UTF-8, so a text carrying a lone continuation byte is not JSON
;; text.  This reader takes it and hands back the byte unchanged.
;;
;; The WRITER no longer emits it.  These lines used to say it did --
;; "measured, not inferred" -- and that was true when written and stale
;; by the end of the same batch: the writer gained a check and this
;; paragraph did not move.  The writer's half is pinned in test/json.ss;
;; nothing here calls it.
;;
;; Whether the reader's acceptance is a DEVIATION is a narrower question
;; than it looks.  Section 9 says a parser MUST accept every text that
;; conforms to the grammar and MAY accept non-JSON forms or extensions;
;; taking a malformed one is the second sentence, not a breach of the
;; first.  So these rows are not filed with A, C and D: they record an
;; extension, kept because the counterpart reader accepts it too.
(define X81 "section 8.1, JSON text SHALL be encoded in UTF-8; section 9, a parser MAY accept non-JSON forms")
(row "X/lone-cont"  (qbytes #x80)      'ACCEPT X81)
(row "X/lone-ff"    (qbytes #xFF)      'ACCEPT X81)
(row "X/truncated"  (qbytes #xE4 #xB8) 'ACCEPT X81)   ; two of a three-byte run
(row "X/overlong"   (qbytes #xC0 #x80) 'ACCEPT X81)   ; overlong NUL
(row "X/surrogate"  (qbytes #xED #xA0 #x80) 'ACCEPT X81) ; a raw surrogate half
(row "X/past-max"   (qbytes #xF4 #x90 #x80 #x80) 'ACCEPT X81) ; past U+10FFFF

;; ...and that the bytes come back UNCHANGED, which "it was accepted"
;; does not say.  `status` throws the parsed value away, so every row
;; above is satisfied by a reader that takes these and returns
;; something else -- mapping every byte >= 0x80 to `?` passes all of
;; them.  Preservation is the property that makes the acceptance worth
;; recording: a reader that mangles is not interoperable with the
;; counterpart either, it just fails later.
(let loop ((cases (list (list #x80) (list #xFF) (list #xE4 #xB8)
                        (list #xC0 #x80) (list #xED #xA0 #x80)
                        (list #xF4 #x90 #x80 #x80))))
  (unless (null? cases)
    (let* ((bs (car cases))
           (want (apply u8 bs))
           (got (guard (e (#t 'raised)) (string->json (apply qbytes bs)))))
      (unless (and (string? got) (string=? got want))
        (fail (string-append "X/preserved " (number->string (car bs)))
              got "section 8.1 -- accepted, and handed back as it arrived")))
    (loop (cdr cases))))

;; ---- section 7, the escape set: all eight, plus \u -----------------
(define E7 "section 7, char = unescaped / escape ( %x22 / %x5C / %x2F / %x62 / %x66 / %x6E / %x72 / %x74 / %x75 4HEXDIG ); escape = %x5C")
(row "E/quote"   "\"\\\"\""   'ACCEPT E7)
(row "E/bslash"  "\"\\\\\""   'ACCEPT E7)
(row "E/solidus" "\"\\/\""    'ACCEPT E7)
(row "E/b"       "\"\\b\""    'ACCEPT E7)
(row "E/f"       "\"\\f\""    'ACCEPT E7)
(row "E/n"       "\"\\n\""    'ACCEPT E7)
(row "E/r"       "\"\\r\""    'ACCEPT E7)
(row "E/t"       "\"\\t\""    'ACCEPT E7)
(row "E/u0000"   "\"\\u0000\"" 'ACCEPT E7)
;; 4HEXDIG carries HEXDIG = DIGIT / A-F / a-f, and DIGIT = %x30-39.  The
;; number rows walk %x30-39 through the number scanner, which is a
;; DIFFERENT scanner: the escape path has its own digit test, and
;; narrowing that one to %x30-38 left this whole table green until
;; these rows existed.  An endpoint belongs to the production AS USED
;; HERE, not to the character class in the abstract.
;; HEXDIG is THREE ranges, each with two ends, and the escape scanner
;; tests them as three separate conditions -- so six rows, not "one for
;; digits and one for letters".  Writing only \u9999 and \uAAAA left
;; the upper end of A-F unpinned: dropping F from the upper-case range
;; stayed green.  The same rule that produced these rows had already
;; been applied one level up, and it had to be applied again here.
(row "E/u0000-lo" "\"\\u0000\"" 'ACCEPT E7)   ; DIGIT 0
(row "E/u9999-hi" "\"\\u9999\"" 'ACCEPT E7)   ; DIGIT 9
(row "E/uaaaa-lo" "\"\\uaaaa\"" 'ACCEPT E7)   ; a-f, a
(row "E/uffff-hi" "\"\\uffff\"" 'ACCEPT E7)   ; a-f, f
(row "E/uAAAA-lo" "\"\\uAAAA\"" 'ACCEPT E7)   ; A-F, A
(row "E/uFFFF-hi" "\"\\uFFFF\"" 'ACCEPT E7)   ; A-F, F
(row "E/u-not-hex" "\"\\uGGGG\"" 'REJECT E7)  ; and nothing outside them
(row "E/uD7FF"   "\"\\ud7ff\"" 'ACCEPT E7)
(row "E/uE000"   "\"\\ue000\"" 'ACCEPT E7)
(row "E/pair"    "\"\\uD834\\uDD1E\"" 'ACCEPT E7)  ; U+1D11E, four UTF-8 bytes
(row "E/not-in-set" "\"\\q\""  'REJECT E7)
(row "E/not-x"      "\"\\x41\"" 'REJECT E7)        ; \x is not JSON's spelling
(row "E/short-u"    "\"\\u12\"" 'REJECT E7)

;; ---- section 2, ws = *(%x20 / %x09 / %x0A / %x0D) -------------------
(define W2 "section 2, ws = *(%x20 / %x09 / %x0A / %x0D) -- exactly four characters")
(row "W/space" " 1 "  'ACCEPT W2)
(row "W/tab"   "\t1"  'ACCEPT W2)
(row "W/lf"    "\n1"  'ACCEPT W2)
(row "W/cr"    "\r1"  'ACCEPT W2)
(row "W/vtab"  (string (integer->char 11) #\1) 'REJECT W2)
(row "W/ff"    (string (integer->char 12) #\1) 'REJECT W2)
;; Both of the two above are written with integer->char rather than
;; "\v" and "\f".  This is a WORKAROUND, not a style preference, and
;; "\f" is not the tidier spelling to restore: the self-hosted reader
;; takes only \t \n \r \\ \" and silently drops the backslash on the
;; rest (and reads \x41; as four characters), so those spellings
;; compile to DIFFERENT programs depending on which host compiled them,
;; with no diagnostic on either.  That is a defect against the
;; compiler, filed separately; a test file is the last place that
;; should differ by who built it.
;; The two above are the interesting half of this production: they LOOK
;; like whitespace and are not in it.  A member list is only as good as
;; its complement's neighbourhood -- listing the four that are in it
;; would be satisfied by a reader that skipped every control character.

;; ---- section 6, the number grammar ---------------------------------
(define N6 "section 6, number = [minus] int [frac] [exp]")
(row "N/0"        "0"        'ACCEPT N6)
;; int = zero / (digit1-9 *DIGIT) cites digit1-9 = %x31-39, so that
;; range gets its endpoints too -- the same rule that produced the
;; unescaped rows.  Without them the table asserted the rule and then
;; did not follow it for this production.
(row "N/1-low"    "1"        'ACCEPT N6)
(row "N/9-high"   "9"        'ACCEPT N6)
(row "N/10"       "10"       'ACCEPT N6)   ; *DIGIT includes zero after the first
(row "N/-0"       "-0"       'ACCEPT N6)
(row "N/0.5"      "0.5"      'ACCEPT N6)
(row "N/1e+5"     "1e+5"     'ACCEPT N6)
(row "N/-0.5e01"  "-0.5e01"  'ACCEPT N6)
(row "N/no-int"   ".5"       'REJECT N6)   ; int is not optional
(row "N/plus"     "+5"       'REJECT N6)   ; only minus is allowed
(row "N/plus-frac" "+.5"     'REJECT N6)
(row "N/bare-dot" "-."       'REJECT N6)
(row "N/trail-dot" "5."      'REJECT N6)   ; frac needs 1*DIGIT after the dot
(row "N/dot-exp"  "5.e3"     'REJECT N6)
(row "N/lead-dot" "-.5"      'REJECT N6)
(row "N/two-dots" "5..2"     'REJECT N6)
(row "N/exp-empty" "1e"      'REJECT N6)
(row "N/exp-empty-E" "1E"    'REJECT N6)
(row "N/exp-sign-only" "1e+" 'REJECT N6)
(row "N/exp-frac" "1e5.5"    'REJECT N6)
;; ---- the exponent, both directions -------------------------------
;; `exp = e [ minus / plus ] 1*DIGIT` puts NO limit on how many digits
;; follow, so "1e0001" -- whose value is ten -- conforms.  This reader
;; refused it: the exponent scan was capped at three digits, which is
;; neither a range nor a precision limit and so is not covered by the
;; allowance below.  The counterpart accepted it all along, so the two
;; readers disagreed about a valid document and neither table had a row
;; that would have said so.
;;
;; These rows are written in BOTH directions because the change that
;; made the first group pass was a WIDENING, and a widening that went
;; too far would look identical from the accepting side alone.
(row "N/exp-0001"  "1e0001"   'ACCEPT N6)   ; 1*DIGIT, four of them
(row "N/exp-plus"  "1e+0005"  'ACCEPT N6)
(row "N/exp-minus" "1e-0001"  'ACCEPT N6)
(row "N/exp-many"  "1e000000000000000001" 'ACCEPT N6)
;; ...and what widening the digit count must NOT take with it
(row "N/exp-none"   "1e"      'REJECT N6)   ; 1*DIGIT means at least one
(row "N/exp-sign"   "1e+"     'REJECT N6)
(row "N/exp-alpha"  "1eX"     'REJECT N6)
(row "N/exp-space"  "1e 5"    'REJECT N6)
(row "N/exp-2signs" "1e+-5"   'REJECT N6)
(row "N/exp-dot"    "1e1.0"   'REJECT N6)
;; ...and the interaction between the two gates, which is the thing a
;; test for either one alone cannot see: a LONG spelling of a LARGE
;; exponent must still be refused by the range gate.  If widening the
;; digit count had been folded into the range check, these two would
;; have started passing while every row above and below stayed green.
(row "N/exp-long-big"  "1e0000000000400" 'REJECT N6R)
(row "N/exp-long-309"  "1e00000000000000000000309" 'REJECT N6R)

;; ---- repetition operators, three tiers each -----------------------
;; Wherever the grammar says `1*X` or `*X` the count is unbounded, and
;; a reader can go wrong at either end: refusing the empty case of a
;; `*X`, or imposing a private ceiling on how many.  The private
;; ceiling is what this parser had -- three exponent digits -- and no
;; row would have found it, because every row anyone writes by hand
;; uses a "normal" number of repetitions.  So each repetition in the
;; productions cited above gets EXACTLY ONE, A TYPICAL FEW, and FAR
;; MORE THAN ANYONE WOULD WRITE.
(define REP "the count in a 1*X / *X repetition is unbounded")
(row "R/exp-1"     "1e1"                  'ACCEPT REP)
(row "R/exp-few"   "1e001"                'ACCEPT REP)
(row "R/exp-many"  "1e00000000005"        'ACCEPT REP)
;; int's *DIGIT: zero more, one more, far more
(row "R/int-0"     "7"                    'ACCEPT REP)
(row "R/int-1"     "70"                   'ACCEPT REP)
(row "R/int-many"  "1000000000000000000000000000" 'ACCEPT REP)
;; frac = decimal-point 1*DIGIT
(row "R/frac-1"    "1.5"                  'ACCEPT REP)
(row "R/frac-few"  "1.55555"              'ACCEPT REP)
(row "R/frac-many" "1.00000000000000000000000000005" 'ACCEPT REP)
(row "R/frac-0"    "1."                   'REJECT REP)   ; 1* needs one
;; string = quotation-mark *char quotation-mark: zero chars is a string
(row "R/str-0"     "\"\""                 'ACCEPT REP)
(row "R/str-1"     "\"a\""                'ACCEPT REP)
(row "R/str-many"  "\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"" 'ACCEPT REP)
;; ws = *( ... ): none, one, many
(row "R/ws-0"      "1"                    'ACCEPT REP)
(row "R/ws-1"      " 1"                   'ACCEPT REP)
(row "R/ws-many"   "        1        "    'ACCEPT REP)
;; and the array/object element repetitions, which are *(value-separator ...)
(row "R/arr-0"     "[]"                   'ACCEPT REP)
(row "R/arr-1"     "[1]"                  'ACCEPT REP)
(row "R/arr-many"  "[1,2,3,4,5,6,7,8,9,10,11,12]" 'ACCEPT REP)
(row "R/obj-0"     "{}"                   'ACCEPT REP)
(row "R/obj-1"     "{\"a\":1}"             'ACCEPT REP)
(row "R/obj-many"  "{\"a\":1,\"b\":2,\"c\":3,\"d\":4}" 'ACCEPT REP)
(row "N/underscore" "1_000"  'REJECT N6)
(row "N/ratio"    "1/2"      'REJECT N6)
(row "N/hex"      "#x10"     'REJECT N6)
(row "N/nan"      "NaN"      'REJECT N6)
(row "N/inf"      "Infinity" 'REJECT N6)
(row "N/-inf"     "-Infinity" 'REJECT N6)
;; section 6 also says an implementation MAY set limits on range and
;; precision, so refusing a literal that reads as an infinity is
;; conforming -- and it is what keeps a NUMBER from crossing the round
;; trip as `null`.  The counterpart refuses these too.
(define N6R "section 6, an implementation may set limits on range and precision")
(row "N/1e309"    "1e309"    'REJECT N6R)
(row "N/-1e309"   "-1e309"   'REJECT N6R)
(row "N/0.5e400"  "0.5e400"  'REJECT N6R)
(row "N/1e308"    "1e308"    'ACCEPT N6R)   ; the should-GREEN half
(row "N/-1e308"   "-1e308"   'ACCEPT N6R)
(row "N/maxdbl"   "1.7976931348623157e308" 'ACCEPT N6R)
(row "N/tiny"     "1e-320"   'ACCEPT N6R)   ; underflow is not overflow

;; ---- sections 3-5, the value grammar --------------------------------
(define V3 "sections 3-5, value = false / null / true / object / array / number / string")
(row "V/true"    "true"   'ACCEPT V3)
(row "V/false"   "false"  'ACCEPT V3)
(row "V/null"    "null"   'ACCEPT V3)
(row "V/scalar"  "1"      'ACCEPT V3)        ; section 2: a text is any value
(row "V/string"  "\"x\""  'ACCEPT V3)
(row "V/nested"  "[{\"a\":[1,{\"b\":null}]}]" 'ACCEPT V3)
(row "V/True"    "True"   'REJECT V3)        ; the literals are lower case
(row "V/truex"   "truex"  'REJECT V3)
(row "V/empty"   ""       'REJECT V3)
(row "V/blank"   "   "    'REJECT V3)
(row "V/trail"   "1 2"    'REJECT V3)
(row "V/trail2"  "[1] extra" 'REJECT V3)
(row "V/comma-array"  "[1,2,]"     'REJECT V3)
(row "V/comma-object" "{\"a\":1,}" 'REJECT V3)
(row "V/hole"    "[1,,2]" 'REJECT V3)
(row "V/squote"  "'a'"    'REJECT V3)
(row "V/squote-key" "{'a':1}" 'REJECT V3)
(row "V/bare-key"   "{a:1}"   'REJECT V3)   ; section 4: name is a string
(row "V/num-key"    "{1:2}"   'REJECT V3)
(row "V/comment"    "[1] // c"  'REJECT V3) ; JSON has no comments
(row "V/comment2"   "/* c */ 1" 'REJECT V3)

;; ---- section 4, duplicate names -------------------------------------
;; "The names within an object SHOULD be unique" -- SHOULD, not MUST, so
;; taking them is not a deviation.  What we do with them is a choice,
;; and it is pinned here because the counterpart makes the SAME choice
;; and the two were measured against each other rather than assumed:
;; every pair is kept, in input order, and json-ref answers the first.
(define d (string->json "{\"a\":1,\"a\":2}"))
(unless (equal? d '(("a" . 1) ("a" . 2)))
  (fail "dup/retained" d "section 4, names SHOULD be unique -- a choice, not a deviation"))
(unless (eqv? 1 (json-ref d "a"))
  (fail "dup/first" (json-ref d "a") "section 4 -- first match, same as the counterpart"))

(when (> fails 0)
  (display "rows failed: ") (display fails) (newline))
(= fails 0)
