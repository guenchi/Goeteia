;; Copyright 2026 guenchi
;;
;; Licensed under the Apache License, Version 2.0 (the "License");
;; you may not use this file except in compliance with the License.
;; You may obtain a copy of the License at
;;
;;     http://www.apache.org/licenses/LICENSE-2.0
;;
;; Unless required by applicable law or agreed to in writing, software
;; distributed under the License is distributed on an "AS IS" BASIS,
;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;; See the License for the specific language governing permissions and
;; limitations under the License.

;; Something was taken; a claim on getting part of it back exists until
;; it is used once.
;;
;; A recovery holds one number -- how much is at stake -- and whether
;; the claim on it is still open.  Recording a loss opens a claim for
;; that amount.  Claiming answers a fraction of it and closes the claim
;; for good, whether or not the caller asked for all of it.
;;
;; IT DOES NOT TAKE THE AMOUNT FROM ANYTHING, AND IT DOES NOT GIVE IT
;; BACK.  Both are the caller's, and this only keeps the books between
;; them.  The obvious alternative -- hand it the thing the amount lives
;; in, and let it subtract and add -- was the shape this started from,
;; and it ties two independent parts together permanently: the claim
;; could then only ever be against that one kind of store, in that one
;; currency, and a design that wants a claim against two things at once,
;; or against something that is not a pool of points at all, stops
;; fitting.  Worse, it puts the arithmetic of somebody else's store in
;; here, where the rules that store enforces -- a floor, a cap, what
;; happens at zero -- are neither known nor checkable.  Keeping them
;; apart costs the caller the one line that does the subtraction and
;; makes this correct against every store instead of one.
;;
;; SO THE CALLER CLAMPS, NOT THIS.  Record what was ACTUALLY taken.  A
;; store that had 30 points when 50 were demanded lost 30, and if 50 is
;; recorded here the claim is for points that were never there and the
;; caller will hand back more than it took.  This cannot detect that:
;; the only place both numbers are known is the call site.
;;
;; A SECOND LOSS REPLACES THE FIRST.  There is one claim, not a queue of
;; them, so recording a loss while a claim is still open abandons it --
;; the earlier amount is gone and unrecoverable.  This is a rule worth
;; reading twice because it is the one that silently destroys value:
;; a caller that wants the earlier claim kept must read recovery-open?
;; and decide before recording, and a caller that wants several at once
;; wants several of these, one per thing being claimed.
;;
;; CLAIMING CONSUMES THE CLAIM EVEN FOR NOTHING.  A claim of a zero
;; fraction answers zero and closes the claim, because the operation is
;; "settle this claim now, at these terms" and not "collect what is
;; available".  A caller deciding whether it can afford to settle asks
;; recovery-pending first, which changes nothing.
;;
;; IT DOES NOT ROUND.  The amount comes back as the fraction of what was
;; recorded, exactly as the arithmetic gives it.  Rounding it would be a
;; statement about what the number counts -- whole points round, a
;; distance or a duration does not -- and that is the same question this
;; library already refused to answer when it declined to know what the
;; amount is.  A caller counting whole units floors what it gets back.
(library (gam recovery)
  (export make-recovery recovery? recovery-open? recovery-pending
          recovery-loss! recovery-claim!)
  (import (rnrs))

  ;; #(gam-recovery amount open?)
  (define ($r? r)
    (and (vector? r) (= (vector-length r) 3)
         (eq? (vector-ref r 0) 'gam-recovery)))
  (define ($need-r who r)
    (unless ($r? r) (error who "not a recovery" r)))
  (define ($amount r) (vector-ref r 1))
  (define ($amount! r v) (vector-set! r 1 v))
  (define ($open? r) (vector-ref r 2))
  (define ($open! r v) (vector-set! r 2 v))

  (define (recovery? r) ($r? r))

  ;; Starts closed: nothing has been lost, so there is nothing to claim.
  (define (make-recovery) (vector 'gam-recovery 0 #f))

  ;; Whether a claim is outstanding.  This is not the same question as
  ;; whether recovery-pending is zero, and the difference matters: a
  ;; claim for zero is open and will be consumed by a claim, while no
  ;; claim at all cannot be consumed by anything.  A caller that tests
  ;; the number instead of this one treats those two as the same and is
  ;; right until the first loss that took nothing.
  (define (recovery-open? r) ($need-r 'recovery-open? r) ($open? r))

  ;; Zero when no claim is open, so a caller that only wants to know
  ;; what is on the table can ask one question.
  (define (recovery-pending r)
    ($need-r 'recovery-pending r)
    (if ($open? r) ($amount r) 0))

  ;; Answers the amount recorded, so the call reads as the record it is
  ;; and the caller can log or display it without asking again.
  (define (recovery-loss! r amount)
    ($need-r 'recovery-loss! r)
    (unless (and (real? amount) (not (< amount 0)))
      (error 'recovery-loss! "a loss is a non-negative real" amount))
    ($amount! r amount)
    ($open! r #t)
    amount)

  ;; A fraction outside 0 to 1 is refused rather than clamped: above one
  ;; asks to get back more than was lost, and below zero asks for the
  ;; claim to take something further, and neither is a thing this can do
  ;; approximately.  Claiming with no claim open answers zero and
  ;; changes nothing, which is the honest answer to "settle up" when
  ;; there is nothing outstanding.
  (define (recovery-claim! r fraction)
    ($need-r 'recovery-claim! r)
    (unless (and (real? fraction) (not (< fraction 0)) (not (< 1 fraction)))
      (error 'recovery-claim! "a fraction is a real from 0 to 1" fraction))
    (let ((owed (* fraction (recovery-pending r))))
      ($open! r #f)
      ($amount! r 0)
      owed)))
