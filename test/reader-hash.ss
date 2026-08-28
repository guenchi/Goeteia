;; expect: every # form is recognised or refused by name
;; The `#` dispatcher used to answer `(eof-object)` for every form it
;; did not implement.  That is not a weak error, it is the WRONG KIND
;; of value: end-of-input is a control signal, and a consumer's correct
;; reaction to it is to stop and consider the data complete.  So an
;; unimplemented syntax did not fail, it ENDED THE DATUM -- politely.
;;
;;   (read "(1 #b101 3)")  =>  (1 #<eof> 101 3)
;;
;; Three elements became four, with different contents, and nothing
;; anywhere said so.  That is the case these cells exist for; the rest
;; of the file is the negative controls that keep the fix from taking
;; the working branches down with it.
;;
;; The reader is exercised at RUNTIME here, through `read`, not by
;; putting the forms in this file's own source.  That is deliberate:
;; compiling a form runs the reader AND macro expansion AND name
;; resolution, so an unbound-variable error from the last stage reads
;; exactly like a refusal from the first.  Measured that way, every
;; form below looked like it was "loudly refused"; measured through
;; `read` alone, most of them were silently accepted as something else.
;; A probe for one component must not pass through two.
(import (rnrs))

(define failures 0)
(define (fail! what) (set! failures (+ failures 1)) (display "  FAIL: ")
                     (display what) (newline))
(define (rd s) (with-input-from-string s read))

(define (has-sub? hay needle)
  (let* ((h (string-length hay)) (n (string-length needle)))
    (let loop ((i 0))
      (cond ((< (- h i) n) #f)
            ((string=? (substring hay i (+ i n)) needle) #t)
            (else (loop (+ i 1)))))))

;; must raise, and the message must say WHY -- a bare "it threw" would
;; pass just as well if the reader started refusing everything
(define (refuses? src . needles)
  (guard (e ((error? e)
             (let ((m (condition-message e)))
               (let loop ((ns needles))
                 (cond ((null? ns) #t)
                       ((has-sub? m (car ns)) (loop (cdr ns)))
                       (else (fail! (string-append
                                     "refused " src " but the message did not "
                                     "mention \"" (car ns) "\": " m))
                             #f)))))
            (#t (fail! (string-append "refused " src " with a non-error object"))
                #f))
    (let ((v (rd src)))
      (fail! (string-append src " was accepted, not refused"))
      #f)))

(define (reads-as? src ok?)
  (guard (e (#t (fail! (string-append src " raised, but it is a working form"))
                #f))
    (or (ok? (rd src))
        (begin (fail! (string-append src " read as the wrong value")) #f))))

;; ---- the forms with no branch: every one used to answer eof-object --
(refuses? "#b101" "#")
(refuses? "#o17" "#")
(refuses? "#d15" "#")
(refuses? "#e1.5" "#")
(refuses? "#i3" "#")
;; `#` followed by real end of input.  This is the purest cell in the
;; file: before the fix its answer was an eof-object, which is EXACTLY
;; what a well-formed empty input returns, so the two were not merely
;; hard to tell apart -- they were the same value.
(refuses? "#" "#")
;; the structure-corruption judge: a bad form in the middle of a list
(refuses? "(1 #b101 3)" "#")

;; ---- #vu8(, which the writer emits and the reader had no branch for
;; The printer spells a bytevector "#vu8(...)"; with no entry here the
;; library could not read back its own output, and did not say so --
;; the eof-object came out instead.
(define (bv=? v lst)
  (and (bytevector? v)
       (= (bytevector-length v) (length lst))
       (let loop ((i 0) (l lst))
         (or (null? l)
             (and (= (bytevector-u8-ref v i) (car l))
                  (loop (+ i 1) (cdr l)))))))
(reads-as? "#vu8(1 2 255)" (lambda (v) (bv=? v '(1 2 255))))
(reads-as? "#vu8()" (lambda (v) (bv=? v '())))
(reads-as? "#vu8( 1  2 )" (lambda (v) (bv=? v '(1 2))))
;; Elements are checked here rather than left to bytevector-u8-set!,
;; because an out-of-range value would be truncated or wrapped, and a
;; wrapped byte is a wrong value that looks like a right one.
(refuses? "#vu8(256)" "0..255")
(refuses? "#vu8(-1)" "0..255")
(refuses? "#vu8(1.5)" "0..255")
(refuses? "#vu8(x)" "0..255")
(refuses? "#v(1)" "#v")                 ; #v not followed by u8(

;; ---- still unimplemented, and now refused by name rather than ended -
;; Neither is a shape the writer emits, so refusing them loudly has no
;; asymmetry to answer for; they land with their own change.
(refuses? "#| c |# 7" "#")              ; block comment
(refuses? "#;(x) 7" "#")                ; datum comment

;; ---- #x, which had a branch but no validation -----------------------
;; It read digits until a byte it did not recognise and then returned
;; what it had -- starting from 0.  So "#x" alone answered 0, which is
;; indistinguishable from "#x0", and the leftover bytes were re-read as
;; separate data.
(refuses? "#x" "at least one")
(refuses? "#xzz" "base-16 digit")
(refuses? "#x1g" "base-16 digit")
;; Both signs, not just the one that was reported: "#x-1f" happened to
;; be loud when compiled (the leftover became an unbound variable) and
;; "#x+1f" was never mentioned, which is how a sign gets half-fixed.
;; In THIS change both are refused; making them read as -31 and 31
;; belongs to the change that generalises the digit loop over a radix,
;; and that change gets its own cells.
(refuses? "#x-1f" "base-16 digit")
(refuses? "#x+1f" "base-16 digit")

;; ---- negative controls: one per branch that already worked ----------
;; The risk in this change is not the new error, it is the six working
;; branches sitting next to it in the same cond.
(reads-as? "#t" (lambda (v) (eq? v #t)))
(reads-as? "#f" (lambda (v) (eq? v #f)))
(reads-as? "#(1 2)" (lambda (v) (and (vector? v) (= 2 (vector-length v))
                                     (equal? 1 (vector-ref v 0)))))
(reads-as? "#'x" (lambda (v) (and (pair? v) (eq? 'syntax (car v)))))
(reads-as? "#\\a" (lambda (v) (eqv? v #\a)))
(reads-as? "#\\space" (lambda (v) (eqv? v #\space)))
(reads-as? "#x1f" (lambda (v) (eqv? v 31)))
(reads-as? "#x1F" (lambda (v) (eqv? v 31)))   ; upper-case digits
(reads-as? "#xFF" (lambda (v) (eqv? v 255)))
(reads-as? "#x0" (lambda (v) (eqv? v 0)))
;; and that a genuinely empty input still gives the eof-object, which is
;; the value the broken branch was borrowing
(reads-as? "" (lambda (v) (eof-object? v)))

(display (if (= failures 0)
             "every # form is recognised or refused by name"
             "SEE FAILURES ABOVE"))
