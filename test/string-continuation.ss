;; expect: #t
;; R6RS 4.2.5: a backslash followed by intraline whitespace, a line
;; ending and more intraline whitespace stands for NOTHING.  It is how a
;; long string literal is broken across source lines, and it is NOT an
;; escape -- the pair produces no character at all.
;;
;; This exists because the two hosts disagreed about it.  Chez elides
;; the continuation; this runtime's reader had no case for it, so the
;; pair fell through to the escape table's `else` and became a newline.
;; The consequence was not a wrong string in one place: it was that the
;; SAME SOURCE compiled to different bytes on the two hosts, which is
;; the invariant docs/determinism.md exists to hold.  Nothing used the
;; escape until a test file did, and then the cross-host check caught it.
(import (rnrs))

(define fails 0)
(define (check name ok)
  (unless ok
    (display "FAIL ") (display name) (newline)
    (set! fails (+ fails 1))))

;; the plain case: the pair vanishes, and so does the indentation after it
(check "a continuation joins the halves with nothing between"
       (string=? "ab" "a\
                       b"))

;; intraline whitespace BEFORE the line ending is part of it too
(check "trailing spaces before the line ending are eaten"
       (string=? "ab" "a\   
                       b"))

;; ...and what is NOT a continuation still escapes as it always did
(check "the escapes proper are untouched"
       (and (= 1 (string-length "\n"))
            (= 10 (char->integer (string-ref "\n" 0)))
            (= 9 (char->integer (string-ref "\t" 0)))
            (= 13 (char->integer (string-ref "\r" 0)))
            (string=? "\"" (string (integer->char 34)))
            (string=? "\\" (string (integer->char 92)))))

;; a continuation at the very start and very end of the contents
(check "a continuation may sit at either edge"
       (and (string=? "x" "\
                           x")
            (string=? "x" "x\
                           ")))

(= fails 0)
