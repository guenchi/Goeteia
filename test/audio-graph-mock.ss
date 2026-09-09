;; expect: #t
;; The recording audio mock, judged as an instrument.
;;
;; ⭐ This file tests test/lib/audmock.ss, not (aud sfx).  It drives the
;; mock by hand, through (web js), so that what it asserts is what the
;; INSTRUMENT records and not what any library happens to do.  A mock
;; checked only through its subject is checked by the thing it is meant
;; to judge: if both are blind to the same distinction, both are green.
;;
;; The four properties below are exactly the four the mock was rewritten
;; for.  Each one is a distinction the previous inline mock could not
;; make, and for each one there is a way the rewrite could have gone
;; wrong that leaves every audio test still passing:
;;
;;   - a mock that defaults an absent index to 0 makes "explicitly
;;     input 1" and "not given" the same reading, and the merger wiring
;;     that the explicit indices exist for becomes unjudgeable;
;;   - a mock that rounds its timestamps makes two ramps 100 us apart
;;     identical, and a fade is a question about exactly that;
;;   - a mock that reuses one id per node kind makes "which gain
;;     reached the destination" unaskable, and a panned voice has three;
;;   - a mock that fires `ended` from inside stop() cannot tell a
;;     library that waits for the callback from one that assumes it.
(import (rnrs) (web js) (audmock))

(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))

(audio-mock-install!)
(audio-mock-reset!)
(define ctx (js-new (js-get (js-global) "AudioContext")))
(define (make what) (js-call (js-get ctx what) ctx))
(define (id n) (js->string (js-get n "id")))

;; ---- absent is not zero ----
(define g1 (make "createGain"))
(define g2 (make "createGain"))
(define m (js-call (js-get ctx "createChannelMerger") ctx (number->js 2)))
(js-call (js-get g1 "connect") g1 m)                                ; no indices
(js-call (js-get g2 "connect") g2 m (number->js 0) (number->js 1))   ; both given
(let ((a (audio-find "connect"))
      (b (audio-find-from "connect" (+ 1 (audio-find "connect")))))
  (check "MOCK-ABSENT: a connect with no indices records them as absent, not as 0"
         (and (equal? (audio-arg a 2) "absent") (equal? (audio-arg a 3) "absent")))
  (check "MOCK-ABSENT: and an explicit 0 records as 0, which is a different reading"
         (and (equal? (audio-arg b 2) "0") (equal? (audio-arg b 3) "1")))
  (check "MOCK-ABSENT: the two are not equal -- if they were, this mock could not judge a merger"
         (not (equal? (audio-arg a 2) (audio-arg b 2)))))

;; ---- node identity ----
(check "MOCK-IDENTITY: two gains have different ids"
       (not (string=? (id g1) (id g2))))
(check "MOCK-IDENTITY: and a connect names the one that made it"
       (string=? (audio-arg (audio-find "connect") 0) (id g1)))

;; ---- raw times ----
;; 100 microseconds apart.  Rounded to two places these are one number.
(audio-mock-reset!)
(audio-advance! 2.0)
(js-set! (js-get g1 "gain") "value" (number->js 0.5))
(audio-advance! 0.0001)
(js-set! (js-get g1 "gain") "value" (number->js 0.6))
(let ((a (audio-find "param.value"))
      (b (audio-find-from "param.value" (+ 1 (audio-find "param.value")))))
  (check "MOCK-RAWTIME: two writes 100 us apart have different recorded times"
         (not (= (audio-time-at a) (audio-time-at b))))
  (check "MOCK-RAWTIME: and the difference is the one that was asked for"
         (< (abs (- (- (audio-time-at b) (audio-time-at a)) 0.0001)) 0.000000001))
  (check "MOCK-RAWTIME: a parameter write records the value that was assigned"
         (= (audio-arg-num b 2) 0.6)))
;; the clock does not move on its own: two reads with nothing between
;; them must agree, or every timing assertion in every audio test is
;; comparing against a number that changed while it was being read
(check "MOCK-CLOCK: the clock advances only when a test advances it"
       (= (audio-now) (audio-now)))
(check "MOCK-CLOCK: backwards is refused, naming the procedure"
       (guard (e ((error? e) #t) (else #f))
         (begin (audio-advance! -1.0) #f)))

;; ---- ended arrives separately ----
(audio-mock-reset!)
(define src (make "createBufferSource"))
(js-set! src "onended" (js-eval "(() => { globalThis.__endedSeen = (globalThis.__endedSeen || 0) + 1 })"))
(js-eval "globalThis.__endedSeen = 0")
(js-call (js-get src "stop") src (number->js 3.0))
(define (ended-seen) (js->number (js-get (js-global) "__endedSeen")))
(check "MOCK-ENDED: stop() does not deliver ended"
       (and (= 0 (ended-seen)) (not (audio-find "ended"))))
(audio-fire-ended! (id src))
(check "MOCK-ENDED: the test delivers it, and the handler runs"
       (and (= 1 (ended-seen)) (audio-find "ended")))
(check "MOCK-ENDED: stop is still recorded, with the time it was given"
       (= 3.0 (audio-arg-num (audio-find "stop") 1)))

;; ---- disconnect, and the state of a node ----
(audio-mock-reset!)
(js-call (js-get g1 "disconnect") g1)
(check "MOCK-DISCONNECT: a bare disconnect is recorded, with an absent target"
       (and (audio-find "disconnect")
            (equal? (audio-arg (audio-find "disconnect") 1) "absent")))
(check "MOCK-STATE: a node that was stopped says when"
       (equal? (audio-node-field (id src) "stopped") "3"))
(check "MOCK-STATE: a node that was never started says absent"
       (equal? (audio-node-field (id g1) "started") "absent"))
(check "MOCK-STATE: and a node that does not exist says so -- a different fact"
       (equal? (audio-node-field "GAIN#9999" "started") "no-such-node"))
(display (= failed 0))
