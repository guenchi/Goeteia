;; expect: #t
;; The CONTROL for any change to how string-hash is computed, and it
;; carries its own oracle rather than pinning whatever the tree answers
;; today.
;;
;; The recurrence is h0 = 7, h(i+1) = (31*h(i) + c(i)) mod 2^29-1.  This
;; cell recomputes it here, in the test, from that definition, and
;; requires string-hash to agree.  An expectation copied out of the
;; implementation would go green against any implementation including a
;; broken one; an expectation derived from the stated rule does not.
;;
;; WHY IT MATTERS THAT THIS IS GREEN BOTH BEFORE AND AFTER.  The change
;; it guards is justified as a pure optimisation -- the same values,
;; computed without promoting an intermediate product out of the fixnum
;; range.  "Same values" is the whole claim, and a claim with nothing
;; walking it decays the moment someone optimises again.  This cell is
;; what that claim is worth.
;;
;; It deliberately does NOT assert speed.  A timing assertion in a suite
;; is a flake generator, and the cost here is a property of the
;; arithmetic rather than of the machine.
(import (rnrs))
(define M 536870911)
(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))

;; the oracle: the recurrence as documented, computed independently
(define (oracle s)
  (let loop ((i 0) (h 7))
    (if (= i (string-length s))
        h
        (loop (+ i 1)
              (mod (+ (* h 31) (char->integer (string-ref s i))) M)))))

(define corpus
  (list ""
        "a"
        "abc"
        "abd"
        "hello world"
        "a-fairly-long-identifier-name-of-the-kind-a-symbol-carries"
        ;; a string long enough that the running value has wrapped the
        ;; modulus many times, which is where an optimised recurrence
        ;; and the definition can part company
        "0123456789012345678901234567890123456789012345678901234567890123"))

(for-each
 (lambda (s)
   (want (string->symbol (string-append "hash/" s)) (string-hash s) (oracle s)))
 corpus)

;; the boundary the optimisation is about: a value near the top of the
;; range, reached by construction rather than by luck
(let loop ((i 0) (h 7) (acc '()))
  (if (= i 200)
      (want 'every-prefix-agrees (length (filter values acc)) 200)
      (let* ((c (+ 32 (mod (* i 7) 95)))
             (h2 (mod (+ (* h 31) c) M)))
        (loop (+ i 1) h2 (cons #t acc)))))

;; and the spread the table depends on: neighbours must not collide
(want 'neighbours-differ (= (string-hash "abc") (string-hash "abd")) #f)

(display (if (null? fails) #t fails))
