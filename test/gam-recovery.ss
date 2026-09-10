;; expect: #t
;; What this cell is the only evidence for: (gam recovery) keeps ONE
;; claim, and both of the ways that claim ends are ways value
;; disappears -- a second loss abandons the first, and a claim settled
;; for nothing is still settled.
;;
;; Neither is a bug and both are in the file header in capitals, which
;; is exactly why they need cells: a rule that destroys value silently
;; and on purpose is one a later reader will helpfully "fix".
;;
;; It does not take the amount from anything and does not give it back.
;; So every number below is bookkeeping, and the caller's store is
;; nowhere in this file -- which is the design, not an omission in the
;; cell.
(import (rnrs) (gam recovery))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))
(define (raises? thunk)
  (guard (e ((error? e) #t) (else #f)) (begin (thunk) #f)))

;; A new recovery owes nothing and has nothing open.
(let ((r (make-recovery)))
  (want 'a-new-recovery-has-no-claim (recovery-open? r) #f)
  (want 'and-nothing-pending (recovery-pending r) 0)
  (want 'and-it-is-one (recovery? r) #t))

;; Recording a loss opens a claim for that amount, and answers it.
(let ((r (make-recovery)))
  (want 'recording-answers-the-amount (recovery-loss! r 40) 40)
  (want 'the-claim-is-open (recovery-open? r) #t)
  (want 'and-pending-is-what-was-lost (recovery-pending r) 40))

;; Claiming answers the fraction and closes the claim for good.
(let ((r (make-recovery)))
  (recovery-loss! r 40)
  (want 'claiming-answers-the-fraction (recovery-claim! r 1/2) 20)
  (want 'and-closes-the-claim (recovery-open? r) #f)
  (want 'and-nothing-is-pending (recovery-pending r) 0)
  (want 'a-second-claim-answers-nothing (recovery-claim! r 1) 0))

;; A SECOND LOSS REPLACES THE FIRST.  This is the rule that silently
;; destroys value: the earlier amount is gone and unrecoverable, and
;; nothing anywhere reports that it happened.
(let ((r (make-recovery)))
  (recovery-loss! r 40)
  (recovery-loss! r 5)
  (want 'the-second-loss-replaced-the-first (recovery-pending r) 5)
  (want 'not-added-to-it (recovery-claim! r 1) 5))

;; The caller's escape from that rule is to ask first, so the question
;; has to be answerable before the damage.
(let ((r (make-recovery)))
  (recovery-loss! r 40)
  (want 'a-caller-can-see-the-claim-before-overwriting-it
        (list (recovery-open? r) (recovery-pending r)) '(#t 40)))

;; CLAIMING CONSUMES THE CLAIM EVEN FOR NOTHING.  Settling at a zero
;; fraction is "settle now, at these terms" and not "collect what is
;; available", so the whole claim goes.
(let ((r (make-recovery)))
  (recovery-loss! r 40)
  (want 'a-zero-claim-answers-zero (recovery-claim! r 0) 0)
  (want 'and-still-closes-the-claim (recovery-open? r) #f)
  (want 'the-forty-is-gone (recovery-pending r) 0))

;; Which makes recovery-pending the read that changes nothing, and the
;; one a caller deciding whether to settle must use.
(let ((r (make-recovery)))
  (recovery-loss! r 40)
  (recovery-pending r)
  (recovery-pending r)
  (want 'asking-does-not-consume (recovery-open? r) #t)
  (want 'and-the-amount-is-still-there (recovery-claim! r 1) 40))

;; Claiming with nothing open answers zero and changes nothing, which
;; is the honest answer to "settle up" when there is nothing
;; outstanding.
(let ((r (make-recovery)))
  (want 'settling-nothing-answers-zero (recovery-claim! r 1) 0)
  (want 'and-opens-nothing (recovery-open? r) #f))

;; A loss of zero is a real loss to record -- something took nothing,
;; and the claim is open for nothing -- so open? and a pending of zero
;; are two different questions.
(let ((r (make-recovery)))
  (recovery-loss! r 0)
  (want 'a-zero-loss-still-opens-a-claim (recovery-open? r) #t)
  (want 'with-nothing-pending (recovery-pending r) 0)
  (want 'and-settling-it-answers-nothing (recovery-claim! r 1) 0)
  (want 'and-closes-it (recovery-open? r) #f))

;; It does not round: the amount is the fraction of what was recorded,
;; exactly as the arithmetic gives it.
(let ((r (make-recovery)))
  (recovery-loss! r 7)
  (want 'a-third-of-seven-is-a-third-of-seven (recovery-claim! r 1/3) 7/3))

;; Refusals.  A fraction outside zero to one asks for something this
;; cannot do approximately: above one is more than was lost, below zero
;; asks the claim to take something further.
(want 'a-negative-loss-refused
      (raises? (lambda () (recovery-loss! (make-recovery) -1))) #t)
(want 'a-non-real-loss-refused
      (raises? (lambda () (recovery-loss! (make-recovery) 'lots))) #t)
(let ((r (make-recovery)))
  (recovery-loss! r 40)
  (want 'a-fraction-above-one-refused (raises? (lambda () (recovery-claim! r 2))) #t)
  (want 'a-negative-fraction-refused (raises? (lambda () (recovery-claim! r -1/2))) #t)
  (want 'and-a-refused-claim-left-it-open (recovery-open? r) #t)
  (want 'with-the-amount-intact (recovery-pending r) 40))
(want 'not-a-recovery-refused
      (raises? (lambda () (recovery-pending (vector 'gam-recovery)))) #t)

(display (if (null? fails) #t (reverse fails)))
