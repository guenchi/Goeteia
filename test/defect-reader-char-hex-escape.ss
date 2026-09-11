;; expect: A
;; EXPECTED FAIL against the reader at 94e6b88.  R6RS gives a character
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
;; it is filed separately rather than folded into that change.
(import (rnrs))
(display #\x41)
