;; expect: 5
;; REGRESSION GUARD. Written as a red witness against the pre-directive
;; reader (snapshot bd5880e8), where goeteia's own # dispatch had
;; branches for t, f, ', (, the number prefixes, v and \ and nothing for
;; !, so #!r6rs -- a lexical directive R6RS defines and every file may
;; open with -- was refused with "unrecognised # syntax: #!".
;;
;; The reason this one was easy to get wrong, and why the cell earns its
;; place: stage0 PASSED it the whole time.  stage0 is Chez-hosted and
;; reads source with CHEZ's reader, which implements directives, so the
;; stage0 and js paths accepted #!r6rs and only the self-hosted reader
;; refused it.  Measuring on stage0 alone says goeteia supports
;; directives; it says nothing about goeteia's reader.
;;
;; Found by attempting to add #!r6rs to every .ss file in the tree: the
;; self-build failed at src/prelude.ss line 1, the snapshot refusing to
;; read its own source.  Fixed by putting directives in the atmosphere
;; layer beside #| and #; rather than in the datum reader -- the datum
;; reading cannot express (1 #!r6rs) or a directive at end of input,
;; where there is no following datum to attach to.  The negative half,
;; that an unknown directive RAISES rather than being swallowed, is in
;; test/reader-diagnostics.mjs.
#!r6rs
(import (rnrs))
(display 5)
