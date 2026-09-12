;; expect: #t
;; EXPECTED FAIL against src/prelude.ss at 175cfee.  integer->char
;; accepts any integer at all and hands back a character outside every
;; range this implementation claims to have.
;;
;; docs/limits.md says the model in one sentence: "A character in this
;; runtime is a byte, and a string is a sequence of bytes, so there is
;; no room in a character for a code point that needs more than one."
;; The READER enforces that -- #\lambda is refused by name on both
;; hosts, deliberately, and limits.md gives the reason: accepting it on
;; one host would mean the two compilers disagreed about which programs
;; exist.  integer->char enforces nothing, so the same value the reader
;; refuses can be minted at run time.
;;
;; THE ROWS SPLIT INTO TWO KINDS and only the first is a settled
;; question.
;;
;; Beyond Unicode is wrong under ANY model and R6RS requires the
;; refusal: integer->char takes a Unicode scalar value, so #x110000 and
;; the surrogates are not arguments.  Measured: (integer->char 1114112)
;; answers a character whose char->integer is 1114112.
;;
;; Between U+0080 and U+10FFFF is a DESIGN question and is only
;; observed here, not asserted, because narrowing an exported primitive
;; is not this cell's to decide.  What the rows below do record is that
;; the two halves of the language disagree today:
;;   (string-length (string (integer->char 233)))  is 1
;;   (string-length "\xE9;")                       is 2
;; and those two strings are NOT string=?, though R6RS says a character
;; and its hex spelling denote the same thing.  A character that cannot
;; be put into a string faithfully is a value the rest of the language
;; cannot hold.
;;
;; WHERE THE CHECK CAN AND CANNOT GO, measured, so this is not
;; re-derived.  integer->char is not a prelude procedure: it is a
;; COMPILER PRIMITIVE emitted at compiler.ss:4295 as three instructions
;; that set the tag bit, with nowhere in them to put a test.  And it
;; cannot be emitted inline either, because the only refusal available
;; in generated code is a wasm TRAP, and a trap ABORTS rather than
;; raising -- the guard in this very cell would not catch one.  So the
;; check has to be in Scheme, which means splitting the primitive:
;; rename it %integer->char and let the prelude define a checked public
;; integer->char over it.  That touches the compiler's primitive
;; vocabulary, 28 uses in the prelude and 8 in the compiler, and is
;; self-affecting in both.
;;
;; Two of those uses are PER BYTE -- %fill-bytes at prelude:1248, once
;; per byte of every string built from bytes, and port output at
;; prelude:616 -- so a checked public name reached from the inside
;; would put two comparisons and a call on every byte of every string.
;; The shape that answers it is internals pointing at the raw name,
;; chosen site by site rather than swept.
;;
;; AND A RANGE CHECK DOES NOT SETTLE THE OBSERVED ROW, which is why
;; this is parked rather than queued.  Even restricted to 0..255:
;;   (string (integer->char 233))  is a ONE-byte string holding #xE9
;;   "\xE9;"                       is TWO bytes, U+00E9 in UTF-8
;; A string literal's \x...; names a CODE POINT and encodes it;
;; integer->char names a BYTE.  R6RS says they denote the same thing
;; and in this design they cannot, at any range.  So the disagreement
;; has a documentation half -- docs/limits.md explains the character
;; LITERAL limit and stops -- that no check answers.
;;
;; Nothing enforces the model at run time at all: the primitive sets a
;; tag bit and char->integer clears it, so the only thing holding
;; "a character is a byte" anywhere is the reader.
(import (rnrs))
(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))
(define (raises? thunk) (guard (e (#t #t)) (thunk) #f))

;; settled: outside Unicode is not a scalar value
(want 'past-the-top-of-unicode (raises? (lambda () (integer->char #x110000))) #t)
(want 'far-past-the-top (raises? (lambda () (integer->char 1114112))) #t)
(want 'a-surrogate (raises? (lambda () (integer->char #xD800))) #t)
(want 'negative (raises? (lambda () (integer->char -1))) #t)

;; CONTROL: the range the implementation does claim keeps working, so a
;; repair cannot pass by refusing too widely.  These must stay green.
(want 'CONTROL-ascii (char->integer (integer->char 65)) 65)
(want 'CONTROL-nul (char->integer (integer->char 0)) 0)
(want 'CONTROL-top-byte (char->integer (integer->char 255)) 255)

;; OBSERVED, not asserted: the disagreement between the character type
;; and the string type above ASCII.  Recorded as a reading rather than
;; a requirement, because which side gives way is a design decision.
(want 'OBSERVED-char-and-its-hex-spelling-differ
      (list (string-length (string (integer->char 233)))
            (string-length "\xE9;")
            (string=? (string (integer->char 233)) "\xE9;"))
      (list 1 2 #f))

(display (if (null? fails) #t fails))
