;; expect: js->number converts exactly the fixnums and no others
;; A number crossing from JS becomes a fixnum when it fits in one and
;; stays a flonum otherwise.  The range is CLOSED -- a fixnum here is
;; -536870912 .. 536870911 inclusive, one tag bit short of 31 -- and
;; the test was written with two strict comparisons, so both endpoints
;; fell out of it and arrived as flonums.  Nothing downstream refuses a
;; flonum, so the wrong representation just travels.
;;
;; Every value here is fed through js-eval, so it arrives the way a
;; real JS number does.  Writing the literal in Scheme and asking
;; `fixnum?` would test the Scheme reader, not the conversion.
;;
;; Each cell asserts the REPRESENTATION and the VALUE.  A conversion
;; that answered a fixnum 0 for everything would satisfy `fixnum?`
;; alone, and one that truncated to 32 bits would satisfy the value
;; check on small numbers only.
(import (rnrs) (web js))

(define failures 0)
(define (fail! what) (set! failures (+ failures 1))
  (display "  FAIL: ") (display what) (newline))

(define (from-js text) (js->number (js-eval text)))

(define (fixnum-is? text want)
  (let ((v (from-js text)))
    (cond ((not (fixnum? v))
           (fail! (string-append text " came back as a flonum, not a fixnum")))
          ((not (= v want))
           (fail! (string-append text " came back with the wrong value"))))))

(define (flonum-is? text want)
  (let ((v (from-js text)))
    (cond ((not (flonum? v))
           (fail! (string-append text " came back as a fixnum, not a flonum")))
          ((not (fl=? v want))
           (fail! (string-append text " came back with the wrong value"))))))

;; ---- the four transition points ------------------------------------
;; 2^29 is the boundary; the fixnum range is asymmetric because one
;; value is spent on the tag, so the negative end reaches one further.
(fixnum-is? "536870911"  536870911)     ; the largest fixnum
(flonum-is? "536870912"  536870912.0)   ; one past it
(fixnum-is? "-536870912" -536870912)    ; the smallest fixnum
(flonum-is? "-536870913" -536870913.0)  ; one past that

;; ---- values with a fraction are never fixnums ----------------------
;; A conversion that rounded instead of refusing would pass the four
;; cells above and lose the fraction here.
(flonum-is? "536870911.5"  536870911.5)
(flonum-is? "-536870911.5" -536870911.5)
(flonum-is? "0.5" 0.5)
(flonum-is? "-0.5" -0.5)

;; ---- and integers far outside, where a 32-bit path would show ------
(flonum-is? "2147483648"       2147483648.0)      ; 2^31
(flonum-is? "-2147483649"      -2147483649.0)
(flonum-is? "9007199254740992" 9007199254740992.0) ; 2^53

;; ---- the ordinary middle, which must not regress -------------------
(fixnum-is? "0" 0)
(fixnum-is? "1" 1)
(fixnum-is? "-1" -1)
(fixnum-is? "42" 42)

(display (if (= failures 0)
             "js->number converts exactly the fixnums and no others"
             "SEE FAILURES ABOVE"))
