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

;; A roster of entity handles, with one of them singled out.
;;
;; Membership is an ordered list of handles from (sim entity), plus at
;; most one selection which is either a member or nothing.
;;
;; IT HOLDS HANDLES AND NOT ENTITIES.  A handle is a slot paired with
;; the generation that slot is on, so a handle stops matching the moment
;; the entity it named is destroyed -- and keeps not matching when the
;; slot is later reused by something else.  That property is the reason
;; this library is worth having rather than a list: a roster of
;; references would quietly acquire whatever took the dead one's place,
;; and a roster of handles cannot, because the generation the handle was
;; issued for is not the generation the slot is on any more.  Every
;; question here that could be answered wrongly by a stale handle is
;; asked of the store instead of assumed.
;;
;; IT DOES NOT NOTICE DEATH BY ITSELF.  Nothing tells this library when
;; an entity is destroyed, so a destroyed member stays on the list until
;; party-prune! is called.  This is deliberate and is why the pruning is
;; a call rather than a hook: a hook would fire in the middle of
;; whatever destroyed the entity, at a moment the caller did not choose,
;; and the caller usually wants to know who left -- which it can see by
;; comparing the members across a prune, and could not see from inside a
;; callback that had already removed them.  In the meantime the roster
;; is not lying: party-members answers handles, and a dead handle
;; answers dead to anyone who asks the store.
;;
;; IT DOES NOT DECIDE HOW MANY MAY JOIN.  A limit is a rule about a
;; particular design and would have to be a number in a library that has
;; no way to choose it; a caller with a limit tests the length it
;; already has before it adds.
;;
;; THE SELECTION IS A MEMBER OR IT IS #f.  There is no third state.
;; Selecting a non-member raises rather than joining them, because the
;; two operations are not the same intent and a select! that quietly
;; added would make a typo grow the roster.  Removing the selected
;; member clears the selection instead of moving it to a neighbour:
;; there is no neighbour this library could pick that the caller would
;; not have to check anyway, and a selection that moves on its own is
;; how an input arrives at whoever happened to be next.
(library (gam party)
  (export make-party party? party-members party-selected
          party-add! party-remove! party-select! party-prune!)
  (import (rnrs) (sim entity))

  ;; #(gam-party members selected); members in the order they joined
  (define ($p? p)
    (and (vector? p) (= (vector-length p) 3)
         (eq? (vector-ref p 0) 'gam-party)))
  (define ($need-p who p)
    (unless ($p? p) (error who "not a party" p)))
  (define ($members p) (vector-ref p 1))
  (define ($members! p v) (vector-set! p 1 v))
  (define ($selected p) (vector-ref p 2))
  (define ($selected! p v) (vector-set! p 2 v))

  ;; Handles are pairs of two numbers, so identity is equality of both
  ;; halves and not eq? -- the handle a caller kept and the handle the
  ;; store would issue for the same live entity are equal without being
  ;; the same object.
  (define ($member? p h)
    (let loop ((l ($members p)))
      (and (pair? l) (or (equal? (car l) h) (loop (cdr l))))))

  (define (party? p) ($p? p))

  (define (make-party) (vector 'gam-party '() #f))

  ;; The list itself, which is never altered in place: what a caller
  ;; holds stays as it was, and a later add or remove builds a new list
  ;; rather than changing the one already handed out.
  (define (party-members p) ($need-p 'party-members p) ($members p))
  (define (party-selected p) ($need-p 'party-selected p) ($selected p))

  ;; Joining twice is quiet rather than an error: the caller that adds
  ;; on an event it may receive more than once is doing an ordinary
  ;; thing, and the roster after the second add is the roster it asked
  ;; for.  A dead handle is refused, because that caller is asking to
  ;; enrol something that is already gone and no later call would tell
  ;; it so.
  (define (party-add! p store h)
    ($need-p 'party-add! p)
    (unless (entity-alive? store h)
      (error 'party-add! "that entity is not alive" h))
    (unless ($member? p h)
      ($members! p (append ($members p) (list h)))))

  ;; Removing someone who is not a member is quiet: it asks for a state
  ;; -- that handle not on the roster -- which already holds.
  (define (party-remove! p h)
    ($need-p 'party-remove! p)
    ($members! p (let loop ((l ($members p)))
                   (cond ((not (pair? l)) '())
                         ((equal? (car l) h) (loop (cdr l)))
                         (else (cons (car l) (loop (cdr l)))))))
    (when (equal? ($selected p) h) ($selected! p #f)))

  ;; #f is how a caller says nobody, and is the only value accepted that
  ;; is not a live member.
  (define (party-select! p store h)
    ($need-p 'party-select! p)
    (unless (or (not h) (and (entity-alive? store h) ($member? p h)))
      (error 'party-select! "that entity is not a live member of the party" h))
    ($selected! p h))

  ;; The walk is over the list as it stands on entry, and party-remove!
  ;; replaces the roster rather than altering that list, so removing
  ;; while walking is safe and every member is examined exactly once.
  (define (party-prune! p store)
    ($need-p 'party-prune! p)
    (for-each
     (lambda (h) (unless (entity-alive? store h) (party-remove! p h)))
     ($members p))))
