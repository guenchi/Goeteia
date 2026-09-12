;; expect: (1 . #(2))
;; REGRESSION GUARD.  Written as a red witness against src/prelude.ss
;; at 6a46f34, the SHARP half
;; of the leading dot boundary: what follows the dot here is a DATUM,
;; not a comment.
;;
;; The branch deciding whether "." is a tail marker or the start of a
;; symbol tests %delimiter? alone, and "#" is not in that set.  So the
;; reader takes the dot as beginning a name, %read-atom stops at the
;; "#" -- which it now does, since 6701d9d -- and the name is "."
;; alone: "a lone . is not a datum".  Chez answers (1 . #(2)).
;;
;; IT DISCRIMINATES A REPAIR THAT ONLY SKIPS COMMENTS.  Its sibling
;; test/defect-reader-dot-leading-boundary.ss puts a block comment after
;; the dot, and a fix that consumed atmosphere there would turn that one
;; green while leaving this one red, because there is no atmosphere here
;; to consume -- #(2) is the tail itself.  The two must go green
;; together.
;;
;; The measurement that says what the repair is: `(1 . #|c|# 2)`, with a
;; SPACE after the dot, already works.  So $read handles atmosphere in
;; datum position perfectly well and nothing needs extracting for it --
;; the only thing missing is that the dot does not end at a "#".  Since
;; 6701d9d a "#" always terminates a name, so a dot followed by one can
;; only ever be a tail marker, and the test after the dot can say so.
;;
;; stage0 PASSES this, being Chez-hosted.  Only the self-hosted reader
;; shows it.
(import (rnrs))
(write '(1 .#(2)))
