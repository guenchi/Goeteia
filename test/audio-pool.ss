;; expect: #t
;; The voice pool's tail bound, which is the one thing about the pool
;; that a graph picture cannot show.
;;
;; When a stronger effect displaces a weaker one, the weaker one is not
;; torn down where it stands -- it is faded, and the teardown is hung on
;; the source's `ended`.  So for the length of one fade the pool holds
;; MORE allocations than its cap, on purpose.  The design writes that as
;;
;;     sounding(t)  <=  cap + (evictions in (t-F, t])
;;
;; and the cells below are the first reading of it.  Two quantities,
;; and they are not the same one:
;;
;;   ALLOCATED   what (audio-voice-count) reports.  It counts a voice
;;               that is fading out, and it falls only when `ended`
;;               arrives -- never because time passed.
;;   SOUNDING    allocated minus the voices whose stop has already been
;;               reached.  Derived HERE, from the mock's log and clock,
;;               rather than read from a counter the library computes:
;;               the library's arithmetic is what these cells are for,
;;               and a number it hands us would be its own answer to its
;;               own question.
;;
;; The third cell is the one that discriminates.  An implementation
;; that released the voice inside stop() rather than on `ended` passes
;; "count is 3 after the eviction" and "count is 2 after ended" -- and
;; it tears the nodes down before the ramp has run, which is the defect
;; the fade exists to prevent.  What it cannot pass is "the clock moved
;; past the ramp and the count did not".
(import (rnrs) (web js) (audmock) (aud sfx))

(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))

(audio-mock-install!)
(audio-init!)
(define FADE 0.01)
(audio-voices! 2 0 FADE)                ; cap 2, no loop reserve
(define buf (js-eval "({id:'BUF'})"))
(audio-mock-reset!)                     ; clock back to 0, log empty

;; SOUNDING, derived: allocated minus the voices already stopped.  A
;; source is scheduled to stop exactly once, so counting stop entries
;; whose time has been reached counts voices, not events.
(define (stopped-by now)
  (let loop ((i 0) (n 0))
    (cond ((>= i (audio-log-length)) n)
          ((and (string=? (audio-op i) "stop")
                (not (eq? 'absent (audio-arg i 1)))
                (<= (audio-arg-num i 1) now))
           (loop (+ i 1) (+ n 1)))
          (else (loop (+ i 1) n)))))
(define (sounding) (- (audio-voice-count) (stopped-by (audio-now))))

(play! buf 1.0 1.0 #f 1.0)              ; a
(play! buf 1.0 1.0 #f 1.0)              ; b
(check "POOL-FILL: two effects in a pool of two" (= 2 (audio-voice-count)))
(check "POOL-FILL: and both of them are sounding" (= 2 (sounding)))

;; ---- the eviction ----
(play! buf 1.0 1.0 #f 9.0)              ; stronger: displaces one of them
(check "POOL-OVERSHOOT: the eviction leaves the pool holding cap+1 allocations"
       (= 3 (audio-voice-count)))
(check "POOL-OVERSHOOT: the displaced voice is stopped at the end of the fade, not now"
       (let ((i (audio-find "stop")))
         (and i (not (eq? 'absent (audio-arg i 1)))
              (< (abs (- (audio-arg-num i 1) FADE)) 0.000000001))))
(check "POOL-OVERSHOOT: so all three are still sounding, and the bound allows it (3 <= cap+1)"
       (= 3 (sounding)))

;; ---- time alone releases nothing ----
(audio-advance! (* 2.0 FADE))
(check "POOL-ENDED: past the end of the ramp the allocation is STILL held"
       (= 3 (audio-voice-count)))
(check "POOL-ENDED: but it has stopped sounding, so the bound is met again"
       (= 2 (sounding)))

;; ---- and `ended` is what releases it ----
(define evicted (audio-arg (audio-find "stop") 0))
(audio-fire-ended! evicted)
(check "POOL-ENDED: the callback is what frees the slot"
       (= 2 (audio-voice-count)))
(check "POOL-ENDED: and the freed voice was disconnected"
       (audio-find "disconnect"))
;; delivering it twice must not free a second voice: on the platform a
;; teardown that runs again is a teardown of somebody else's nodes
(audio-fire-ended! evicted)
(check "POOL-ENDED: a second delivery for the same source frees nothing more"
       (= 2 (audio-voice-count)))
(display (= failed 0))
