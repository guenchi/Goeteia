;; expect: the reader agrees with the reference face on every row
;; Every number spelling in test/number-face.tsv, read through this
;; reader and compared with what Chez answers.  The fixture is a CROSS
;; PRODUCT of radix prefixes, exactness prefixes, signs and bodies, so
;; the denominator of this check is counted rather than remembered --
;; the hand-written list it replaced was missing hex fractions whose
;; exponent marker is a digit, exactness applied over an exponent, and
;; every sign pile-up.
;;
;; The comparison is on VALUES, never on printed text: a flonum by its
;; eight bytes, an exact number by its exact numeral, a symbol by name.
;; An earlier version of this comparison used `display` and reported
;; +inf.0 as a disagreement -- the value was right and only the
;; spelling differed, because this printer writes an infinity as
;; "<big-flonum>" by a recorded decision.  The judge was wrong, not the
;; two rows; the fix was to change the judge rather than to exempt them.
(import (rnrs) (web fs) (gfx fx) (notrun))

(define FIXTURE "test/number-face.tsv")

(define $hex "0123456789abcdef")
(define $bb (fx-alloc! 16))
(define (bits x)
  (%mem-f64-set! $bb x)
  (let loop ((i 7) (acc ""))
    (if (< i 0) acc
        (loop (- i 1)
              (let ((b (%mem-u8-ref (+ $bb i))))
                (string-append acc (string (string-ref $hex (quotient b 16))
                                           (string-ref $hex (remainder b 16)))))))))

(define (classify v)
  (cond ((eof-object? v) "EOF")
        ((symbol? v) (string-append "sym:" (symbol->string v)))
        ((flonum? v) (string-append "f64:" (bits v)))
        ((number? v) (string-append "exact:" (number->string v)))
        (else "other")))

(define (read-one s)
  (guard (e (#t "REFUSED"))
    (classify (with-input-from-string s read))))

;; split on a byte, keeping empty pieces: the fixture's own separator
(define (split s ch)
  (let ((n (string-length s)))
    (let loop ((i 0) (start 0) (acc '()))
      (cond
       ((= i n) (reverse (cons (substring s start i) acc)))
       ((char=? (string-ref s i) ch)
        (loop (+ i 1) (+ i 1) (cons (substring s start i) acc)))
       (else (loop (+ i 1) start acc))))))

(define declared -1)                    ; the row count the fixture states
(define checked 0)
(define failures 0)
(define shown 0)

(define (declared-count! line)
  ;; ";; rows: N", written by the generator alongside the rows
  (let ((tag ";; rows: "))
    (when (and (< (string-length tag) (string-length line))
               (string=? tag (substring line 0 (string-length tag))))
      (set! declared
            (string->number (substring line (string-length tag)
                                       (string-length line)))))))

(define (check-row line)
  (declared-count! line)
  (unless (or (string=? line "")
              (and (< 1 (string-length line))
                   (char=? #\; (string-ref line 0))))
    (let ((parts (split line #\tab)))
      (when (= 2 (length parts))
        (let* ((src (car parts)) (want (cadr parts)) (got (read-one src)))
          (set! checked (+ checked 1))
          (unless (string=? got want)
            (set! failures (+ failures 1))
            (when (< shown 12)
              (set! shown (+ shown 1))
              (display "  FAIL ") (display src)
              (display ": want ") (display want)
              (display " got ") (display got) (newline))))))))

(if (not (fs-exists? FIXTURE))
    (not-exercised! "the reference fixture is not on disk; it is generated
from Chez by test/gen-number-face.sc and tracked in the repository"
                    FIXTURE)
    (for-each check-row (split (fs-slurp-string FIXTURE) #\newline)))

;; The count travels with the verdict.  "The reader agrees" over zero
;; rows reads exactly like agreement over four thousand, and a fixture
;; that failed to load would produce the first while looking like the
;; second.
(display (cond ((not (fs-exists? FIXTURE)) "fixture absent, nothing compared")
               ((= checked 0) "FIXTURE LOADED BUT NO ROWS PARSED")
               ;; The fixture states how many rows it has; a truncated
               ;; file would otherwise pass with "every row" meaning a
               ;; handful.  The count is not cached here -- it is read
               ;; from the same file it describes.
               ((not (= checked declared)) "FIXTURE ROW COUNT DOES NOT MATCH")
               ((= failures 0)
                "the reader agrees with the reference face on every row")
               (else "SEE FAILURES ABOVE")))
