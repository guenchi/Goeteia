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

;; Who hears what, without anybody having to know who is listening.
;;
;; Dispatch walks a snapshot of the subscriptions, so the set that hears
;; one emit is fixed before the first listener runs.  A listener added
;; while an emit is in flight hears the next one, and a listener removed
;; during an emit does not run even though the snapshot still holds it.
;; Both halves matter: without the snapshot, a listener that subscribes
;; from inside a handler would hear the event that created it; without
;; the liveness check, unsubscribing would not take effect until the
;; emit finished, which is exactly when a caller unsubscribes.
;;
;; Emitting from inside a listener is allowed and runs to completion
;; before the outer emit resumes.  It is bounded, because the natural
;; mistake -- a listener that emits the topic it listens to -- would
;; otherwise exhaust the stack, and a stack overflow does not say which
;; two topics were feeding each other.
(library (sim events)
  (export make-bus bus-on! bus-off! bus-emit! bus-clear! bus-depth-limit)
  (import (rnrs))

  (define bus-depth-limit 32)

  ;; #(subscriptions depth); a subscription is #(topic proc live?)
  (define (make-bus) (vector '() 0))

  (define (bus-on! b topic proc)
    (unless (symbol? topic)
      (error 'bus-on! "a topic must be a symbol" topic))
    (unless (procedure? proc)
      (error 'bus-on! "a listener must be a procedure" topic))
    (let ((token (vector topic proc #t)))
      ;; appended, so listeners hear in the order they subscribed
      (vector-set! b 0 (append (vector-ref b 0) (list token)))
      token))

  ;; Marking dead is what makes a removal take effect inside a running
  ;; emit; the token is dropped from the list as well, and doing it
  ;; twice is quiet because the second call names something already gone.
  (define (bus-off! token)
    (vector-set! token 2 #f))

  (define (bus-clear! b)
    (for-each (lambda (t) (vector-set! t 2 #f)) (vector-ref b 0))
    (vector-set! b 0 '()))

  (define (bus-emit! b topic payload)
    (unless (symbol? topic)
      (error 'bus-emit! "a topic must be a symbol" topic))
    (when (>= (vector-ref b 1) bus-depth-limit)
      (error 'bus-emit! "emit nested past the depth limit: a listener is feeding its own topic"
             topic bus-depth-limit))
    (let ((snapshot (vector-ref b 0)))
      (vector-set! b 1 (+ (vector-ref b 1) 1))
      (guard (e (#t (vector-set! b 1 (- (vector-ref b 1) 1)) (raise e)))
        (let run ((ts snapshot))
          (unless (null? ts)
            (let ((t (car ts)))
              (when (and (vector-ref t 2) (eq? topic (vector-ref t 0)))
                ((vector-ref t 1) payload)))
            (run (cdr ts))))
        (vector-set! b 1 (- (vector-ref b 1) 1))
        ;; dead tokens are dropped once nothing is walking the list
        (when (= (vector-ref b 1) 0)
          (vector-set! b 0 (let keep ((ts (vector-ref b 0)) (out '()))
                             (cond ((null? ts) (reverse out))
                                   ((vector-ref (car ts) 2)
                                    (keep (cdr ts) (cons (car ts) out)))
                                   (else (keep (cdr ts) out))))))))))
