;; expect: #t
;; The reader's diagnostics carry a position, and the position names
;; where the offending construct was OPENED -- not where the reader
;; finally noticed, which for an unbalanced file is its very end.
;; Every expected line/column below is counted out by hand from the
;; input string beside it.
(define (msg thunk)
  (guard (e ((error? e) (condition-message e)))
    (thunk)
    "no-error"))
(define (msg-of s) (msg (lambda () (read (open-input-string s)))))

(and
 ;; ---- an unclosed list reports its own open paren ----
 ;; "(a b)\n(c\n    (d e\n": three lines.  The innermost list opens on
 ;; line 3 at the 5th byte; the enclosing one opened on line 2 at byte
 ;; 1.  The inner one is the one that must be named.  Reading twice
 ;; from the same port also proves the position survives between
 ;; reads: the first read consumes line 1 only.
 (let ((p (open-input-string "(a b)\n(c\n    (d e\n")))
   (and (equal? (read p) '(a b))
        (string=? (msg (lambda () (read p)))
                  "list opened at line 3 column 5 never closed")))

 ;; a list opened on line 1 at column 1, ended by a dotted tail that
 ;; runs off the end
 (string=? (msg-of "(a . b")
           "list opened at line 1 column 1 never closed")

 ;; #(...) reports the paren it actually opened with
 (string=? (msg-of "\n  #(1 2")
           "list opened at line 2 column 4 never closed")

 ;; ---- a close paren with nothing open reports itself ----
 (let ((p (open-input-string "(a)\n  )")))
   (and (equal? (read p) '(a))
        (string=? (msg (lambda () (read p)))
                  "unexpected ) at line 2 column 3")))
 (string=? (msg-of ")") "unexpected ) at line 1 column 1")

 ;; ---- an unclosed string reports its open quote ----
 (string=? (msg-of "\n  \"abc")
           "string opened at line 2 column 3 never closed")
 ;; a trailing backslash cannot swallow the end of input
 (string=? (msg-of "\"abc\\")
           "string opened at line 1 column 1 never closed")

 ;; ---- an unknown character name says where it ended ----
 (string=? (msg-of "#\\nosuch ")
           "unknown character name ending at line 1 column 8")

 ;; ---- columns count BYTES, so a multi-byte character is as wide as
 ;; its encoding.  The literal below is three bytes; the open paren
 ;; that follows sits at byte 7 of the line.
 (let ((p (open-input-string "\"中\" (")))
   (and (string=? (read p) "中")
        (string=? (msg (lambda () (read p)))
                  "list opened at line 1 column 7 never closed")))

 ;; ---- well-formed input is unaffected ----
 (equal? (read (open-input-string "(1 2 (3 . 4) #(5) \"hi\" #\\a)"))
         '(1 2 (3 . 4) #(5) "hi" #\a))
 ;; comments, newlines and nesting all still read, and the counting
 ;; that runs through them changes nothing about the value
 (equal? (read (open-input-string
                "; a comment\n(alpha\n   (beta . gamma) ; trailing\n   #(1 2))"))
         '(alpha (beta . gamma) #(1 2)))
 (let ((p (open-input-string "1 \"two\" (three)")))
   (and (equal? (read p) 1)
        (equal? (read p) "two")
        (equal? (read p) '(three))
        (eof-object? (read p))))

 ;; ---- reading a nested port leaves the outer port's position alone:
 ;; the inner read below burns three lines, and the outer port must
 ;; still report line 3 for its own unclosed list ----
 (let ((outer (open-input-string "(a\n b\n  (c")))
   (and (equal? (read (open-input-string "\n\n\nx")) 'x)
        (string=? (msg (lambda () (read outer)))
                  "list opened at line 3 column 3 never closed"))))
