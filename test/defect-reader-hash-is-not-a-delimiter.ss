;; expect: abc
;; REGRESSION GUARD.  Written as a red witness against the reader where
;; %delimiter? did not count "#", so a token ran on through a block
;; comment that touched it.
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
;; THE REASON FIRST FILED FOR DEFERRING THIS WAS WRONG and is kept here
;; corrected, because it is the kind of reason that gets re-derived.  It
;; said R6RS uses # as a digit placeholder inside numbers.  R6RS REMOVED
;; R5RS's digit placeholder; Chez reads 2#|c|#3 as one token only
;; because that token opens with a digit, and Chez itself refuses a#b.
;;
;; The real collision was STACKED NUMBER PREFIXES: %read-prefixed reads
;; a whole token and peels prefixes off afterwards, so the # of #x in
;; #e#x10 sits INSIDE the token.  The repair tells the name scans apart
;; from that one rather than widening a single delimiter set --
;; %read-token and %read-prefixed are untouched, and the scans that
;; read a NAME stop at "#".  Nothing enforces which scanner a future
;; caller picks; what carries the weight is %read-token having exactly
;; one caller.  The controls are in
;; test/reader-hash-delimiter-controls.ss and 2#3 is now refused, which
;; is a named behaviour change rather than an accident.
;;
;; stage0 PASSES this: it is Chez-hosted and reads with Chez's reader,
;; so only the self-hosted path shows the gap.  Measuring on stage0
;; alone says nothing about goeteia's reader.
(import (rnrs))
(display 'abc#|c|#)
