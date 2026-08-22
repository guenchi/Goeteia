;; expect: #t
;; (web sexpr)'s size limits, built in Scheme rather than read out of
;; the golden fixture.
;;
;; This file exists because of a hole the fixture sweep had: the
;; oversized vectors -- the 65536- and 65537-character tokens that pin
;; the token cap -- are exactly the ones test/sexpr-golden*.ss passes
;; over as too large to parse alongside everything else.  The cap could
;; therefore have been off by any amount, or absent, with both golden
;; files green.  Each case below is one allocation and one call, which
;; is comfortable on its own, so the boundary is held here instead.
;;
;; The limits themselves are the authority's: a TOKEN is capped at
;; 65536 characters -- on the way in and, since the authority's writer
;; grew the same check, on the way out -- and nothing else is.  A long
;; string, a long list and a big bytevector are not tokens and pass
;; untouched in both directions.
(import (rnrs) (web js) (web sexpr))

;; Named skips go to STDERR, not stdout.  run-tests.sh compares the
;; WHOLE of stdout against the ";; expect:" line, so anything a passing
;; run prints there is a failure -- while "a skip must be named out
;; loud" is a rule about the log, not about the oracle's channel.  The
;; two live on different channels and both get what they need.
(define _note-chan (js-eval "globalThis.__note=(s)=>{console.error(s);}"))
(define __note (js-get (js-global) "__note"))
(define (note s) (js-call __note (js-undefined) (string->js s)))


(define fails 0)
(define (check name ok)
  (unless ok
    (display "FAIL ") (display name) (newline)
    (set! fails (+ fails 1))))
;; "It raised" is not the same as "it refused".  A crash -- a bare
;; assertion, an index out of range, a type error -- also raises, and a
;; probe that counts any raise as success cannot tell a guard doing its
;; job from the implementation falling over on the same input.  So the
;; thrown value has to be this codec's own refusal.
(define (refusal? e)
  (and (list? e) (= 3 (length e)) (eq? (car e) 'sexpr-error)))
(define (raises? thunk)
  (eq? 'refused (guard (e ((refusal? e) 'refused) (#t 'crashed)) (thunk))))

;; The other half, and it is not `(not (raises? ...))`.  That reads
;; false for a clean completion AND for a crash, so a probe written
;; that way says "accepted" when the implementation fell over.  This
;; one requires the call to finish.
(define (accepts? thunk)
  (eq? 'ok (guard (e (#t 'threw)) (thunk) 'ok)))

;; What this catches, and what it does not.  A CATCHABLE crash -- a
;; raised condition of any other shape -- now reads as a failure, which
;; is the point.  A wasm trap (an out-of-range index, a failed cast)
;; cannot be caught by `guard` at all: it takes the whole program down,
;; so the file produces no value and the suite fails it for having no
;; output rather than for saying #f.  Both are failures; only the first
;; is one this helper decides.  Do not read the shape test as a trap
;; detector.
;;
;; Worth recording: when this replaced the old "any raise is a pass"
;; version, every existing probe stayed green.  A negative result, and
;; a useful one -- it says none of them had been passing because the
;; implementation fell over on the input rather than refusing it.

;; ...and where a SECOND guard could plausibly reject the same input,
;; the reason is pinned as well.  Not everywhere: matching every
;; message would weld the tests to their wording, and better wording
;; would then read as a regression.  The rule is "is there another
;; guard near this input that would also refuse it" -- for a UTF-8
;; probe there is (the token cap, the depth limit, an unterminated
;; string), and for a base64 probe there is (bad character versus
;; non-canonical tail).
(define (refuses-because? thunk fragment)
  (guard (e ((and (refusal? e) (string-contains? (cadr e) fragment)) #t)
            (#t #f))
    (thunk)
    #f))
(define (string-contains? hay needle)
  (let ((h (string-length hay)) (n (string-length needle)))
    (let loop ((i 0))
      (cond ((> (+ i n) h) #f)
            ((string=? (substring hay i (+ i n)) needle) #t)
            (else (loop (+ i 1)))))))

;; ---- the token cap, from both sides ---------------------------------

(define cap 65536)

(check "a symbol token at the cap is read"
       (let ((v (string->sexpr (make-string cap #\a))))
         (and (symbol? v) (= cap (string-length (symbol->string v))))))

(check "one character past the cap is refused"
       (raises? (lambda () (string->sexpr (make-string (+ cap 1) #\a)))))

;; the same boundary for a NUMBER token: a cap that only counts symbol
;; characters would let an enormous digit run through, and the cost
;; there is a bignum build rather than a symbol intern
(check "a number token at the cap is read"
       (integer? (string->sexpr (make-string cap #\1))))

(check "one digit past the cap is refused"
       (raises? (lambda () (string->sexpr (make-string (+ cap 1) #\1)))))

;; ---- the WRITE side of the same cap ---------------------------------
;; The writer refuses what the reader would refuse: a name or a numeral
;; past the cap comes back as "token too long" at the far end, so it
;; does not leave in the first place.

(check "a symbol at the cap is written"
       (= cap (string-length (sexpr->string (string->symbol (make-string cap #\a))))))

(check "a symbol past the cap is refused by the writer"
       (raises? (lambda ()
                  (sexpr->string (string->symbol (make-string (+ cap 1) #\a))))))


;; NOT EXERCISED HERE: the writer's numeral cap.  Not for want of
;; trying, and not because the cases above cover it -- they are READER
;; tests and would pass with the writer's guard deleted.  The guard
;; needs a printed numeral longer than the cap, and the check can only
;; run once the numeral exists; this runtime builds the 65537-digit
;; bignum fine (measured) but exhausts itself turning it back into
;; decimal, which is the O(n^2) step the authority also performs before
;; its own check.  So the boundary is unreachable from here rather than
;; skipped for convenience.  test/sexpr-mjs.mjs holds the same guard --
;; BigInt makes the conversion cheap there -- for an integer and for a
;; ratio measured whole.  Named out loud, because a boundary nobody
;; names is a boundary nobody is holding anyone to.
(note "  NOT EXERCISED HERE (this runtime cannot print a 65537-digit bignum): the writer's numeral cap -- see test/sexpr-mjs.mjs")

;; A ratio is measured WHOLE -- "num/den" is one token to the reader --
;; so two halves that each fit can still be refused together.  That
;; case is held in test/sexpr-mjs.mjs instead: building an oversized
;; ratio here means a gcd over two 40000-digit bignums, which this
;; runtime does not survive alongside the rest of this file.  Nothing
;; in THIS file exercises the writer's numeral guard -- see the note
;; above, which says why it is unreachable here rather than skipped.

;; ---- what the cap must NOT touch ------------------------------------
;; A string is not a token: its length is bounded by the caller's body
;; limit, not by this one.  Same for a list's length and a
;; bytevector's size.  Each is checked as a round trip, so a limit that
;; silently truncated instead of raising would be caught too.

(define big-string (make-string 70000 #\a))
(check "a string past the cap survives the round trip"
       (let ((v (string->sexpr (sexpr->string big-string))))
         (and (string? v) (= 70000 (string-length v))
              (string=? v big-string))))

(define big-bytes
  (let ((bv (make-bytevector 70000 0)))
    (let loop ((i 0))
      (if (= i 70000)
          bv
          (begin (bytevector-u8-set! bv i (mod i 256)) (loop (+ i 1)))))))
(check "a bytevector past the cap survives the round trip"
       (let ((v (string->sexpr (sexpr->string big-bytes))))
         (and (bytevector? v)
              (= 70000 (bytevector-length v))
              (= 7 (bytevector-u8-ref v 7))
              (= 255 (bytevector-u8-ref v 255))
              (= (mod 69999 256) (bytevector-u8-ref v 69999)))))

;; PAST the token cap on purpose: at 4000 elements this proved nothing
;; -- a regression applying the 65536-character token cap to a list's
;; length would have left it green.  A list is not a token, and the
;; only way to say so is to be longer than one.
(define long-list-length 70000)
(define long-list
  (let loop ((k 0) (acc '()))
    (if (= k long-list-length) acc (loop (+ k 1) (cons k acc)))))
(check "a list past the token cap survives the round trip"
       (let ((v (string->sexpr (sexpr->string long-list))))
         (and (list? v) (= long-list-length (length v))
              (equal? (car v) (car long-list))
              (equal? (list-ref v (- long-list-length 1))
                      (list-ref long-list (- long-list-length 1))))))

;; NOT EXERCISED HERE: the spine cap's own boundary (1,000,001 accepted,
;; 1,000,002 refused).  Building either list costs this runtime more
;; than it has -- the 70000-element one above is already the largest
;; structure in this file -- so a moved or deleted spine guard would
;; not be caught here.  test/sexpr-mjs.mjs holds both sides of that
;; boundary and the dotted branch; named rather than left implied.
(note "  NOT EXERCISED HERE (needs a million-element list): the spine cap's boundary -- see test/sexpr-mjs.mjs")

;; ---- the VALUE behind the bytes, WITHOUT the fixture ----------------
;; The golden suites parse an authority wire with our reader and write
;; it back with our writer, which is a fixed-point test: a paired error
;; -- decoding a flonum big-endian AND encoding it big-endian -- gives
;; back the original bytes while every value in between is wrong.  So
;; here the value is built NATIVELY and its authority bytes are named,
;; with nothing of ours between the two.
;;
;; test/sexpr-anchors.ss now asks that same question across the whole
;; value model, as a cross product rather than a list.  This section is
;; NOT its leftovers and is not the place to add coverage: what it has
;; that the matrix does not is that its expected bytes are LITERALS IN
;; THIS SOURCE.  Everything the matrix knows it learns from
;; test/sexpr-vectors.json, so a fixture regenerated against a broken
;; authority, or edited, takes the matrix with it and leaves this
;; standing.  Two mechanisms reaching the same answer by different
;; routes is the point; one of them being smaller is fine, and it is
;; deliberately CLOSED -- a new value branch goes in the generator's
;; matrix (emitted as the fixture's `anchors` group, consumed by
;; test/sexpr-anchors.ss), not here.  That file carries the same note
;; pointing back at this one, so whoever finds one of the two learns
;; why the other exists before deciding it is a duplicate.

(define (writes? value bytes)
  (let ((r (guard (e (#t 'raised)) (sexpr->string value))))
    (and (string? r) (string=? r bytes))))
(define (reads-as? bytes ok?)
  (let ((r (guard (e (#t 'raised)) (string->sexpr bytes))))
    (and (not (eq? r 'raised)) (ok? r))))

;; 1.5 is #f8"AAAAAAAA+D8=" -- little-endian IEEE-754.  Read big-endian
;; it would be 5.7e-322, and written back big-endian it would still
;; produce these same bytes.
(check "a native flonum writes the authority's bytes"
       (writes? 1.5 "#f8\"AAAAAAAA+D8=\""))
(check "the authority's bytes read back as that flonum"
       (reads-as? "#f8\"AAAAAAAA+D8=\""
                  (lambda (v) (and (flonum? v) (fl=? v 1.5)))))
(check "one that is not symmetric under byte order"
       (and (writes? 0.1 "#f8\"mpmZmZmZuT8=\"")
            (reads-as? "#f8\"mpmZmZmZuT8=\""
                       (lambda (v) (and (flonum? v) (fl=? v 0.1))))))

;; the same for a bytevector: base64 with the alphabet in the wrong
;; order would round-trip through itself and be wrong on the wire
(check "a native bytevector writes the authority's bytes"
       (writes? (let ((bv (make-bytevector 3 0)))
                  (bytevector-u8-set! bv 0 0)
                  (bytevector-u8-set! bv 1 1)
                  (bytevector-u8-set! bv 2 255)
                  bv)
                "#vu8\"AAH/\""))
(check "the authority's bytes read back as those octets"
       (reads-as? "#vu8\"AAH/\""
                  (lambda (v) (and (bytevector? v)
                                   (= 3 (bytevector-length v))
                                   (= 0 (bytevector-u8-ref v 0))
                                   (= 1 (bytevector-u8-ref v 1))
                                   (= 255 (bytevector-u8-ref v 2))))))

;; and an exact ratio, whose sign and order a paired slip could swap
(check "a native ratio writes the authority's bytes"
       (writes? -7/2 "-7/2"))
(check "the authority's bytes read back as that ratio"
       (reads-as? "-7/2" (lambda (v) (and (rational? v) (exact? v)
                                          (= v -7/2)))))

;; Each of the following was a PAIRED mutation that survived every
;; fixed-point sweep: swap #t and #f on both sides, negate integers on
;; both sides, reverse vectors on both sides, exchange the two string
;; escapes on both sides, swap the two zeros on both sides.  Every one
;; reproduces the authority's bytes exactly while the Scheme value in
;; between is wrong, so each needs an anchor of its own.

(check "booleans are not swapped"
       (and (writes? #t "#t") (writes? #f "#f")
            (reads-as? "#t" (lambda (v) (eq? v #t)))
            (reads-as? "#f" (lambda (v) (eq? v #f)))))

(check "integers keep their sign, magnitude and EXACTNESS"
       ;; integer? and = both accept 42.0, so a paired change that read
       ;; integer tokens as flonums and printed integral flonums as
       ;; integer text would survive without the exact? here
       (and (writes? 42 "42") (writes? -42 "-42") (writes? 0 "0")
            (reads-as? "42" (lambda (v) (and (integer? v) (exact? v) (= v 42))))
            (reads-as? "-42" (lambda (v) (and (integer? v) (exact? v) (= v -42))))
            (reads-as? "0" (lambda (v) (and (integer? v) (exact? v) (= v 0))))))

(check "a vector keeps its order"
       (and (writes? (vector 1 2 3) "#(1 2 3)")
            (reads-as? "#(1 2 3)"
                       (lambda (v) (and (vector? v) (= 3 (vector-length v))
                                        (= 1 (vector-ref v 0))
                                        (= 3 (vector-ref v 2)))))))

;; Swapping () and #() for ZERO-LENGTH values only, on both sides,
;; reproduces every fixture byte: the fixture has both empties and each
;; rewrites to itself, and every other native anchor here is non-empty.
(check "the empty list and the empty vector are not exchanged"
       (and (writes? '() "()")
            (writes? (vector) "#()")
            (reads-as? "()" (lambda (v) (and (null? v) (not (vector? v)))))
            (reads-as? "#()" (lambda (v) (and (vector? v)
                                              (= 0 (vector-length v))
                                              (not (null? v)))))))

;; A dotted pair whose halves are exchanged on both sides also
;; round-trips; the head and tail below are told apart by value.
(check "a dotted pair keeps head and tail in place"
       (and (writes? (cons 1 2) "(1 . 2)")
            (writes? (cons 1 (cons 2 3)) "(1 2 . 3)")
            (reads-as? "(1 . 2)"
                       (lambda (v) (and (pair? v) (= 1 (car v)) (= 2 (cdr v)))))
            (reads-as? "(1 2 . 3)"
                       (lambda (v) (and (pair? v) (= 1 (car v))
                                        (pair? (cdr v)) (= 2 (cadr v))
                                        (= 3 (cddr v)))))))

(check "a list keeps its order"
       (and (writes? (list 1 2 3) "(1 2 3)")
            (reads-as? "(1 2 3)"
                       (lambda (v) (and (pair? v) (= 1 (car v))
                                        (= 3 (car (cddr v))))))))

;; the two escapes: exchanging their meanings on both sides round-trips
(check "the string escapes are not exchanged"
       (and (writes? (string #\") "\"\\\"\"")
            (writes? (string #\\) "\"\\\\\"")
            (reads-as? "\"\\\"\"" (lambda (v) (and (string? v) (= 1 (string-length v))
                                             (char=? (string-ref v 0) #\"))))
            (reads-as? "\"\\\\\"" (lambda (v) (and (string? v) (= 1 (string-length v))
                                              (char=? (string-ref v 0) #\\))))))

;; the two zeros: every other flonum anchor here is nonzero, so a
;; paired sign swap on zero would have gone unnoticed
(define neg-zero (fl* (fl- 0.0 1.0) 0.0))
(define (neg-zero? v) (and (flonum? v) (fl<? (fl/ 1.0 v) 0.0)))
(check "the two zeros are not swapped"
       (and (writes? 0.0 "#f8\"AAAAAAAAAAA=\"")
            (writes? neg-zero "#f8\"AAAAAAAAAIA=\"")
            ;; ...and it has to BE zero: "a flonum that is not negative
            ;; zero" is also true of 1.0, of infinity and of a NaN
            (reads-as? "#f8\"AAAAAAAAAAA=\""
                       (lambda (v) (and (flonum? v) (fl=? v 0.0)
                                        (not (neg-zero? v)))))
            (reads-as? "#f8\"AAAAAAAAAIA=\""
                       (lambda (v) (and (neg-zero? v) (fl=? v 0.0))))))

;; The two infinities: flipping their sign in BOTH DataView calls
;; round-trips the fixture's two entries perfectly, and every other
;; flonum anchor here (1.5, 0.1, the zeros) is unaffected by it.
(define pos-inf (fl/ 1.0 0.0))
(define neg-inf (fl/ (fl- 0.0 1.0) 0.0))
(check "the infinities are not exchanged"
       (and (writes? pos-inf "#f8\"AAAAAAAA8H8=\"")
            (writes? neg-inf "#f8\"AAAAAAAA8P8=\"")
            (reads-as? "#f8\"AAAAAAAA8H8=\""
                       (lambda (v) (and (flonum? v) (fl<? 0.0 v)
                                        (fl=? v (fl* v 2.0)))))
            (reads-as? "#f8\"AAAAAAAA8P8=\""
                       (lambda (v) (and (flonum? v) (fl<? v 0.0)
                                        (fl=? v (fl* v 2.0)))))))

;; Newline, tab and return travel as themselves inside a string -- this
;; format escapes only " and \ -- and each is read back from BOTH the
;; raw character and its escape.  Swapping newline and tab on every one
;; of those paths at once round-trips the fixture's literal-newline,
;; tab and escape probes byte for byte; only a native anchor tells them
;; apart.
(check "the control characters are not exchanged"
       (and (writes? (string #\newline) "\"\n\"")
            (writes? (string #\tab) "\"\t\"")
            (writes? (string #\return) "\"\r\"")
            (reads-as? "\"\n\"" (lambda (v) (and (string? v) (= 1 (string-length v))
                                            (char=? (string-ref v 0) #\newline))))
            (reads-as? "\"\t\"" (lambda (v) (and (string? v) (= 1 (string-length v))
                                            (char=? (string-ref v 0) #\tab))))
            (reads-as? "\"\r\"" (lambda (v) (and (string? v) (= 1 (string-length v))
                                            (char=? (string-ref v 0) #\return))))
            ;; ...and from the escape spellings the reader also accepts
            (reads-as? "\"\\n\"" (lambda (v) (and (string? v) (= 1 (string-length v))
                                              (char=? (string-ref v 0) #\newline))))
            (reads-as? "\"\\t\"" (lambda (v) (and (string? v) (= 1 (string-length v))
                                              (char=? (string-ref v 0) #\tab))))
            (reads-as? "\"\\r\"" (lambda (v) (and (string? v) (= 1 (string-length v))
                                              (char=? (string-ref v 0) #\return))))))

;; base64 across its WHOLE alphabet: "AAH/" exercises three sextet
;; values, so swapping two letters in both tables survived it.  These
;; 48 bytes walk every value 0..63 in order.
(define alphabet-bytes
  (let* ((bs '(0 16 131 16 81 135 32 146 139 48 211 143 65 20 147 81
               85 151 97 150 155 113 215 159 130 24 163 146 89 167 162
               154 171 178 219 175 195 28 179 211 93 183 227 158 187
               243 223 191))
         (bv (make-bytevector (length bs) 0)))
    (let loop ((i 0) (xs bs))
      (if (null? xs)
          bv
          (begin (bytevector-u8-set! bv i (car xs))
                 (loop (+ i 1) (cdr xs)))))))
(define alphabet-wire
  (string-append "#vu8\"ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                 "abcdefghijklmnopqrstuvwxyz0123456789+/\""))
(check "base64 uses the whole alphabet in the right order"
       (and (writes? alphabet-bytes alphabet-wire)
            ;; every byte, not three of them: swapping two letters in
            ;; the DECODER table alone corrupts interior bytes while
            ;; offsets 0, 1 and 47 stay right
            (reads-as? alphabet-wire
                       (lambda (v)
                         (and (bytevector? v)
                              (= 48 (bytevector-length v))
                              (let loop ((i 0))
                                (or (= i 48)
                                    (and (= (bytevector-u8-ref v i)
                                            (bytevector-u8-ref alphabet-bytes i))
                                         (loop (+ i 1))))))))))
;; ...and padding, which "AAH/" has none of
;; base64 has two guards that can refuse the same payload -- a
;; character outside the alphabet, and a non-canonical tail -- and a
;; probe for one of them is green when the other fires.  These name
;; which.
(check "a bad base64 character is refused as such"
       (and (refuses-because? (lambda () (string->sexpr "#vu8\"A!A=\""))
                              "bad base64")
            (refuses-because? (lambda () (string->sexpr "#f8\"AAAAAAAAAAA!\""))
                              "bad base64")))
(check "a non-canonical tail is refused as such"
       ;; How these two were chosen is the point: both characters are
       ;; INSIDE the base64 alphabet, so the character rule cannot fire
       ;; and only the leftover-bits rule can refuse them.  Pinning a
       ;; reason is only worth anything when the sample can be refused
       ;; for that reason alone -- otherwise the probe passes on the
       ;; other guard and says nothing about the one it names.
       ;;
       ;; The two guards also had to be given DIFFERENT words before
       ;; this could mean anything: they both used to say "bad base64
       ;; in X", so matching that phrase proved only that one of them
       ;; fired.
       (and (refuses-because? (lambda () (string->sexpr "#vu8\"AB\""))
                              "non-canonical")
            (refuses-because? (lambda () (string->sexpr "#vu8\"AR==\""))
                              "non-canonical")))
(check "a flonum of the wrong length is refused as such"
       (refuses-because? (lambda () (string->sexpr "#f8\"AAAAAAAAAAAA\""))
                         "8 bytes"))

(check "base64 padding round-trips"
       (let ((one (let ((bv (make-bytevector 1 0)))
                    (bytevector-u8-set! bv 0 255) bv))
             (two (let ((bv (make-bytevector 2 0)))
                    (bytevector-u8-set! bv 0 255)
                    (bytevector-u8-set! bv 1 254) bv)))
         (and (writes? one "#vu8\"/w==\"")
              (writes? two "#vu8\"//4=\"")
              ;; ...and read back, which the label claimed all along
              (reads-as? "#vu8\"/w==\""
                         (lambda (v) (and (bytevector? v)
                                          (= 1 (bytevector-length v))
                                          (= 255 (bytevector-u8-ref v 0)))))
              (reads-as? "#vu8\"//4=\""
                         (lambda (v) (and (bytevector? v)
                                          (= 2 (bytevector-length v))
                                          (= 255 (bytevector-u8-ref v 0))
                                          (= 254 (bytevector-u8-ref v 1))))))))

;; ---- a string this runtime can build but the wire cannot carry -----
;; The other side of "accepting a value is a promise": this runtime's
;; strings are UTF-8 bytes and nothing stops one from being malformed.

(define (mk-bytes . bs) (list->string (map integer->char bs)))
(define (wire-of . bs)
  (string-append "\"" (apply mk-bytes bs) "\""))
;; both directions: the reader has to refuse what the writer refuses,
;; or it accepts bytes it cannot itself write back
;; These pin the reason as well, though the justification is narrower
;; than it first looked: the inputs are short, top-level and closed, so
;; the token cap (which does not apply inside a string), the depth
;; guard and "unterminated string" cannot actually fire on them.  What
;; the pinning does buy is that the refusal is the UTF-8 one rather
;; than some future guard added nearby -- cheap here, since these
;; probes exist precisely to exercise that one check.
(define (both-refuse? . bs)
  (and (refuses-because? (lambda () (sexpr->string (apply mk-bytes bs)))
                         "UTF-8")
       (refuses-because? (lambda () (string->sexpr (apply wire-of bs)))
                         "UTF-8")))
(define (both-accept? . bs)
  (and (accepts? (lambda () (sexpr->string (apply mk-bytes bs))))
       (accepts? (lambda () (string->sexpr (apply wire-of bs))))))

(check "well-formed UTF-8 goes out and comes in"
       (and (both-accept? 228 184 173)             ; U+4E2D, three bytes
            (both-accept? 240 159 152 128)         ; U+1F600, four bytes
            (both-accept? 194 128)                 ; U+0080, the two-byte floor
            (both-accept? 223 191)                 ; U+07FF, its ceiling
            (both-accept? 237 159 191)             ; U+D7FF, just below D800
            (both-accept? 238 128 128)             ; U+E000, just above DFFF
            (both-accept? 244 143 191 191)))       ; U+10FFFF, the last one

;; Each of these pins a boundary the state machine could be one off at.
;; The earlier "lone continuation byte" probe used #xff, which is not a
;; continuation byte at all -- it proved the 0xF5..0xFF rule twice and
;; the continuation rule not once.
(check "a real continuation byte where a lead byte belongs"
       (both-refuse? 128))                          ; 0x80
(check "0xC0 and 0xC1 are always overlong"
       (and (both-refuse? 192 175) (both-refuse? 193 191)))
(check "0xF5..0xFF are never lead bytes"
       (and (both-refuse? 245 128 128 128) (both-refuse? 255)))
;; "at every length" was three of the six shapes a truncation can
;; take: a 2-byte lead has one, a 3-byte lead two, a 4-byte lead three.
;; The three that were missing are the ones where the lead byte is
;; followed by NOTHING and the string simply ends -- measured, the
;; predicate refused them all, but no test asked, and mutating it to
;; accept a bare 0xF0 or 0xE4 left this whole suite green, and the
;; whole gate with it.  A name that says "every" over a hand-written
;; list is only as true as the list.
(check "a truncated sequence, at every length"
       (and (both-refuse? 194)                       ; 2-byte, nothing after
            (both-refuse? 228 184)                   ; 3-byte, one short
            (both-refuse? 228)                       ; 3-byte, nothing after
            (both-refuse? 240 159 152)               ; 4-byte, one short
            (both-refuse? 240 159)                   ; 4-byte, two short
            (both-refuse? 240)))                     ; 4-byte, nothing after
(check "a lead byte followed by a non-continuation"
       (both-refuse? 228 65 173))
(check "the surrogate range is excluded"
       (and (both-refuse? 237 160 128)               ; U+D800
            (both-refuse? 237 191 191)))             ; U+DFFF
(check "a three-byte overlong is excluded"
       (both-refuse? 224 128 128))                   ; would be U+0000
(check "a four-byte overlong is excluded"
       (both-refuse? 240 128 128 128))               ; would be U+0000
;; a non-continuation in a LATER slot, not just the first: the earlier
;; probe only ever broke the sequence at slot 1
(check "a non-continuation in the last slot"
       (and (both-refuse? 228 184 65)                ; 3-byte, bad slot 2
            (both-refuse? 240 159 152 65)))          ; 4-byte, bad slot 3
(check "a non-continuation in the MIDDLE slot"
       ;; slot 2 of four is its own branch: probes for the first and
       ;; the last leave it untested, and removing it accepts F0 9F 41 80
       (both-refuse? 240 159 65 128))
(check "past U+10FFFF is excluded"
       (both-refuse? 244 144 128 128))               ; U+110000

;; ---- the depth limit, at its own boundary ---------------------------
;; 64 levels of nesting are legal and 65 are not; the fixture covers
;; this too, but those vectors are small enough to keep here as well,
;; and having the two boundaries in one file makes the pair obvious.

(define (nest-text k leaf)
  (let loop ((i 0) (s leaf))
    (if (= i k) s (loop (+ i 1) (string-append "(" s ")")))))

(check "64 levels are read" (accepts? (lambda () (string->sexpr (nest-text 64 "1")))))
(check "65 levels are refused" (raises? (lambda () (string->sexpr (nest-text 65 "1")))))

(= fails 0)
