;; expect: #t
;; (web fs): whole files in and out of staging memory.
;;
;; Every round trip here writes a file this test made and reads it
;; back, so the suite needs no fixture and no machine-local asset --
;; the oracle is the bytes that went in.  The interesting cases are
;; the boundaries, and each is asserted as a NAMED failure rather
;; than "it raised something":
;;
;;   * the byte just past the end of the read is poisoned before the
;;     slurp and checked after it, so a read that returned one byte
;;     too many (or wrote one) is caught even though the count would
;;     still look plausible;
;;   * a file bigger than the capacity the caller gave is refused by
;;     name instead of scribbling into whatever fx-alloc! handed out
;;     next;
;;   * an absent path is #f from fs-exists? and a named error from
;;     the readers -- the two answers a host with no filesystem must
;;     also give, which is the whole point of naming them.
;;
;; The empty file is here because it is the one length at which
;; "loop until EOF" and "loop len times" can disagree without any
;; content to show it.
(import (rnrs) (web fs) (gfx fx))

(define BIN "/tmp/goeteia-web-fs.bin")
(define TXT "/tmp/goeteia-web-fs.txt")
(define NIL "/tmp/goeteia-web-fs-empty.bin")
(define GONE "/tmp/goeteia-web-fs-no-such-file-here.bin")

(define N 1000)
(define POISON 173)

(define fails '())
(define (chk name ok)
  (unless ok
    (display "  FAIL ") (display name) (newline)
    (set! fails (cons name fails)))
  ok)

;; -> the who symbol of whatever the thunk raised, or #f if it
;; returned.  A test that only asked "did it raise" would pass on a
;; trap from a completely different place.
(define (raised-who thunk)
  (guard (e ((error? e) (condition-who e))
            (#t 'non-condition))
    (thunk)
    #f))

(define SRC (fx-alloc! N))
(define DST (fx-alloc! (+ N 16)))

(define (fill! base n)
  (let loop ((i 0))
    (when (< i n)
      (%mem-u8-set! (+ base i) (remainder (* (+ i 1) 37) 251))
      (loop (+ i 1)))))

(define (poison! base n)
  (let loop ((i 0))
    (when (< i n)
      (%mem-u8-set! (+ base i) POISON)
      (loop (+ i 1)))))

(define (same? a b n)
  (let loop ((i 0))
    (cond ((= i n) #t)
          ((= (%mem-u8-ref (+ a i)) (%mem-u8-ref (+ b i))) (loop (+ i 1)))
          (else (display "    first difference at byte ") (display i)
                (newline) #f))))

;; ---- a real round trip ----
(fill! SRC N)
(poison! DST (+ N 16))

(define wrote (fs-spit! BIN SRC N))
(define read-back (fs-slurp! BIN DST (+ N 16)))

(define roundtrip-ok
  (and
   (chk "fs-spit! answers the count it wrote" (= wrote N))
   (chk "fs-slurp! answers the same count" (= read-back N))
   (chk "every byte survived" (same? SRC DST N))
   ;; the off-by-one gate: nothing past the file's length was touched
   (chk "the byte after the file is untouched"
        (= (%mem-u8-ref (+ DST N)) POISON))
   (chk "the last byte of the file is the last byte written"
        (= (%mem-u8-ref (+ DST (- N 1))) (%mem-u8-ref (+ SRC (- N 1)))))
   (chk "fs-size agrees with the count" (= (fs-size BIN) N))
   (chk "fs-exists? sees the file it wrote" (fs-exists? BIN))))

;; ---- the empty file ----
(define empty-ok
  (and
   (chk "an empty write answers 0" (= (fs-spit! NIL SRC 0) 0))
   (chk "an empty file exists" (fs-exists? NIL))
   (chk "an empty file is 0 bytes" (= (fs-size NIL) 0))
   (chk "an empty read answers 0"
        (begin (poison! DST 4)
               (and (= (fs-slurp! NIL DST 16) 0)
                    (= (%mem-u8-ref DST) POISON))))))

;; ---- strings ----
;; the text is deliberately not all ASCII: a Goeteia string holds one
;; character per UTF-8 byte, and a codec that "helpfully" decoded
;; would come back a different length
(define TEXT "hello (web fs) -- é中文 -- done\n")

(define string-ok
  (let ((n (fs-spit-string! TXT TEXT)))
    (and
     (chk "fs-spit-string! answers the byte count"
          (= n (string-length TEXT)))
     (chk "the file is that many bytes" (= (fs-size TXT) n))
     (chk "the text comes back unchanged"
          (string=? (fs-slurp-string TXT) TEXT))
     (chk "a string round trip is not shortened by a wide character"
          (> n 24)))))

;; ---- the absent path ----
(define absent-ok
  (and
   (chk "fs-exists? answers #f and does not raise"
        (eq? (fs-exists? GONE) #f))
   (chk "fs-slurp! names itself on an absent path"
        (eq? (raised-who (lambda () (fs-slurp! GONE DST 16))) 'fs-slurp!))
   (chk "fs-size names itself on an absent path"
        (eq? (raised-who (lambda () (fs-size GONE))) 'fs-size))
   (chk "fs-slurp-string names itself on an absent path"
        (eq? (raised-who (lambda () (fs-slurp-string GONE)))
             'fs-slurp-string))))

;; ---- the boundaries ----
(define bounds-ok
  (and
   (chk "a file bigger than the capacity is refused by name"
        (eq? (raised-who (lambda () (fs-slurp! BIN DST (- N 1))))
             'fs-slurp!))
   (chk "a capacity of exactly the file's size is accepted"
        (= (fs-slurp! BIN DST N) N))
   (chk "a negative length is refused by name"
        (eq? (raised-who (lambda () (fs-spit! BIN SRC -1))) 'fs-spit!))
   (chk "a negative address is refused by name"
        (eq? (raised-who (lambda () (fs-slurp! BIN -1 16))) 'fs-slurp!))
   (chk "a write range past the staging memory is refused by name"
        (eq? (raised-who
              (lambda () (fs-spit! BIN SRC (* 65536 (+ (%mem-size) 1)))))
             'fs-spit!))
   (chk "a path that is not a string is refused by name"
        (eq? (raised-who (lambda () (fs-exists? 7))) 'fs-exists?))))

;; the refused slurp above stopped mid-file, so the destination is
;; whatever it managed; re-read it clean and check the bytes once
;; more, to be sure the refusal did not leave the library confused
;; about its own descriptor
(define after-refusal-ok
  (begin
    (poison! DST (+ N 16))
    (and
     (chk "reading again after a refusal still works"
          (= (fs-slurp! BIN DST (+ N 16)) N))
     (chk "and gives the same bytes" (same? SRC DST N)))))

(and roundtrip-ok empty-ok string-ok absent-ok bounds-ok after-refusal-ok
     (null? fails))
