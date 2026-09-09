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
                (unless (and (real? mx) (not (< mx 0)))
                  (error 'make-stats "a pool maximum is a non-negative real" name mx))
                (unless (and (real? regen) (not (< regen 0)))
                  (error 'make-stats "a regeneration rate is a non-negative real" name regen))
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

  (define (stat-set! s name v)
    (let ((p ($pool 'stat-set! s name)))
      (unless (real? v) (error 'stat-set! "a pool value is a real" name v))
      ($p-value! p ($clamp p v))))

  (define (stat-add! s name d)
    (let ((p ($pool 'stat-add! s name)))
      (unless (real? d) (error 'stat-add! "a pool change is a real" name d))
      ($p-value! p ($clamp p (+ ($p-value p) d)))))

  ;; All or nothing.  A partial spend is the worst of the three possible
  ;; answers: the caller's action goes ahead having paid less than it
  ;; asked to, and the pool is left at a value neither side chose.
  (define (stats-spend! s name amount)
    (let ((p ($pool 'stats-spend! s name)))
      (unless (and (real? amount) (not (< amount 0)))
        (error 'stats-spend! "a cost is a non-negative real" name amount))
      (and (not (< ($p-value p) amount))
           (begin ($p-value! p ($clamp p (- ($p-value p) amount))) #t))))

  ;; Answers what was actually removed, which is not the amount asked
  ;; for once the pool runs out.  A caller that reports damage, or feeds
  ;; a counter with it, needs the number that happened rather than the
  ;; number it proposed.
  (define (stats-damage! s name amount)
    (let ((p ($pool 'stats-damage! s name)))
      (unless (and (real? amount) (not (< amount 0)))
        (error 'stats-damage! "damage is a non-negative real" name amount))
      (let* ((before ($p-value p))
             (after ($clamp p (- before amount))))
        ($p-value! p after)
        (- before after))))

  ;; The mirror of stats-damage!, and it answers the same way: what was
  ;; actually restored, which stops short at the maximum.
  (define (stats-heal! s name amount)
    (let ((p ($pool 'stats-heal! s name)))
      (unless (and (real? amount) (not (< amount 0)))
        (error 'stats-heal! "healing is a non-negative real" name amount))
      (let* ((before ($p-value p))
             (after ($clamp p (+ before amount))))
        ($p-value! p after)
        (- after before))))

  ;; Each pool moves by its own rate; a rate of zero is a pool that only
  ;; ever refills explicitly.  Time does not run backwards, and a
  ;; negative dt is refused rather than quietly draining every pool.
  (define (stats-regenerate! s dt)
    ($need-stats 'stats-regenerate! s)
    (unless (and (real? dt) (not (< dt 0)))
      (error 'stats-regenerate! "elapsed time is a non-negative real" dt))
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
    (unless (and (real? amount) (not (< amount 0)))
      (error 'stats-gain-xp! "experience is a non-negative real" amount))
    ($xp! s (+ ($xp s) amount))
    (let ((curve ($curve s)))
      (if (not curve)
          0
          (let loop ((gained 0))
            (let ((need (curve ($level s))))
              (unless (and (real? need) (< 0 need))
                (error 'stats-gain-xp!
                       "the level curve answered a cost that is not positive"
                       ($level s) need))
              (if (< ($xp s) need)
                  gained
                  (begin
                    ($xp! s (- ($xp s) need))
                    ($level! s (+ ($level s) 1))
                    (let ((hook ($on-level s)))
                      (when hook (hook s ($level s))))
                    (loop (+ gained 1))))))))))
