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

;; One thing: which of the objects an action could affect it has already
;; affected.
;;
;; A sword swing is sampled every frame for as long as the swing lasts,
;; a beam pulses while it is held, a piercing shot crosses several
;; bodies.  In each of those the same target must be affected ONCE, not
;; once per sample, and the thing that makes that true is a set with the
;; lifetime of the episode rather than of the frame.
;;
;; IDENTITY, NOT EQUALITY.  Two actors with identical contents are two
;; actors, so the test is eq? -- a reference comparison -- and not
;; equal?.  A caller that uses a number or a string as the identity is
;; relying on something no Scheme promises: two values that are `=' or
;; `string=?' need not be eq?.  Objects and symbols are what this is
;; for.
;;
;; A LIST, NOT A HASHTABLE, and the reason is in docs/limits.md: this
;; runtime exposes no identity for an object -- no address, no serial,
;; no object hash, no weak reference -- so an eq-hashtable keyed by an
;; actor degenerates to a linear scan carrying a hashtable's constant
;; factor on top.  memq over a list is the same complexity without the
;; pretence, and an action touches few things.
;;
;; once-first! EXISTS SO THE TWO-STEP CANNOT BE WRITTEN WRONG.  The
;; obvious interface is seen? followed by mark!, and the obvious defect
;; is a caller that asks and then forgets to record -- which is the very
;; failure this structure exists to prevent, reappearing one level up in
;; the caller.  Answering and recording in one call leaves nothing to
;; forget:
;;
;;     (when (once-first! hits target) (apply-damage! target))
;;
;; once-seen? remains for a caller that wants to look without taking the
;; turn: it is the one procedure that is ABOUT an object and does not
;; record it.  (once? and once-count do not record either; they are not
;; asked about an object at all.)
;;
;; WHY THIS IS NOT (gam window).  window-mark! is the same one-call
;; answer-and-record, down to the caller's idiom, and window-marked?,
;; window-marks and window-reset! complete the same ledger.  Two things
;; separate them, and neither is a matter of taste.
;;
;;   window-marked? compares with equal?.  For a ledger of TARGETS that
;;   is not a near miss, it is the wrong test: two actors carrying the
;;   same numbers are two actors, and under equal? the second one is
;;   silently refused its turn because the first one looked like it.
;;
;;   A window is a span of time -- it has a duration, a step!, and
;;   live?/done?/span.  A piercing shot that crosses three bodies in a
;;   single frame has no clock to attach a ledger to, and would have to
;;   invent a duration to get one.
;;
;; quest-record! in (gam quest) has the shape too, and is further away
;; still: it filters against objectives declared when the quest was
;; made, and refuses anything that is not a symbol, character, boolean
;; or fixnum.
(library (gam once)
  (export make-once once? once-first! once-seen? once-reset! once-count)
  (import (rnrs))

  ;; The tag is a fresh pair rather than a symbol.  The other libraries
  ;; here tag with a symbol, which a caller can WRITE DOWN:
  ;; (vector 'gam-inventory '()) passes their type test.  A pair made at
  ;; load time cannot be written as a literal, so a forgery has to be
  ;; built from a real set.
  ;;
  ;; It is not out of reach, and saying so would be false: make-once
  ;; puts the tag in slot 0 of every set it hands out, so a caller
  ;; holding one can read it and build (vector that-tag '()), which
  ;; once? accepts.  The check is against a caller writing the shape by
  ;; hand, not against one that sets out to defeat it.
  (define $once-tag (list 'gam-once))

  ;; #(tag seen); seen is the objects taken so far, most recent first.
  (define ($once? s)
    (and (vector? s) (= (vector-length s) 2)
         (eq? (vector-ref s 0) $once-tag)))
  (define ($seen s) (vector-ref s 1))
  (define ($seen! s v) (vector-set! s 1 v))

  (define ($need-once who s)
    (unless ($once? s) (error who "not a once set" s)))

  (define (make-once) (vector $once-tag '()))

  ;; Answers rather than raising, so a caller can test a value it is not
  ;; sure about; every other procedure here raises, because by then the
  ;; caller has said it has one.
  (define (once? s) ($once? s))

  ;; #t exactly once per object, and the recording happens in the same
  ;; call that answers.  A second ask about the same object answers #f
  ;; and adds nothing -- the count is what proves the second ask did not
  ;; quietly record a duplicate.
  (define (once-first! s x)
    ($need-once 'once-first! s)
    (and (not (memq x ($seen s)))
         (begin ($seen! s (cons x ($seen s))) #t)))

  ;; Looks without taking the turn.
  (define (once-seen? s x)
    ($need-once 'once-seen? s)
    (and (memq x ($seen s)) #t))

  ;; The next pulse of the same beam, or the next swing.  The set is
  ;; reused rather than remade so that a caller holding it across frames
  ;; keeps holding the same one.
  (define (once-reset! s)
    ($need-once 'once-reset! s)
    ($seen! s '()))

  (define (once-count s)
    ($need-once 'once-count s)
    (length ($seen s))))
