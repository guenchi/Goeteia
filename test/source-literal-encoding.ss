;; expect: every source literal denotes the same bytes on both hosts
;; A string literal in a SOURCE FILE has to mean the same thing however
;; the file is compiled.  It did not: the Chez-hosted driver read the
;; source as raw bytes (one byte = one char) so that a literal written
;; as UTF-8 would survive verbatim -- and a \xNN...; escape in that same
;; stream produced a CODE POINT, which the emitter then truncated to
;; one byte.  "\x3bb;" compiled to the single byte 187 on that host and
;; to the two bytes 206 187 on the self-hosted one, from the same file.
;;
;; The driver's own comment named the failure ("otherwise Chez decodes
;; UTF-8 to code points and compile-datum truncates them") and guarded
;; half of it: raw bytes survived, escapes did not.  The two arrive
;; INDISTINGUISHABLE at the emitter -- one byte of a UTF-8 sequence and
;; a code point below 256 are the same char -- which is why the fix is
;; at the reading boundary rather than in the emitter.
;;
;; Nothing in the tree used such an escape, so nothing went red.
(import (rnrs) (gfx fx))

(define failures 0)
(define (codes s) (map char->integer (string->list s)))
(define (want! tag s expected)
  (let ((got (codes s)))
    (unless (and (= (length got) (length expected))
                 (let loop ((a got) (b expected))
                   (or (null? a) (and (= (car a) (car b)) (loop (cdr a) (cdr b))))))
      (set! failures (+ failures 1))
      (display "  FAIL ") (display tag) (display ": want ") (display expected)
      (display " got ") (display got) (newline))))

;; ---- escapes, at and around the byte the old read truncated --------
(want! "\\x7f;"    "\x7f;"    '(127))
(want! "\\x80;"    "\x80;"    '(194 128))
(want! "\\xe9;"    "\xe9;"    '(195 169))
(want! "\\xff;"    "\xff;"    '(195 191))
(want! "\\x100;"   "\x100;"   '(196 128))   ; used to truncate to 0
(want! "\\x3bb;"   "\x3bb;"   '(206 187))
(want! "\\x1f600;" "\x1f600;" '(240 159 152 128))

;; ---- a literal written as UTF-8, which always worked ---------------
(want! "raw lambda" "λ" '(206 187))
(want! "raw emoji"  "😀" '(240 159 152 128))

;; ---- both spellings in ONE literal, which is the direct judge ------
;; The old reading could not tell a raw byte from an escaped code
;; point; a literal holding both is where that ambiguity has to show.
(want! "raw and escaped together" "λ\x3bb;" '(206 187 206 187))
(want! "escaped then raw"         "\x3bb;λ" '(206 187 206 187))
(want! "ascii around them"        "a\x3bb;bλc" '(97 206 187 98 206 187 99))

;; ---- symbol names take the same path -------------------------------
(want! "symbol name, escaped" (symbol->string (string->symbol "\x3bb;")) '(206 187))
(want! "symbol name, raw"     (symbol->string (string->symbol "λ")) '(206 187))

;; ---- line endings inside a literal are still normalised ------------
;; The reader turns a line ending inside a string into a newline, and
;; NEL (U+0085) is one.  Under the old byte reading that byte was also
;; a UTF-8 continuation, so the driver escaped it blind; under a
;; decoded reading U+5185 is one character and cannot be mistaken for
;; it.  These pin that the normalisation still happens and that a
;; character ENDING in the NEL byte is left alone.
;; An ESCAPE denotes a character and is not a line ending: "\xD;" is a
;; carriage return in the string, left alone.  A LITERAL line ending in
;; the source is what the reader normalises -- the two cells below with
;; real bytes in them cover that, and they are the ones the driver's
;; escaping exists for.
(want! "the escape \\xD; is a character, not a line ending" "x\xD;y" '(120 13 121))
(want! "the escape \\x85; is U+0085" "x\x85;y" '(120 194 133 121))
(want! "U+5185, whose UTF-8 ends in 0x85" "\x5185;" '(229 134 133))

;; Real bytes, not escapes: a carriage return and a NEL sitting inside
;; a string literal in this very file.  The reader turns each into one
;; newline.  U+0085's UTF-8 is C2 85, and the second of those bytes is
;; also NEL -- under a byte-wise reading the two were indistinguishable,
;; which is what the driver's blind escaping was for; under a decoded
;; reading they are one character and one line ending respectively.
(want! "a literal CR in a string" "xy" '(120 10 121))
(want! "a literal NEL in a string" "xy" '(120 10 121))

(display (if (= failures 0)
             "every source literal denotes the same bytes on both hosts"
             "SEE FAILURES ABOVE"))
