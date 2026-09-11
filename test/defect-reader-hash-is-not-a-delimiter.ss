;; expect: abc
;; EXPECTED FAIL, and pre-existing: this cell is RED on stage1 right now
;; and that red is the defect it names.
;;
;; %delimiter? does not count "#", so a token runs on through a block
;; comment that touches it.  Chez ends the symbol at the "#|" and reads
;; abc; goeteia's own reader swallows the comment into the token and
;; answers the symbol abc#c# -- a DIFFERENT symbol, silently, with
;; nothing refused.  A wrong value is worse here than a refusal would
;; be: nothing anywhere reports it.
;;
;; The same gap refuses `#!r6rs#|c|#(display 1)`, where the directive
;; token absorbs the comment and is then unrecognised; Chez answers 1.
;; So it is not specific to directives -- directives merely meet it.
;;
;; NOT a one-line fix, which is why it is filed rather than patched:
;; R6RS uses # as a digit placeholder inside numbers, so `2#|c|#3` is a
;; single token to Chez, and adding # to %delimiter? changes number
;; lexing.  That earns a design pass of its own.
;;
;; stage0 PASSES this: it is Chez-hosted and reads with Chez's reader,
;; so only the self-hosted path shows the gap.  Measuring on stage0
;; alone says nothing about goeteia's reader.
(import (rnrs))
(display 'abc#|c|#)
