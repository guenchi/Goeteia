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

;; Who exists, and handles that cannot be confused with what replaced them.
;;
;; A simulation hands entity references around: to a scheduler, to an
;; event payload, to a save file.  An index is not enough, because the
;; slot it names is reused, and the day it is reused every stale copy of
;; that index starts addressing a stranger -- silently, since an index
;; into a live array is always "valid".  So a handle here is a slot and
;; the generation that slot was on: destroying an entity bumps the
;; generation, and the old handle stops matching for good.  That is the
;; whole reason this library exists; everything else is bookkeeping.
;;
;; Capacity is fixed.  Running out is an error rather than a silent
;; growth, because the moment a simulation stopped being bounded is
;; worth knowing.  Components are a small association per entity, which
;; is right for hundreds of entities and wrong for hundreds of
;; thousands; when someone measures that, the fix is an index, and the
;; interface here does not have to change for it.
(library (sim entity)
  (export make-entities entity-spawn! entity-alive? entity-destroy!
          entity-set! entity-ref entity-each entity-count entity-capacity)
  (import (rnrs))

  ;; #(components generations free count capacity); components is a
  ;; vector of per-slot alists, or #f for a slot that holds no entity.
  (define ($ents-components w) (vector-ref w 0))
  (define ($ents-generations w) (vector-ref w 1))

  (define (make-entities capacity)
    (unless (and (fixnum? capacity) (> capacity 0))
      (error 'make-entities "capacity must be a positive fixnum" capacity))
    (vector (make-vector capacity #f)
            (make-vector capacity 0)
            (let build ((i (- capacity 1)) (out '()))
              (if (< i 0) out (build (- i 1) (cons i out))))
            0
            capacity))

  (define (entity-capacity w) (vector-ref w 4))
  (define (entity-count w) (vector-ref w 3))

  ;; A handle matches only while its slot is occupied AND still on the
  ;; generation the handle was issued for.  A handle from another store,
  ;; or a pair that was never a handle, simply does not match.
  (define (entity-alive? w h)
    (and (pair? h) (fixnum? (car h)) (fixnum? (cdr h))
         (>= (car h) 0) (< (car h) (entity-capacity w))
         (vector-ref ($ents-components w) (car h))
         (= (cdr h) (vector-ref ($ents-generations w) (car h)))
         #t))

  (define (entity-spawn! w)
    (let ((free (vector-ref w 2)))
      (unless (pair? free)
        (error 'entity-spawn! "no free slot: the store is at capacity"
               (entity-capacity w)))
      (let ((slot (car free)))
        (vector-set! w 2 (cdr free))
        (vector-set! ($ents-components w) slot '())
        (vector-set! w 3 (+ (vector-ref w 3) 1))
        (cons slot (vector-ref ($ents-generations w) slot)))))

  ;; Destroying is idempotent: a handle that no longer matches names
  ;; something already gone, and asking for that again is not an error.
  (define (entity-destroy! w h)
    (when (entity-alive? w h)
      (let ((slot (car h)))
        (vector-set! ($ents-components w) slot #f)
        (vector-set! ($ents-generations w) slot
                     (+ (vector-ref ($ents-generations w) slot) 1))
        (vector-set! w 2 (cons slot (vector-ref w 2)))
        (vector-set! w 3 (- (vector-ref w 3) 1)))))

  ;; Writing is not idempotent: a write to something that no longer
  ;; exists is a mistake in the caller, and saying so is the point of
  ;; having generations at all.  Reading is quiet and answers the
  ;; default, because asking about the dead is how callers find out.
  (define (entity-set! w h key value)
    (unless (symbol? key)
      (error 'entity-set! "a component key must be a symbol" key))
    (unless (entity-alive? w h)
      (error 'entity-set! "no such entity: the handle is stale or foreign" h))
    (let* ((rows (vector-ref ($ents-components w) (car h)))
           (row (assq key rows)))
      (if row
          (set-cdr! row value)
          (vector-set! ($ents-components w) (car h) (cons (cons key value) rows))))
    value)

  (define (entity-ref w h key default)
    (if (entity-alive? w h)
        (let ((row (assq key (vector-ref ($ents-components w) (car h)))))
          (if row (cdr row) default))
        default))

  ;; The walk is over a snapshot taken before the first call, and each
  ;; entity is checked again as it comes up.  So destroying during a
  ;; walk skips what was destroyed, and spawning during a walk is not
  ;; visited until the next one -- both stated, because a caller that
  ;; spawns from inside a walk otherwise cannot tell whether it just
  ;; wrote a loop that never ends.
  (define (entity-each w proc)
    (let* ((cs ($ents-components w))
           (gs ($ents-generations w))
           (snapshot
            (let scan ((i (- (entity-capacity w) 1)) (out '()))
              (cond ((< i 0) out)
                    ((vector-ref cs i)
                     (scan (- i 1) (cons (cons i (vector-ref gs i)) out)))
                    (else (scan (- i 1) out))))))
      (for-each (lambda (h) (when (entity-alive? w h) (proc h))) snapshot))))
