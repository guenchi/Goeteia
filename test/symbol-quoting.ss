;; expect: every symbol name survives being written and read back
;; A symbol whose name cannot be spelled bare has to be escaped on the
;; way out, or the writer emits something that is not the datum it was
;; given.  It did: (write (string->symbol "a b")) put `a b` on the
;; wire, which reads back as the symbol `a` with `b` left over, and the
;; empty symbol wrote as nothing at all and read back as end-of-input.
;; Same family as the string escapes and the \x escape before it --
;; a value that survives in memory and not through the printer.
;;
;; THE ORACLE IS CHEZ, AND IT CONTRADICTED THE PLAN.  The brief said to
;; wrap such names in |...|; Chez does not.  It writes INLINE \xNN;
;; escapes -- `a b` goes out as `a\x20;b` -- and uses || for exactly
;; one name, the empty one, because there is no inline escape for
;; nothing.  Measured, not assumed:
;;
;;   scheme --quiet -e '(write (string->symbol "a b"))'   =>  a\x20;b
;;   scheme --quiet -e '(write (string->symbol ""))'      =>  ||
;;
;; Chez's READER takes both spellings, so this reader takes both too:
;; refusing input the reference accepts is a lockstep gap pointing the
;; other way.  The hex digits are upper case with no padding, which is
;; also measured -- a tab is `\x9;`, not `\x09;`.
;;
;; (web sexpr) has its own wire-symbol rule and is NOT this contract.
;; It answers a different question -- what may cross to a peer that is
;; not a Scheme reader -- and neither file speaks for the other.
(import (rnrs) (notrun))

(define failures 0)
(define (fail! what) (set! failures (+ failures 1))
  (display "  FAIL: ") (display what) (newline))
(define (rd s) (with-input-from-string s read))
(define (wr x) (with-output-to-string (lambda () (write x))))

;; ---- the writer, byte for byte against Chez ------------------------
(define (writes? name want)
  (let ((got (wr (string->symbol name))))
    (unless (string=? got want)
      (fail! (string-append "(write (string->symbol " (wr name) ")) gave "
                            (wr got) ", Chez gives " (wr want))))))

(writes? "abc"    "abc")
(writes? "a-b?!"  "a-b?!")
(writes? "+"      "+")
(writes? "-"      "-")
(writes? "..."    "...")
(writes? "λ"      "λ")                  ; non-ASCII needs no escape
(writes? "a b"    "a\\x20;b")
(writes? ""       "||")                 ; the one name with no inline form
(writes? "a|b"    "a\\x7C;b")
(writes? "a\\b"   "a\\x5C;b")
(writes? "a\"b"   "a\\x22;b")
(writes? "a(b"    "a\\x28;b")
(writes? "a)b"    "a\\x29;b")
(writes? "a;b"    "a\\x3B;b")
(writes? "a\tb"   "a\\x9;b")            ; minimal digits, not \x09;
(writes? "a#b"    "a\\x23;b")
(writes? "#ab"    "\\x23;ab")
(writes? "1abc"   "\\x31;abc")          ; a name that would read as a number
(writes? "1"      "\\x31;")
(writes? "1.5"    "\\x31;.5")
(writes? "."      "\\x2E;")             ; the one token this reader refuses bare

;; ---- the arrow prefix, which exempts ONE byte and not the name -----
;; `+`, `-` and `...` are whole names that need no escaping.  `->` is
;; not one of them: it lets the leading `-` stand and nothing else.
;; Treating it as a whole-name exemption wrote "->a b" bare, which
;; reads back as `->a` with `b` left over -- the very failure this file
;; exists to close, reintroduced by the exemption meant to spell `->x`.
;; Found by review, not by the cells above: every name they tested
;; began with an ordinary byte.
(writes? "->x"    "->x")
(writes? "->"     "->")
(writes? "->a b"  "->a\\x20;b")
(writes? "->|"    "->\\x7C;")
(writes? "->#"    "->\\x23;")
(writes? "->\\x41;" "->\\x5C;x41\\x3B;")   ; the name is those seven characters

;; ---- the reader, on both spellings ---------------------------------
(define (reads? text want)
  (guard (e (#t (fail! (string-append (wr text) " raised"))))
    (let ((v (rd text)))
      (cond ((not (symbol? v)) (fail! (string-append (wr text) " is not a symbol")))
            ((string=? (symbol->string v) want) #t)
            (else (fail! (string-append (wr text) " read as "
                                        (wr (symbol->string v)))))))))

(reads? "a\\x20;b" "a b")               ; inline, which is what we write
(reads? "\\x31;abc" "1abc")
(reads? "a\\x7C;b" "a|b")
(reads? "\\x2E;"   ".")
(reads? "|a b|"    "a b")               ; bars, which Chez writes for none but ||
(reads? "||"       "")
(reads? "|abc|"    "abc")
(reads? "abc"      "abc")               ; and a bare name is still bare

;; ---- the round trip, asked so that leftovers cannot pass ----------
;; Reading ONE datum back is not enough: `a b` gives the symbol `a`
;; first and leaves `b`, so a check that only looked at the first datum
;; would have called the old writer correct.  The second read has to
;; reach end of input, and the name has to match BYTE FOR BYTE -- this
;; runtime holds a symbol's name as UTF-8 bytes, so "a λ" is four
;; characters here and comparing prints would compare two printers.
(define (codes s) (map char->integer (string->list s)))
(define (same-codes? a b)
  (and (= (length a) (length b))
       (let loop ((a a) (b b))
         (or (null? a) (and (= (car a) (car b)) (loop (cdr a) (cdr b)))))))

(define (trips-exactly? name)
  (guard (e (#t (fail! (string-append "round trip raised for " (wr name)))))
    (let* ((text (wr (string->symbol name)))
           (port (open-input-string text))
           (first (read port))
           (second (read port)))
      (cond
       ((not (symbol? first))
        (fail! (string-append (wr name) " wrote " (wr text)
                              " which does not read back as a symbol")))
       ((not (same-codes? (codes (symbol->string first)) (codes name)))
        (fail! (string-append (wr name) " wrote " (wr text)
                              " which read back as "
                              (wr (symbol->string first)))))
       ((not (eof-object? second))
        (fail! (string-append (wr name) " wrote " (wr text)
                              " and left something after the symbol")))))))

;; and inside a list, where a leftover token changes the LENGTH -- the
;; failure the old writer actually produced
(define (trips-in-list? name)
  (guard (e (#t (fail! (string-append "list round trip raised for " (wr name)))))
    (let* ((text (string-append "(1 " (wr (string->symbol name)) " 3)"))
           (v (rd text)))
      (unless (and (list? v) (= 3 (length v))
                   (symbol? (cadr v))
                   (same-codes? (codes (symbol->string (cadr v))) (codes name)))
        (fail! (string-append (wr name) " inside a list read as " (wr text)
                              " -> wrong shape or wrong element"))))))

;; ---- the round trip, which is the property ------------------------
(define (trips? name)
  (guard (e (#t (fail! (string-append "round trip raised for " (wr name)))))
    (let ((back (rd (wr (string->symbol name)))))
      (unless (and (symbol? back) (string=? (symbol->string back) name))
        (fail! (string-append "round trip lost " (wr name)))))))
(define $names
  (list "abc" "a-b?!" "+" "-" "..." "->x" "λ" "a b" "" "a|b" "a\\b" "a\"b"
        "a(b" "a)b" "a;b" "a\tb" "a#b" "#ab" "1abc" "1" "1.5" "."
        "a\nb" "  " "|" "\\" "'" "-1" "+nan.0" "1e3" "#t"
        ;; escapes with nothing between them, and one at each end
        "\\\\" "||" " a" "a "
        ;; multi-byte names are built at RUNTIME, not written as source
        ;; literals -- see the note below the list
        ;; the arrow prefix, in every shape review turned up
        "->a b" "->|" "->#" "->\\x41;" "->" "->x"))
(for-each trips? $names)
(for-each trips-exactly? $names)
(for-each trips-in-list? $names)
;; ---- non-ASCII names -----------------------------------------------
;; ⚠ These names are built by reading a string at RUNTIME rather than
;; written as source literals, and the reason is a defect somewhere
;; else: the Chez-hosted compiler truncates a \xNN...; escape at or
;; above U+0080 in a SOURCE literal to a single byte -- "\x3bb;" in
;; source compiles to the one byte 187 on that host and to the two
;; bytes 206 187 on the self-hosted one.  Writing these names as source
;; literals would make the cells below test a different name on each
;; host, and pass, which is worse than not testing them.
;;
;; The runtime reader is correct on every host, so it is used as the
;; constructor here.  WHEN THAT DEFECT IS FIXED, these go back to
;; ordinary source literals -- they are written this way because of it,
;; not because runtime construction is better.
(define (name-of text) (rd text))       ; text -> the string it denotes
(define $lambda (name-of "\"\\x3bb;\""))          ; two UTF-8 bytes
(define $emoji  (name-of "\"\\x1f600;\""))        ; four UTF-8 bytes
(define $mixed  (name-of "\"a\\x3bb;b\""))
(define $spaced (name-of "\"a \\x3bb;\""))

(for-each (lambda (n) (trips? n) (trips-exactly? n) (trips-in-list? n))
          (list $lambda $emoji $mixed $spaced))

;; and the byte-level cell: the name must come back as the same bytes,
;; not as something a printer happens to render the same way
(let ((v (rd (wr (string->symbol $spaced)))))
  (unless (and (symbol? v)
               (same-codes? (codes (symbol->string v)) '(97 32 206 187)))
    (fail! "\"a lambda\" did not come back as the bytes 97 32 206 187")))
(let ((v (rd (wr (string->symbol $emoji)))))
  (unless (and (symbol? v)
               (same-codes? (codes (symbol->string v)) '(240 159 152 128)))
    (fail! "a four-byte name did not come back as 240 159 152 128")))

;; ---- negative controls: ordinary names must NOT be escaped ---------
;; A writer that escaped everything would satisfy every cell above.
(define (bare? name)
  (let ((got (wr (string->symbol name))))
    (when (or (string=? got (string-append "|" name "|"))
              (let scan ((i 0))
                (cond ((= i (string-length got)) #f)
                      ((char=? #\\ (string-ref got i)) #t)
                      (else (scan (+ i 1))))))
      (fail! (string-append "an ordinary name was escaped: " (wr name)
                            " -> " (wr got))))))
(for-each bare? '("abc" "a-b?!" "+" "-" "..." "λ" "x1" "set!" "<=>" "a.b"))

(display (if (= failures 0)
             "every symbol name survives being written and read back"
             "SEE FAILURES ABOVE"))
