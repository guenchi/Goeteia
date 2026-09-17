;; expect: #t
;; test/obstacle-identity.ss rests on a premise it never asserts: that
;; "shape/ab" and "shape/bC" land in the same bucket, so that the two
;; identities it then separates are actually being separated BY the
;; equality predicate rather than by never having met.  The premise
;; lives in a comment there.  If the identity hash ever changed and
;; those two names stopped colliding, that cell would quietly become an
;; ordinary two-object test -- still green, and no longer testing the
;; thing its name claims.  This cell is that premise, written down where
;; it can fail.
;;
;; The collision is structural rather than lucky: both names share a
;; prefix, and 31*97 + 98 = 31*98 + 67 = 3105, so the two suffixes "ab"
;; and "bC" drive any multiply-by-31 rolling hash to the same value
;; whatever the modulus.  That is why this holds for the runtime's
;; string-hash (modulus 2^29-1) and held for the private modulus
;; 16777213 the library used to carry.
;;
;; THE CONTROL IS NOT DECORATION.  An assertion that two strings hash
;; alike is satisfied by a hash that returns a constant, which would
;; also make the identity cell vacuous in the other direction.  The
;; second row rules that out: a name one letter away must NOT collide.
(import (rnrs))
(define colliding-a "shape/ab")
(define colliding-b "shape/bC")
(define near-miss "shape/ac")
(and
 (= (string-hash colliding-a) (string-hash colliding-b))
 (not (= (string-hash colliding-a) (string-hash near-miss))))
