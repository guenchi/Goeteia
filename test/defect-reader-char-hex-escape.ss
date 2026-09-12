;; expect: A
;; REGRESSION GUARD.  Written as a red witness against the reader at
;; 94e6b88, where R6RS gave a character
;; literal a hex spelling, #\x<hex>, and goeteia's reader has no branch
;; for it: %named-char takes the named set and then a single character,
;; so #\x41 is read as the NAME "x41", which is neither, and the reader
;; raises "unknown character name".  Chez answers #\A.
;;
;; Found while designing the fix for the sibling defect
;; test/defect-reader-hash-is-not-a-delimiter.ss, by asking what a
;; character literal may contain -- not by reading %named-char, whose
;; comment says it implements "the full R6RS set".  That comment is the
;; claim this cell falsifies: the named set is complete, but the named
;; set is not all of R6RS's character syntax.
;;
;; Same family as the string and symbol escapes widened in the wire
;; reader at 86a2e50, and the same asymmetry: the value has a written
;; form this implementation cannot read back.  Different file, though --
;; this is the SOURCE reader in src/prelude.ss, not (web sexpr) -- so
;; it was filed separately rather than folded into that change.
;;
;; FIXED, and the RANGE is deliberately narrower than Chez's.  A
;; character here is a byte (docs/limits.md, "Character literals stop at
;; U+007F"), so #\x1F600 is REFUSED in the same words the driver uses to
;; refuse a non-ASCII character datum, even though Chez answers one.
;; Copying Chez there would make the two hosts disagree about which
;; programs exist, which limits.md gives as the reason the literal form
;; is refused in the first place.  Measured after the fix: #\x41 and
;; #\x0041 are A, #\x is the character x, and #\X41 and #\xyz are
;; refused -- only a lowercase x opens the escape.
(import (rnrs))
(display #\x41)
