;; expect: every string escape reads as the characters Chez reads
;; The escape table, asked through `read` at runtime so the probe
;; passes through the reader and nothing else.
;;
;; The table had three entries -- \n \t \r -- and an `else` that
;; returned the byte itself.  So `\a` was the letter a, `\v` was the
;; letter v, and `\x41;` was the four characters x, 4, 1 and semicolon:
;; not a refusal, not a diagnostic, just a different string from the
;; one the source says.  docs/determinism.md records the same shape
;; happening once before with the line continuation, and says why it
;; stayed hidden for years: both hosts' programs WORKED, they just
;; built different strings.
;;
;; Every expectation is Chez's, read off by hand from
;;     scheme --quiet -e '(map char->integer (string->list (read ...)))'
;; and no row is a guess.  Two of them are worth naming because they
;; are not what a reading of R6RS would predict:
;;   "\x;"    with no hex digits at all is accepted, as codepoint 0
;;   "\X41;"  with a capital X is refused; only lower-case x opens one
(import (rnrs) (notrun))

(define failures 0)
(define (fail! what) (set! failures (+ failures 1))
  (display "  FAIL: ") (display what) (newline))
(define (rd s) (with-input-from-string s read))
(define (codes s) (map char->integer (string->list s)))
(define (same? a b)
  (and (= (length a) (length b))
       (let loop ((a a) (b b))
         (or (null? a) (and (= (car a) (car b)) (loop (cdr a) (cdr b)))))))

(define (reads? src want)
  (guard (e (#t (fail! (string-append src " raised")) #f))
    (let ((v (rd src)))
      (cond ((not (string? v)) (fail! (string-append src " is not a string")) #f)
            ((same? (codes v) want) #t)
            (else (fail! (string-append src " read as the wrong characters")) #f)))))

(define (refuses? src)
  (guard (e (#t #t))
    (let ((v (rd src))) (fail! (string-append src " was accepted")) #f)))

;; ---- the single-letter escapes R6RS defines ------------------------
;; Four of these -- \a \b \v \f -- produced the letter itself, which is
;; a plausible-looking string and so the least likely thing to be
;; noticed by anyone reading output.
(reads? "\"\\a\"" '(7))
(reads? "\"\\b\"" '(8))
(reads? "\"\\t\"" '(9))
(reads? "\"\\n\"" '(10))
(reads? "\"\\v\"" '(11))
(reads? "\"\\f\"" '(12))
(reads? "\"\\r\"" '(13))
(reads? "\"\\\"\"" '(34))
(reads? "\"\\\\\"" '(92))

;; ---- and what is NOT an escape -------------------------------------
;; The old `else` made every one of these the letter, silently.  A
;; reader that invents a meaning for an unknown escape cannot ever
;; report a typo.
(refuses? "\"\\q\"")
(refuses? "\"\\e\"")
(refuses? "\"\\0\"")                    ; not an octal escape in R6RS

;; ---- the hex escape ------------------------------------------------
(reads? "\"\\x41;\"" '(65))
(reads? "\"\\x0041;\"" '(65))           ; leading zeros are fine
(reads? "\"\\x41;f\"" '(65 102))        ; the semicolon ends it, f is text
; A string in this runtime is a sequence of UTF-8 BYTES -- the reader
;; takes source bytes one at a time -- so a code point above 127 is
;; more than one character here, and asking for (1114111) would be
;; asking this implementation to be a different one.  What must hold is
;; that the ESCAPE and the LITERAL denote the same string, since the
;; escape exists for source files that cannot carry the character.
;; That property is asserted directly below; the byte counts are a
;; consequence of it, not the thing being held.
(reads? "\"\\x10ffff;\"" '(244 143 191 191))   ; U+10FFFF as UTF-8
(reads? "\"\\x3bb;\"" '(206 187))              ; lambda as UTF-8
(unless (string=? (rd "\"\\x3bb;\"") "λ")
  (fail! "\\x3bb; and the literal character are different strings"))
(unless (string=? (rd "\"\\x41;\"") "A")
  (fail! "\\x41; and the literal A are different strings"))
(reads? "\"\\x;\"" '(0))                ; no digits at all: Chez says 0
;; two adjacent escapes, because a terminator consumed twice or not at
;; all only shows when something follows
(reads? "\"\\x41;\\x42;\"" '(65 66))
(reads? "\"\\n\\x41;\\t\"" '(10 65 9))

(refuses? "\"\\x41\"")                  ; no semicolon
(refuses? "\"\\xd800;\"")               ; a surrogate is not a character
(refuses? "\"\\xdfff;\"")
(refuses? "\"\\x110000;\"")             ; past the largest code point
(refuses? "\"\\X41;\"")                 ; capital X does not open one
(refuses? "\"\\xg;\"")                  ; not a hex digit

;; ---- the line continuation, which is not an escape ------------------
;; The negative control for this change: it was fixed once already, and
;; the fix lives in the same cond that is being rewritten here.
(reads? "\"a\\\n   b\"" '(97 98))
(reads? "\"a\\   \n   b\"" '(97 98))

;; ---- a continuation ends on every line ending, not just LF ---------
;; A backslash followed by a line ending stands for nothing.  The
;; reference accepts LF, CR, CRLF, NEL and CR+NEL and LS there; this
;; reader knew only LF and CR, so "\<NEL>" was reported as an unknown
;; escape -- the string BODY had been taught the whole set and the
;; continuation test had not.  One predicate now answers for both.
(define (bytes->text . bs) (list->string (map integer->char bs)))
(define (continues? name . mid)
  (let ((text (apply bytes->text 34 97 92 (append mid (list 98 34)))))
    (guard (e (#t (fail! (string-append "continuation by " name ": raised"))))
      (let ((v (rd text)))
        (unless (and (string? v) (same? (codes v) '(97 98)))
          (fail! (string-append "continuation by " name ": wrong value")))))))
(continues? "LF" 10)
(continues? "CR" 13)
(continues? "CRLF" 13 10)
(continues? "NEL" 194 133)
(continues? "LS" 226 128 168)
(continues? "CR+NEL" 13 194 133)

;; ---- and the string BODY, read at runtime --------------------------
;; A line ending inside a literal is one newline.  That is the third
;; caller of the same predicate, and it needs its own cell HERE rather
;; than in test/source-literal-encoding.ss: that file tests SOURCE
;; literals, and on the Chez-hosted compiler those are read by Chez, so
;; a mutation to this reader cannot reach it.  Measured -- the same
;; mutation reds the two suites that read at runtime and leaves that
;; one green.
(define (body-is? name want . mid)
  (let ((text (apply bytes->text 34 97 (append mid (list 98 34)))))
    (guard (e (#t (fail! (string-append "body " name ": raised"))))
      (let ((v (rd text)))
        (unless (and (string? v) (same? (codes v) want))
          (fail! (string-append "body " name ": wrong bytes")))))))
(body-is? "LF"     '(97 10 98) 10)
(body-is? "CR"     '(97 10 98) 13)
(body-is? "CRLF"   '(97 10 98) 13 10)
(body-is? "NEL"    '(97 10 98) 194 133)
(body-is? "LS"     '(97 10 98) 226 128 168)
(body-is? "CR+NEL" '(97 10 98) 13 194 133)
;; PS is not a line ending: its three bytes stay
(body-is? "PS"     '(97 226 128 169 98) 226 128 169)

(display (if (= failures 0)
             "every string escape reads as the characters Chez reads"
             "SEE FAILURES ABOVE"))
