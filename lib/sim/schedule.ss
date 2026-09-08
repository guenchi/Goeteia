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

;; What runs each tick, in an order that is written down.
;;
;; Systems are registered with a priority number and a symbol name.  The
;; number decides; equal numbers keep the order they were added in, and
;; that stays true across removals.  Nothing here depends on which file
;; loaded first, which is the failure this library exists to prevent:
;; an order that comes from load order is invisible in the source and
;; changes when someone renames a file.
;;
;; A system that raises stops the tick.  That is the opposite of what
;; (lng effect) does for cleanups, and the difference is the point: a
;; cleanup that is skipped leaks a resource, so every cleanup must get
;; its turn; a tick is one transition of the whole world, and running
;; the rest of it after a system failed produces a half-updated state
;; that looks complete.  The condition carries the name of the system
;; that raised, and the schedule is usable again afterwards.
(library (sim schedule)
  (export make-schedule schedule-add! schedule-remove! schedule-run!
          schedule-systems)
  (import (rnrs))

  ;; #(rows running?); a row is #(id priority proc live? seq)
  (define ($sch-rows s) (vector-ref s 0))

  (define (make-schedule) (vector '() #f 0))

  ;; Insertion keeps rows sorted by priority, and among equal priorities
  ;; by the sequence number they were given -- so a row that is removed
  ;; and added again goes after its old neighbours, not back where it
  ;; was.  Ordering by a stored number rather than by list position is
  ;; what makes it survive removals.
  (define ($sch-insert row rows)
    (cond ((null? rows) (list row))
          ((or (< (vector-ref row 1) (vector-ref (car rows) 1))
               (and (= (vector-ref row 1) (vector-ref (car rows) 1))
                    (< (vector-ref row 4) (vector-ref (car rows) 4))))
           (cons row rows))
          (else (cons (car rows) ($sch-insert row (cdr rows))))))

  (define (schedule-add! s id priority proc)
    (unless (symbol? id)
      (error 'schedule-add! "a system id must be a symbol" id))
    (unless (fixnum? priority)
      (error 'schedule-add! "a priority must be a fixnum" priority))
    (unless (procedure? proc)
      (error 'schedule-add! "a system must be a procedure" id))
    (let dup ((rows ($sch-rows s)))
      (cond ((null? rows) #f)
            ((and (eq? id (vector-ref (car rows) 0)) (vector-ref (car rows) 3))
             (error 'schedule-add! "a system with this id is already registered" id))
            (else (dup (cdr rows)))))
    (let ((row (vector id priority proc #t (vector-ref s 2))))
      (vector-set! s 2 (+ (vector-ref s 2) 1))
      (vector-set! s 0 ($sch-insert row ($sch-rows s)))
      row))

  ;; Removal marks the row dead rather than unlinking it, so it takes
  ;; effect at once even for a tick that is already walking the list.
  (define (schedule-remove! row) (vector-set! row 3 #f))

  (define (schedule-systems s)
    (let collect ((rows ($sch-rows s)) (out '()))
      (cond ((null? rows) (reverse out))
            ((vector-ref (car rows) 3)
             (collect (cdr rows) (cons (vector-ref (car rows) 0) out)))
            (else (collect (cdr rows) out)))))

  (define (schedule-run! s context dt)
    (when (vector-ref s 1)
      (error 'schedule-run! "a tick is already running: systems cannot run the schedule"))
    (vector-set! s 1 #t)
    (guard (e (#t (vector-set! s 1 #f)
                  (vector-set! s 0 (let keep ((rows ($sch-rows s)) (out '()))
                                     (cond ((null? rows) (reverse out))
                                           ((vector-ref (car rows) 3)
                                            (keep (cdr rows) (cons (car rows) out)))
                                           (else (keep (cdr rows) out)))))
                  (raise e)))
      (let run ((rows ($sch-rows s)))
        (unless (null? rows)
          (when (vector-ref (car rows) 3)
            ((vector-ref (car rows) 2) context dt))
          (run (cdr rows))))
      (vector-set! s 0 (let keep ((rows ($sch-rows s)) (out '()))
                         (cond ((null? rows) (reverse out))
                               ((vector-ref (car rows) 3)
                                (keep (cdr rows) (cons (car rows) out)))
                               (else (keep (cdr rows) out)))))
      (vector-set! s 1 #f))))
