;; expect: #t
;; The recording audio mock, judged as an instrument.
;;
;; This file tests test/lib/audmock.ss, not (aud sfx).  It drives the
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

;; ---- the graph reader, calibrated on a rewire ----
;; audio-target-of has to answer with the CURRENT target, and the only
;; case where "current" differs from "first" is a node that has been
;; rewired.  A reader that took the first connect passes every graph
;; that is built once and never changed -- which is every graph in this
;; file until here -- and then quietly describes the old graph forever
;; after the first switch.  That is the shape this cell exists for.
(audio-mock-reset!)
(define r1 (make "createGain"))
(define r2 (make "createGain"))
(define r3 (make "createGain"))
(js-call (js-get r1 "connect") r1 r2)
(check "MOCK-GRAPH: a fresh node's target is what it was connected to"
       (equal? (audio-target-of (id r1)) (id r2)))
(js-call (js-get r1 "disconnect") r1)
(check "MOCK-GRAPH: after a bare disconnect it has no target"
       (not (audio-target-of (id r1))))
(js-call (js-get r1 "connect") r1 r3)
(check "MOCK-GRAPH: after a rewire the target is the NEW one, not the first"
       (equal? (audio-target-of (id r1)) (id r3)))
;; The cell above does NOT catch a reader that keeps the first
;; connect -- the disconnect before it clears the answer either way, so
;; "first after the disconnect" and "last" agree.  Measured: with the
;; reader mutated to keep the first, that cell stays green and the one
;; below reds.  A rewire with no disconnect is the discriminating shape,
;; and it is the shape a bus switch actually has when the library
;; reconnects without tearing down first.
(check "MOCK-GRAPH: a rewire with no disconnect also reads as the last connect"
       (begin (js-call (js-get r1 "connect") r1 r2)
              (equal? (audio-target-of (id r1)) (id r2))))
;; and the chain, including its refusal to loop
(js-call (js-get r2 "connect") r2 (js-get ctx "destination"))
(check "MOCK-GRAPH: a path runs to the destination and stops"
       (equal? (audio-path-kinds (id r1)) '("GAIN" "GAIN" "DEST")))
(js-call (js-get r2 "connect") r2 r1)   ; r1 -> r2 -> r1
(check "MOCK-GRAPH: a cycle is reported rather than hung on"
       (let ((p (audio-path-kinds (id r1))))
         (and (> (length p) 2)
              (string=? "runaway" (list-ref p (- (length p) 1))))))

;; ---- the graph outlives the log ----
;; The reader used to scan the log for edges, which made every path
;; assertion depend on where the section breaks fell: an edge recorded
;; once, when a node was born, vanished from the graph the moment a
;; later section called audio-mock-reset!.  Measured before the change:
;; inserting one harmless reset between two sections of test/audio.ss
;; turned "music takes the same path as an effect" red -- a red
;; pointing at the library while the instrument was what broke.
;;
;; So the edges live outside the log now.  This cell is the acceptance
;; criterion for that, and it is written as the thing that used to
;; happen: build a path, reset, and ask again.
(audio-mock-reset!)
(define s1 (make "createGain"))
(define s2 (make "createGain"))
(js-call (js-get s1 "connect") s1 s2)
(js-call (js-get s2 "connect") s2 (js-get ctx "destination"))
(check "MOCK-PERSIST: the path is there before the reset"
       (equal? (audio-path-kinds (id s1)) '("GAIN" "GAIN" "DEST")))
(audio-mock-reset!)
(check "MOCK-PERSIST: and it is still there after one"
       (equal? (audio-path-kinds (id s1)) '("GAIN" "GAIN" "DEST")))
(audio-mock-reset!)
(audio-mock-reset!)
(check "MOCK-PERSIST: and after several"
       (equal? (audio-path-kinds (id s1)) '("GAIN" "GAIN" "DEST")))
;; the log itself must still be cleared -- that is what reset is for,
;; and a fix that made reset stop clearing anything would pass the three
;; cells above and quietly break every count-from-zero in every file
(check "MOCK-PERSIST: while the log itself is still emptied"
       (= 0 (audio-log-length)))
;; a disconnect after a reset still takes the edge away: the structure
;; is live, not a snapshot taken when the log was last cleared
(js-call (js-get s1 "disconnect") s1)
(check "MOCK-PERSIST: and the surviving graph is live, not frozen"
       (equal? (audio-path-kinds (id s1)) '("GAIN")))
(display (= failed 0))
