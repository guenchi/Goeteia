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

;; The parts of mixing that are arithmetic, kept where nothing can
;; reach a browser.
;;
;; (aud sfx) has to talk to Web Audio, so anything living there can
;; only be tested through a fake context.  These two decide things a
;; graph cannot be asked about -- what the pan gains ARE, and which
;; voice should go -- and they decide them with no host at all.  A
;; browser can be made to show that two numbers arrived at two gain
;; nodes; it cannot show that those two numbers are the equal-power
;; law, and a machine with no browser cannot show even the first.
;;
;; So they live here, and the split is the point rather than the
;; tidiness: putting them in (aud sfx) would hand the separation back
;; at the import line -- their tests would drag in (web js) to check
;; code that touches no JS at all.  Here they need no fixture.
;;
(library (aud mix)
  (export pan-gains voice-evict voice-weakest)
  (import (rnrs))

  ;; $sin-fl / $cos-fl come from the prelude rather than from
  ;; (gfx mat)'s flsin/flcos: an audio library has no business
  ;; importing the graphics stack for two trigonometric calls.

  ;; Equal power: the two gains for a pan in [-1,1], as (left . right).
  ;;
  ;; The law is ours on purpose.  Web Audio's StereoPannerNode has a
  ;; specified law of its own -- it is not of unknown provenance -- but
  ;; using it would put the definition in the browser while we still
  ;; needed one here for documentation and for the offline criteria.
  ;; One fact, two definitions, free to disagree with nothing to report
  ;; it.  So we own it, and the browser is handed the results.
  ;;
  ;; A pan outside [-1,1] is refused by name rather than clamped: a
  ;; caller that passed 50 meaning "50 percent" has a bug in whatever
  ;; computed it, and clamping buries that bug in the mix.
  (define (pan-gains pan)
    (let ((p (if (flonum? pan) pan (exact->inexact pan))))
      (when (or (fl<? p -1.0) (fl<? 1.0 p))
        (error 'pan-gains "a pan must lie in [-1,1]" pan))
      (let ((theta (fl* (fl+ p 1.0) (fl/ $trig-pi 4.0))))
        (cons ($cos-fl theta) ($sin-fl theta)))))

  ;; Which voice to drop so that a new one can start -- or that the new
  ;; one must not start after all.  Four kinds of answer, and they are
  ;; a closed set:
  ;;
  ;;   #f          admit it; nothing has to go
  ;;   an id       drop that voice, then admit
  ;;   'reject     the candidate matters less than anything it could
  ;;               displace; do not start it
  ;;   'reserved   the free capacity is reserved for loops, or the pool
  ;;               is entirely loops; do not start it
  ;;
  ;; 'reject and 'reserved are kept apart deliberately.  A test that
  ;; cannot separate them would let one mistake hide the other, and a
  ;; caller cannot separate them either: one means "this sound was not
  ;; important enough", the other means "your music is using the pool".
  ;;
  ;; k is a FLOOR for loops, not a ceiling: sfx may not take the last k
  ;; slots, but loops may use the whole pool.  A game that starts more
  ;; loops than its cap will starve its effects -- and will be TOLD so,
  ;; through 'reserved, rather than finding sounds mysteriously silent.
  ;; Reserving in the other direction as well is a second policy with a
  ;; second failure mode, and nothing measured asks for it yet.
  (define (voice-evict voices cap k candidate-priority candidate-kind)
    (let ((n (vector-length voices)))
      (unless (and (integer? cap) (exact? cap) (> cap 0))
        (error 'voice-evict "the cap must be a positive exact integer" cap))
      (unless (and (integer? k) (exact? k) (>= k 0))
        (error 'voice-evict "the reserve must be a non-negative exact integer" k))
      (unless (< k cap)
        ;; cap = k leaves no slot an effect may ever occupy: a pool that
        ;; can never make a sound, with no symptom but silence
        (error 'voice-evict "the cap must exceed the loop reserve" cap k))
      (when (> n cap)
        (error 'voice-evict "more voices than the cap allows" n cap))
      (unless (or (eq? candidate-kind 'sfx) (eq? candidate-kind 'loop))
        (error 'voice-evict "a voice is 'sfx or 'loop" candidate-kind))
      (let loop ((i 0) (sfx 0) (worst #f))
        (if (< i n)
            (let* ((v (vector-ref voices i))
                   (kind (vector-ref v 3))
                   (sfx? (eq? kind 'sfx)))
              (loop (+ i 1)
                    (if sfx? (+ sfx 1) sfx)
                    ;; the weakest sfx: lowest priority, oldest on a
                    ;; tie, and on a full tie the one written first --
                    ;; so the answer never depends on traversal order
                    (if (and sfx? (or (not worst)
                                      ($voice-weaker? v worst)))
                        v
                        worst)))
            ($voice-decide n cap k sfx worst
                           ($voice-fl candidate-priority)
                           candidate-kind)))))

  ;; Who goes when the pool must SHRINK -- a different question from
  ;; "may this candidate in, and who makes room", and it needs its own
  ;; entry point.  Lowering the cap leaves |voices| > cap, which is
  ;; exactly what voice-evict refuses by name, so the pool cannot get a
  ;; victim out of it: the first call already refuses, and looping does
  ;; not help.
  ;;
  ;; Effects go before loops.  Loops are protected from being crowded
  ;; out BY EFFECTS, which is what the reserve means; they are not
  ;; protected from a cap that no longer fits them, because then there
  ;; is no alternative -- something has to go.
  ;;
  ;; The comparator is shared with voice-evict rather than restated, so
  ;; "weakest" means one thing in this library.  Answers #f for an
  ;; empty pool.
  (define (voice-weakest voices)
    (let ((n (vector-length voices)))
      (let loop ((i 0) (worst-sfx #f) (worst-loop #f))
        (if (< i n)
            (let* ((v (vector-ref voices i))
                   (sfx? (eq? (vector-ref v 3) 'sfx)))
              (loop (+ i 1)
                    (if (and sfx? (or (not worst-sfx) ($voice-weaker? v worst-sfx)))
                        v worst-sfx)
                    (if (and (not sfx?)
                             (or (not worst-loop) ($voice-weaker? v worst-loop)))
                        v worst-loop)))
            (cond (worst-sfx (vector-ref worst-sfx 0))
                  (worst-loop (vector-ref worst-loop 0))
                  (else #f))))))

  ;; Every number that reaches a comparison passes through here.
  ;;
  ;; The first version coerced the CANDIDATE's priority and compared the
  ;; residents' fields raw, so a caller writing priorities as 1, 5, 9 --
  ;; which is how anyone writes priorities -- worked on an empty pool
  ;; and trapped on the first full one.  One field, two rules, and
  ;; nothing to report the difference.
  ;;
  ;; Coercing rather than refusing follows the rest of the tree
  ;; ($col-fl, $cam-fl, $p-fl all do this) and follows what a refusal is
  ;; FOR: pan = 50 is refused because it can only be a miscomputed
  ;; percentage, a defect wearing a value's clothes.  An exact 5 for a
  ;; priority is not a defect -- it is the obvious way to write one --
  ;; so refusing it would be a refusal with no defect behind it.
  (define ($voice-fl v) (if (flonum? v) v (exact->inexact v)))
  (define ($voice-priority v) ($voice-fl (vector-ref v 2)))
  (define ($voice-start v) ($voice-fl (vector-ref v 1)))

  (define ($voice-weaker? a b)          ; is a a better victim than b?
    (let ((pa ($voice-priority a)) (pb ($voice-priority b)))
      (cond ((fl<? pa pb) #t)
            ((fl<? pb pa) #f)
            (else (fl<? ($voice-start a) ($voice-start b))))))

  (define ($voice-decide n cap k sfx worst priority kind)
    (if (eq? kind 'loop)
        (cond ((< n cap) #f)            ; loops may use the whole pool
              (worst (vector-ref worst 0))
              (else 'reject))           ; a full pool of loops
        ;; The invariant the reserve keeps is  #sfx <= cap - k  , and
        ;; these three rules are how it is kept.  Writing the invariant
        ;; down is what makes it possible to see that a rule is doing
        ;; nothing: a REPLACEMENT leaves #sfx unchanged, so it cannot
        ;; break the bound, so refusing one in the reserve's name was a
        ;; rule that did not know what it was protecting.
        (let ((general (- cap k)))
          (cond
           ;; grow the effect population only while it is under bound
           ;; AND there is a slot at all -- loops may have overflowed,
           ;; so a full pool can still show #sfx under the bound
           ((and (< n cap) (< sfx general)) #f)
           ;; at or over the bound: compete with the other effects.
           ;; This is allowed even when the only free slot is reserved,
           ;; because swapping one effect for another never touches the
           ;; room the loops are being kept.
           ((not worst) 'reserved)      ; nothing of mine here to replace
           ((not (fl<? ($voice-priority worst) priority)) 'reject)
           (else (vector-ref worst 0)))))))
