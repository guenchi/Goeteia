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

;; Depleting and refilling pools, and the experience that raises them.
;;
;; A pool is a NAME, a current value, a maximum and a regeneration rate.
;; Naming them is the whole interface decision here.  The obvious
;; alternative is a fixed vector with index constants -- slot 0 is
;; health, slot 2 is mana -- and that turns every call site into an
;; unwritten agreement about which number means which pool.  Getting one
;; index wrong there does not raise: it reads and writes the wrong pool
;; and keeps going.  A name that is not a pool raises here, by name, at
;; the call that used it; nothing answers zero or #f for an unknown
;; pool, because a typo that reads as an empty pool is a bug that will
;; be found in a playtest rather than at the call.
;;
;; What this library does NOT decide:
;;
;;   - which pools exist, how large they are, or how fast they refill:
;;     all three come from the caller's own table;
;;   - what experience a level costs: the caller supplies a curve, and
;;     without one experience accumulates and no level is ever gained;
;;   - what a level grants: the caller supplies a hook, and this library
;;     only promises to call it once per level, at the moment the level
;;     is reached.
;;
;; Those three were constants in the code this grew out of -- a fixed
;; three pools, 80*level to advance, +20 health and +10 mana per level.
;; Numbers like that are a game's design, not a library's, and a library
;; that holds them can only be used by the game it was cut from.
;;
;; There is deliberately no invulnerability timer.  Temporary states
;; belong with the other temporary states, and one living here would
;; make stats-damage! quietly depend on a clock this library does not
;; own: the same call would subtract or not subtract depending on
;; something the caller cannot see in the argument list.  A caller who
;; wants immunity decides that BEFORE it calls stats-damage!, where the
;; decision is visible in its own code.
(library (gam stats)
  (export make-stats stats? stat stat-max stat-set! stat-add!
          stats-spend! stats-damage! stats-heal!
          stats-regenerate! stats-refill!
          stats-level stats-xp stats-gain-xp!)
  (import (rnrs))

  ;; a pool: #(name value max regen zero)
  ;;
  ;; `zero' is the pool's own zero, exact when its maximum is exact and
  ;; inexact when it is not, so a pool set up in flonums stays in
  ;; flonums all the way down to empty instead of changing kind at the
  ;; one value a caller is most likely to compare against.
  ;; A real that is still finite once made inexact, which is what it
  ;; becomes when +, -, * or / combines it with a flonum, or when sin or
  ;; cos takes it; +, -, * and / on exact operands alone stay exact.  An
  ;; exact number of any size is finite as an exact number, yet 2^1024
  ;; becomes +inf.0 and 2^-1100 becomes 0.0 when that happens.  (- y y)
  ;; is 0 for every finite flonum y and NaN for either infinity and for
  ;; NaN; 1.7e308 passes, which a bound such as (< y 1e300) would
  ;; wrongly refuse.  A positive bound is tested on (inexact v) for the
  ;; same reason, since 2^-1100 is positive and becomes 0.0.  A
  ;; non-negative bound is tested on v itself, the stricter of the two
  ;; there, since -2^-1100 becomes -0.0 and (<= 0 -0.0) holds.  Either
  ;; way the value is kept as given.  All of this measured on the three
  ;; back ends.  One private copy per (gam ...) library whose checks use
  ;; it; "Prelude gaps" in docs/limits.md says why, and all eight change
  ;; together when that entry does.
  (define ($finite? x) (let ((y (inexact x))) (= 0 (- y y))))

  (define ($p-name p) (vector-ref p 0))
  (define ($p-value p) (vector-ref p 1))
  (define ($p-value! p v) (vector-set! p 1 v))
  (define ($p-max p) (vector-ref p 2))
  (define ($p-regen p) (vector-ref p 3))
  (define ($p-zero p) (vector-ref p 4))

  ;; #(gam-stats pools level xp curve on-level)
  (define ($stats? s)
    (and (vector? s) (= (vector-length s) 6)
         (eq? (vector-ref s 0) 'gam-stats)))
  (define ($pools s) (vector-ref s 1))
  (define ($level s) (vector-ref s 2))
  (define ($level! s v) (vector-set! s 2 v))
  (define ($xp s) (vector-ref s 3))
  (define ($xp! s v) (vector-set! s 3 v))
  (define ($curve s) (vector-ref s 4))
  (define ($on-level s) (vector-ref s 5))

  (define (stats? s) ($stats? s))

  (define ($need-stats who s)
    (unless ($stats? s) (error who "not a stats value" s)))

  ;; Every entry point resolves a name through this one, so there is a
  ;; single place where an unknown pool is refused and a single message
  ;; for it.
  (define ($pool who s name)
    ($need-stats who s)
    (unless (symbol? name) (error who "a pool name is a symbol" name))
    (let loop ((ps ($pools s)))
      (cond ((null? ps) (error who "no such pool" name))
            ((eq? ($p-name (car ps)) name) (car ps))
            (else (loop (cdr ps))))))

  (define ($clamp p v)
    (cond ((< v ($p-zero p)) ($p-zero p))
          ((< ($p-max p) v) ($p-max p))
          (else v)))

  ;; The pool table is read once, in order, and the pools keep that
  ;; order for the life of the value; nothing here re-sorts them, so a
  ;; caller walking them sees its own table back.
  (define (make-stats pools . rest)
    (unless (list? pools) (error 'make-stats "the pool table is a list" pools))
    (let ((curve (if (null? rest) #f (car rest)))
          (hook (if (or (null? rest) (null? (cdr rest))) #f (cadr rest))))
      (unless (or (not curve) (procedure? curve))
        (error 'make-stats "the level curve is a procedure of a level" curve))
      (unless (or (not hook) (procedure? hook))
        (error 'make-stats "the level hook is a procedure of stats and a level" hook))
      (let build ((ps pools) (out '()))
        (if (null? ps)
            (vector 'gam-stats (reverse out) 1 0 curve hook)
            (let ((row (car ps)))
              (unless (and (list? row) (= (length row) 3))
                (error 'make-stats "a pool is (name max regen-per-second)" row))
              (let ((name (car row)) (mx (cadr row)) (regen (caddr row)))
                (unless (symbol? name)
                  (error 'make-stats "a pool name is a symbol" name))
                (unless (and (real? mx) ($finite? mx) (<= 0 mx))
                  (error 'make-stats
                         "a pool maximum is a non-negative real, finite as a flonum"
                         name mx))
                (unless (and (real? regen) ($finite? regen) (<= 0 regen))
                  (error 'make-stats
                         "a regeneration rate is a non-negative real, finite as a flonum"
                         name regen))
                ;; A repeated name would leave one of the two pools
                ;; unreachable: every lookup answers the first, so the
                ;; second could be written only by the code that built
                ;; the table and never read back.
                (let dup ((seen out))
                  (cond ((null? seen) #f)
                        ((eq? ($p-name (car seen)) name)
                         (error 'make-stats "that pool name appears twice" name))
                        (else (dup (cdr seen)))))
                (build (cdr ps)
                       (cons (vector name mx mx regen
                                     (if (exact? mx) 0 (* 0.0 mx)))
                             out))))))))

  (define (stat s name) ($p-value ($pool 'stat s name)))
  (define (stat-max s name) ($p-max ($pool 'stat-max s name)))

  ;; $finite? rather than a cutoff: a pool value or a change to one may
  ;; be any real finite as a flonum, and a cutoff would refuse legitimate
  ;; values.  $clamp would map an infinity to the pool's bounds, and that
  ;; is deterministic -- the reason to refuse it is what it hides.
  ;; Measured 2026-09-23: a change of -inf.0 was clamped to 0 and emptied
  ;; the pool without a word to the caller, so an arithmetic mistake
  ;; upstream became a legal-looking move.
  ;;
  ;; This is the door the non-negative checks do not cover, and it opens
  ;; on the worst room: $clamp answers NaN for NaN, so the pool holds
  ;; NaN; every later comparison against it is false; and a guard whose
  ;; comparison is false PASSES.  Measured before this check existed, a
  ;; pool set to NaN answered #t to stats-spend! and did not move, so the
  ;; resource could be spent without limit and without the balance ever
  ;; changing.
  (define (stat-set! s name v)
    (let ((p ($pool 'stat-set! s name)))
      (unless (and (real? v) ($finite? v))
        (error 'stat-set! "a pool value is a real, finite as a flonum" name v))
      ($p-value! p ($clamp p v))))

  (define (stat-add! s name d)
    (let ((p ($pool 'stat-add! s name)))
      (unless (and (real? d) ($finite? d))
        (error 'stat-add!
               "a pool change is a real, finite as a flonum"
               name d))
      ($p-value! p ($clamp p (+ ($p-value p) d)))))

  ;; All or nothing.  A partial spend is the worst of the three possible
  ;; answers: the caller's action goes ahead having paid less than it
  ;; asked to, and the pool is left at a value neither side chose.
  (define (stats-spend! s name amount)
    (let ((p ($pool 'stats-spend! s name)))
      (unless (and (real? amount) ($finite? amount) (<= 0 amount))
        (error 'stats-spend!
               "a cost is a non-negative real, finite as a flonum"
               name amount))
      (and (not (< ($p-value p) amount))
           (begin ($p-value! p ($clamp p (- ($p-value p) amount))) #t))))

  ;; Answers what was actually removed, which is not the amount asked
  ;; for once the pool runs out.  A caller that reports damage, or feeds
  ;; a counter with it, needs the number that happened rather than the
  ;; number it proposed.
  (define (stats-damage! s name amount)
    (let ((p ($pool 'stats-damage! s name)))
      (unless (and (real? amount) ($finite? amount) (<= 0 amount))
        (error 'stats-damage!
               "damage is a non-negative real, finite as a flonum"
               name amount))
      (let* ((before ($p-value p))
             (after ($clamp p (- before amount))))
        ($p-value! p after)
        (- before after))))

  ;; The mirror of stats-damage!, and it answers the same way: what was
  ;; actually restored, which stops short at the maximum.
  (define (stats-heal! s name amount)
    (let ((p ($pool 'stats-heal! s name)))
      (unless (and (real? amount) ($finite? amount) (<= 0 amount))
        (error 'stats-heal!
               "healing is a non-negative real, finite as a flonum"
               name amount))
      (let* ((before ($p-value p))
             (after ($clamp p (+ before amount))))
        ($p-value! p after)
        (- after before))))

  ;; Each pool moves by its own rate; a rate of zero is a pool that only
  ;; ever refills explicitly.  Time does not run backwards, and a
  ;; negative dt is refused rather than quietly draining every pool.
  (define (stats-regenerate! s dt)
    ($need-stats 'stats-regenerate! s)
    (unless (and (real? dt) ($finite? dt) (<= 0 dt))
      (error 'stats-regenerate!
             "elapsed time is a non-negative real, finite as a flonum"
             dt))
    (let loop ((ps ($pools s)))
      (unless (null? ps)
        (let ((p (car ps)))
          ($p-value! p ($clamp p (+ ($p-value p) (* ($p-regen p) dt)))))
        (loop (cdr ps)))))

  (define (stats-refill! s)
    ($need-stats 'stats-refill! s)
    (let loop ((ps ($pools s)))
      (unless (null? ps)
        ($p-value! (car ps) ($p-max (car ps)))
        (loop (cdr ps)))))

  (define (stats-level s) ($need-stats 'stats-level s) ($level s))
  (define (stats-xp s) ($need-stats 'stats-xp s) ($xp s))

  ;; Answers how many levels were gained, which is what a caller needs
  ;; to know whether to say anything at all.  With no curve there is no
  ;; notion of a level in this game, so experience accumulates and the
  ;; answer is always zero -- deliberately not an error, because a game
  ;; that tracks experience without levels is a game, not a mistake.
  ;;
  ;; A curve that answers a non-positive cost is refused instead of
  ;; being believed: the loop below would raise a level for free and
  ;; never terminate, and a hang is a far worse diagnosis than a named
  ;; error naming the level whose cost was wrong.
  (define (stats-gain-xp! s amount)
    ($need-stats 'stats-gain-xp! s)
    (unless (and (real? amount) ($finite? amount) (<= 0 amount))
      (error 'stats-gain-xp!
             "experience is a non-negative real, finite as a flonum"
             amount))
    ;; Two gains that are each finite can add up to a total that is not,
    ;; and nothing after this point could recover from it: the total is
    ;; worked out, checked, and only then stored, so a refused gain
    ;; leaves the total as it was.
    (let ((next (+ ($xp s) amount)))
      (unless ($finite? next)
        (error 'stats-gain-xp!
               "the experience total would not be finite as a flonum"
               ($xp s) amount))
      ($xp! s next))
    (let ((curve ($curve s)))
      (if (not curve)
          0
          (let loop ((gained 0))
            (let ((need (curve ($level s))))
              ;; +inf.0 is let through: a level whose cost is infinite can
              ;; never be bought, so experience keeps accumulating and the
              ;; loop stops -- which is how a curve says the cap has been
              ;; reached.  That holds because the total is kept finite as
              ;; a flonum by the check above.  Measured 2026-09-25, before
              ;; that check: two gains of 1e308 made it +inf.0, which is
              ;; not less than +inf.0, and the capped level was bought.
              ;; This is an answer read during the loop, not a
              ;; value stored, so it is held only to the bounds it always
              ;; had; NaN fails (< 0 need) and is refused with the rest.
              (unless (and (real? need) (< 0 need))
                (error 'stats-gain-xp!
                       "the level curve answered a cost that is not positive"
                       ($level s) need))
              ;; The loop ends only because each level bought makes the
              ;; stored total smaller.  A cost below the total's flonum
              ;; resolution does not: measured 2026-09-25, 1e308 less
              ;; 1000 is 1e308, and the loop ran for ever.  So a
              ;; purchase is refused when the difference compares equal
              ;; to the total.  An exact total minus an exact cost never
              ;; does.  A mixed pair is compared as flonums, as it is
              ;; subtracted, so a purchase that would only round an
              ;; exact total down to the nearest flonum is refused as
              ;; well: exact 2^54 + 1 less 1.0 stores 2^54, which
              ;; compares equal to the total.  There is no cap on the
              ;; number of levels one call may buy; docs/limits.md says
              ;; what that costs.
              (if (< ($xp s) need)
                  gained
                  (let ((left (- ($xp s) need)))
                    (when (= left ($xp s))
                      (error 'stats-gain-xp!
                             "the experience total is too large for a level's cost to be subtracted from it"
                             ($level s) ($xp s) need))
                    ($xp! s left)
                    ($level! s (+ ($level s) 1))
                    (let ((hook ($on-level s)))
                      (when hook (hook s ($level s))))
                    (loop (+ gained 1))))))))))
