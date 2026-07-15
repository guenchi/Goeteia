;; Build-time Scheme syntax highlighting: the token classes the live
;; editor's highlighter (index.js) paints, computed while the page is
;; BUILT -- so the code samples in site sources are plain text, and
;; the spans are derived, never hand-written.
(library (hl)
  (export highlight)
  (import (rnrs))

  (define $keywords
    '(define define-syntax define-record-type define-values
      define-component lambda let let* letrec letrec* let-values
      if cond case when unless and or not begin do else
      quote quasiquote unquote set! import library export
      syntax-rules syntax-case with-syntax
      call/cc call-with-current-continuation dynamic-wind guard raise
      values sx sx-mount sx-list
      signal signal-ref signal-set! signal-update!
      effect batch untracked root))

  (define (esc s)
    (let loop ((i 0) (acc '()))
      (if (= i (string-length s))
          (apply string-append (reverse acc))
          (loop (+ i 1)
                (cons (let ((c (string-ref s i)))
                        (case c
                          ((#\&) "&amp;")
                          ((#\<) "&lt;")
                          ((#\>) "&gt;")
                          (else (string c))))
                      acc)))))

  (define (span cls s)
    (string-append "<span class=\"" cls "\">" (esc s) "</span>"))

  (define (delim? c)
    (or (char-whitespace? c)
        (memv c '(#\( #\) #\" #\;))))

  ;; the same shapes index.js tokenizes: comments, strings, #-literals,
  ;; parens (an open paren arms the head flag), and atoms -- keyword /
  ;; number / form head / plain.  Whitespace passes through and keeps
  ;; the head flag alive, so the first atom after ( heads its form
  ;; even across a line break.
  (define (highlight code)
    (let ((n (string-length code)))
      (let loop ((i 0) (head #f) (acc '()))
        (define (emit j chunk head*)
          (loop j head* (cons chunk acc)))
        (if (>= i n)
            (apply string-append (reverse acc))
            (let ((c (string-ref code i)))
              (cond
               ((char=? c #\;)          ; comment, to end of line
                (let eat ((j i))
                  (if (or (= j n) (char=? (string-ref code j) #\newline))
                      (emit j (span "tok-c" (substring code i j)) head)
                      (eat (+ j 1)))))
               ((char=? c #\")          ; string, backslash-aware
                (let eat ((j (+ i 1)))
                  (cond
                   ((>= j n) (emit n (span "tok-s" (substring code i n)) #f))
                   ((char=? (string-ref code j) #\\) (eat (+ j 2)))
                   ((char=? (string-ref code j) #\")
                    (emit (+ j 1) (span "tok-s" (substring code i (+ j 1))) #f))
                   (else (eat (+ j 1))))))
               ((and (char=? c #\#) (< (+ i 1) n)
                     (char=? (string-ref code (+ i 1)) #\\))
                (let ((j (min n (+ i 3))))    ; #\x character literal
                  (emit j (span "tok-l" (substring code i j)) #f)))
               ((and (char=? c #\#) (< (+ i 1) n)
                     (memv (string-ref code (+ i 1)) '(#\t #\f))
                     (or (>= (+ i 2) n) (delim? (string-ref code (+ i 2)))))
                (emit (+ i 2) (span "tok-l" (substring code i (+ i 2))) #f))
               ((memv c '(#\( #\)))
                (emit (+ i 1) (span "tok-p" (string c)) (char=? c #\()))
               ((char-whitespace? c)    ; runs pass through, head survives
                (let eat ((j i))
                  (if (or (= j n) (not (char-whitespace? (string-ref code j))))
                      (emit j (substring code i j) head)
                      (eat (+ j 1)))))
               (else                    ; an atom
                (let eat ((j i))
                  (if (or (= j n) (delim? (string-ref code j)))
                      (let* ((s (substring code i j))
                             (c0 (string-ref s 0))
                             (num? (or (char-numeric? c0)
                                       (and (memv c0 '(#\+ #\-))
                                            (> (string-length s) 1)
                                            (char-numeric? (string-ref s 1))))))
                        (emit j
                              (cond
                               ((memq (string->symbol s) $keywords)
                                (span "tok-k" s))
                               (num? (span "tok-n" s))
                               (head (span "tok-h" s))
                               (else (esc s)))
                              #f))
                      (eat (+ j 1))))))))))))
