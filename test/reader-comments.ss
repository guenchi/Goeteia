;; expect: block and datum comments read as the reference reads them
;; `#|...|#` and `#;` were refused by name after the # dispatcher was
;; made to refuse what it could not read.  Refusing was right at the
;; time -- the alternative then was answering an end-of-input object
;; and silently ending the datum -- but they are ordinary syntax and
;; this implements them.
;;
;; Every expectation is Chez 10.1.0's, generated rather than recalled:
;;
;;   scheme --quiet -e '(let* ((p (open-input-string "#;1 2")))
;;                        (write (list (read p) (read p))))'
;;
;; Each cell reads TWICE.  A block comment that consumed too little
;; leaves a token behind, and a datum comment that consumed too much
;; eats the datum after it; either way the first read can look right
;; while the stream is wrong, which is the failure these forms invite.
(import (rnrs))

(define failures 0)
(define (fail! what) (set! failures (+ failures 1))
  (display "  FAIL: ") (display what) (newline))

;; (first-datum . reached-eof?) for one piece of text
(define (two s)
  (let* ((p (open-input-string s))
         (a (read p))
         (b (read p)))
    (cons a (eof-object? b))))

(define (reads? src want)
  (guard (e (#t (fail! (string-append src " raised"))))
    (let ((r (two src)))
      (cond ((not (equal? (car r) want))
             (fail! (string-append src " read as something else")))
            ((not (cdr r))
             (fail! (string-append src " left something after the datum")))))))

(define (reads-eof? src)
  (guard (e (#t (fail! (string-append src " raised"))))
    (unless (eof-object? (car (two src)))
      (fail! (string-append src " should hold no datum at all")))))

(define (refuses? src . needles)
  (guard (e ((error? e)
             (let ((m (condition-message e)))
               (for-each
                (lambda (n)
                  (unless (let* ((h (string-length m)) (k (string-length n)))
                            (let loop ((i 0))
                              (cond ((< (- h i) k) #f)
                                    ((string=? (substring m i (+ i k)) n) #t)
                                    (else (loop (+ i 1))))))
                    (fail! (string-append src ": the message does not say \""
                                          n "\" -- " m))))
                needles)))
            (#t (fail! (string-append src " refused with a non-error object"))))
    (two src)
    (fail! (string-append src " was accepted"))))

;; ---- datum comments ------------------------------------------------
(reads? "#;1 2" 2)
(reads? "#;'x y" 'y)
(reads? "(#;(1 2) 3)" '(3))            ; a whole list is one datum
(reads? "(1 #;2 3)" '(1 3))
(reads? "(1 #;2 . 3)" '(1 . 3))        ; and the dotted tail survives
;; two in a row: the first comments out the second comment's datum
(reads? "#; #; 1 2 3" 3)
(reads? "#;#;1 2 3" 3)                 ; with no space, same reading

;; ---- block comments ------------------------------------------------
;; a comment between two data: the first read is 1, and 2 is still
;; there -- so this one is asked with both reads, not with the
;; reached-eof helper
(let ((r (two "1 #|c|# 2")))
  (unless (equal? (car r) 1) (fail! "1 #|c|# 2: first datum is not 1"))
  (when (cdr r) (fail! "1 #|c|# 2: the 2 after the comment was eaten")))
(reads? "#| #; |# 1" 1)                ; a datum comment inside is text
(reads-eof? "#||#")
(reads-eof? "#|a|#")
;; NESTING is the judge here.  An implementation that scans to the
;; LAST |# passes the simple two-level case and fails this one, and an
;; implementation that stops at the FIRST |# fails it the other way --
;; so the cell reads what comes after, not just the comment.
(reads? "#| outer #| inner |# still-outer |# 7" 7)
(reads? "#| #| |# |# 5" 5)

;; ---- what stays text or stays refused ------------------------------
(reads? "\"#|not a comment|#\"" "#|not a comment|#")
(refuses? "#| unclosed" "block comment")
(refuses? "#;" "datum")                ; nothing to comment out
(refuses? "(#;)" "")                   ; must not quietly read as ()

;; ---- what ends a line comment ---------------------------------------
;; The reference ends one on LF, CR, NEL (U+0085) and LS (U+2028), and
;; NOT on PS (U+2029).  This reader sees bytes, so NEL arrives as C2 85
;; and LS as E2 80 A8.  All four go through the SAME line-ending
;; predicate as the string body and the string continuation -- one
;; supplier, three callers, and test/reader-escape.ss and
;; test/source-literal-encoding.ss hold the other two.
(define (bytes->text . bs)
  (list->string (map integer->char bs)))
(define (comment-ends? name text want)
  (guard (e (#t (fail! (string-append "comment ended by " name ": raised"))))
    (let ((v (car (two text))))
      (unless (equal? v want)
        (fail! (string-append "comment ended by " name ": read " 
                              (if (eof-object? v) "end of input" "something else")))))))
(comment-ends? "LF"  (bytes->text 59 120 10 55) 7)
(comment-ends? "CR"  (bytes->text 59 120 13 55) 7)
(comment-ends? "NEL" (bytes->text 59 120 194 133 55) 7)
(comment-ends? "LS"  (bytes->text 59 120 226 128 168 55) 7)
;; PS is not a line ending, so the 7 stays inside the comment
(let ((v (car (two (bytes->text 59 120 226 128 169 55)))))
  (unless (eof-object? v)
    (fail! "PS ended a line comment; it is not a line ending")))

(display (if (= failures 0)
             "block and datum comments read as the reference reads them"
             "SEE FAILURES ABOVE"))
