;; expect: #t
;; (aud mix): the half of the audio work that can be judged.
;;
;; These two are pure on purpose.  A panning law and an eviction policy
;; are arithmetic, and arithmetic is the one part of audio this tree can
;; check without a sound card, a browser, or a mock: both compiler
;; targets run these cells and must agree.  Everything else about sound
;; here -- that the nodes are wired up, that the platform's semantics
;; are what we think, that it sounds right -- is judged elsewhere or not
;; at all, and is written down as such in archive/goeteia-audio-design.md.
;;
;; They live in (aud mix) rather than (aud sfx) for the same reason:
;; reaching them through (aud sfx) would drag (web js) into a test of
;; two functions that touch no JS at all, which would undo at the import
;; level the very split this batch exists to make.
;;
;; Each cell names the plausible-but-wrong implementation it excludes.
;; A cell that only rules out an obviously broken version gives the same
;; green as no cell at all.
(import (rnrs) (aud mix))

;; The tolerance is 1e-9, and it is a derived number rather than a
;; number that made the cells pass.  It is bounded on both sides:
;;
;;   below -- the prelude's sin is a polynomial approximation.  Set to
;;            1e-11 and PAN-POWER goes red on all three targets, with
;;            full-precision anchors, so the floor is the library's
;;            trigonometry and not this file's literals -- that was
;;            checked, because a reason that names the wrong cause is
;;            worse than no reason at all;
;;   above -- Web Audio's gain.value is a 32-bit float, relative
;;            precision about 1.2e-7.  An error smaller than that is
;;            erased by the platform before it reaches a sample.
;;
;; 1e-9 sits between the arithmetic noise floor and the smallest
;; difference the platform can represent.  It cannot be loosened -- past
;; 1.2e-7 the error is one the hardware would keep -- and it cannot be
;; tightened without failing on this tree's own trigonometry.  Both
;; bounds have to be re-derived before this number is touched.
;;
;; This is the only place the number is written.  The reasoning is also
;; in archive/goeteia-audio-design.md; the value is not, because two
;; files holding the same constant is two suppliers of one fact.
;;
;; And the fix this rules out: pan = ±1 must NOT be special-cased in
;; the library to return exactly (1, 0).  That would hide a general
;; imprecision by making two points of the range pretend to be exact.
(define (near? a b)
  (and (fl<? (fl- a b) 0.000000001) (fl<? (fl- b a) 0.000000001)))
(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))
(define (refuses? thunk)
  (guard (e ((error? e) #t) (else #f)) (begin (thunk) #f)))
(define (L p) (car (pan-gains p)))
(define (R p) (cdr (pan-gains p)))

;; ---- pan-gains ----
;; PAN-ENDS -- excludes left and right swapped
(check "PAN-ENDS: hard left is all left"  (and (near? (L -1.0) 1.0) (near? (R -1.0) 0.0)))
(check "PAN-ENDS: hard right is all right" (and (near? (L 1.0) 0.0) (near? (R 1.0) 1.0)))
;; PAN-CENTRE -- excludes a law with a bias
(check "PAN-CENTRE: centre is even" (near? (L 0.0) (R 0.0)))
;; PAN-POWER -- excludes an unnormalised linear law
(check "PAN-POWER: the squares sum to one, everywhere"
       (let loop ((i -10))
         (or (> i 10)
             (let* ((p (fl/ (fixnum->flonum i) 10.0))
                    (l (L p)) (r (R p)))
               (and (near? (fl+ (fl* l l) (fl* r r)) 1.0) (loop (+ i 1)))))))
;; PAN-ANCHOR -- the reason this section exists.  A NORMALISED linear law
;; passes ENDS, CENTRE, POWER and MONOTONIC; it parts company only here.
(check "PAN-ANCHOR: half right is equal-power, not linear"
       (and (near? (L 0.5) 0.38268343236508977) (near? (R 0.5) 0.9238795325112867)))
(check "PAN-ANCHOR: and its mirror"
       (and (near? (L -0.5) 0.9238795325112867) (near? (R -0.5) 0.38268343236508977)))
;; PAN-MONOTONIC -- excludes a curve that wobbles
(check "PAN-MONOTONIC: right rises and left falls across the range"
       (let loop ((i -10))
         (or (>= i 10)
             (let* ((p (fl/ (fixnum->flonum i) 10.0))
                    (q (fl/ (fixnum->flonum (+ i 1)) 10.0)))
               (and (fl<? (R p) (R q)) (fl<? (L q) (L p)) (loop (+ i 1)))))))
;; PAN-RANGE -- excludes silent clamping
(check "PAN-RANGE: past the ends is refused, not clamped"
       (and (refuses? (lambda () (pan-gains 1.5)))
            (refuses? (lambda () (pan-gains -1.5)))))

;; ---- voice-evict ----
;; a voice is #(id start-time priority kind); kind is 'sfx or 'loop
(define (v id t p k) (vector id t p k))
(define (ev voices cap k pri kind) (voice-evict voices cap k pri kind))

;; EVICT-ROOM -- excludes an implementation that always evicts
(check "EVICT-ROOM: room in the general slots means nobody leaves"
       (eq? #f (ev (vector (v 'a 0.0 1 'sfx)) 8 2 1 'sfx)))
;; EVICT-ONE -- excludes evicting several at once
(check "EVICT-ONE: a full pool names exactly one victim"
       (let ((r (ev (vector (v 'a 0.0 1 'sfx) (v 'b 1.0 1 'sfx)) 2 0 5 'sfx)))
         (and (symbol? r) (memq r '(a b)) #t)))
;; EVICT-OLDEST -- excludes taking the newest
(check "EVICT-OLDEST: same priority, the earliest goes"
       (eq? 'a (ev (vector (v 'a 0.0 1 'sfx) (v 'b 1.0 1 'sfx)) 2 0 5 'sfx)))
;; EVICT-PRIORITY -- excludes FIFO
(check "EVICT-PRIORITY: a low-priority NEW voice loses to a high-priority OLD one"
       (eq? 'b (ev (vector (v 'a 0.0 9 'sfx) (v 'b 5.0 1 'sfx)) 2 0 5 'sfx)))
;; EVICT-REJECT -- excludes "always evict the weakest resident", which
;; passes every other cell and only shows itself when the newcomer is
;; less important than anyone already sounding
(check "EVICT-REJECT: a candidate weaker than everyone is refused, not admitted"
       (eq? 'reject (ev (vector (v 'a 0.0 5 'sfx) (v 'b 1.0 5 'sfx)) 2 0 1 'sfx)))
;; EVICT-MEMBERSHIP -- excludes returning an id that was never there
(check "EVICT-MEMBERSHIP: the victim came out of the pool"
       (let ((r (ev (vector (v 'a 0.0 1 'sfx) (v 'b 1.0 1 'sfx)) 2 0 5 'sfx)))
         (and (memq r '(a b)) #t)))
;; EVICT-TIE -- excludes anything that depends on traversal order
(check "EVICT-TIE: priority AND time both equal, the first listed goes, repeatably"
       (let* ((pool (vector (v 'a 3.0 4 'sfx) (v 'b 3.0 4 'sfx)))
              (r1 (ev pool 2 0 9 'sfx))
              (r2 (ev pool 2 0 9 'sfx)))
         (and (eq? r1 'a) (eq? r2 'a))))
;; EVICT-ALL-LOOPS -- excludes "loops have the highest priority", which
;; degenerates to taking the earliest, and the earliest is the music
(check "EVICT-ALL-LOOPS: a full pool of loops answers 'reserved, not a victim"
       (eq? 'reserved (ev (vector (v 'm 0.0 1 'loop) (v 'n 1.0 1 'loop)) 2 1 9 'sfx)))
;; EVICT-RESERVE -- excludes "admit whenever the pool is not full",
;; which passes ROOM and ALL-LOOPS and shows itself only when the free
;; slot is a reserved one: the combat sound takes the music's place.
;;
;; The expected answer here was 'reserved and it was wrong.  The reserve
;; bounds the NUMBER of sfx (#sfx <= general); a replacement leaves that
;; number where it was, so it cannot violate the bound, and refusing it
;; enforces something the reserve is not for -- a louder sound losing to
;; a quieter one already playing, exactly when the pool is small.
;;
;; What did NOT change is why the cell is here.  A falsified
;; expectation is a reason to correct the expectation, not to delete the
;; row: with the row gone, nothing in the file would say the reserve is
;; enforced at all, and the list would look tidier for it.  The question
;; to answer before removing any cell is "what excludes the mistake this
;; one excluded?", and here the answer is "this cell, with a different
;; answer".
;;
;; A free slot exists (n=2, cap=3) and it is the reserved one, so the
;; sfx count must not grow into it -- the reserve shows up as an
;; EVICTION rather than a refusal.  Both lines are needed: with only
;; the first, "always evict the weakest resident" also passes.
(let ((two-sfx (vector (v 'a 0.0 1 'sfx) (v 'b 1.0 4 'sfx))))
  (check "EVICT-RESERVE: with a free reserved slot a stronger sfx replaces, and does not add"
         (eq? 'a (ev two-sfx 3 1 9 'sfx)))
  (check "EVICT-RESERVE: and a weaker one is rejected rather than given the free slot"
         (eq? 'reject (ev two-sfx 3 1 0 'sfx))))
;; EVICT-K-ABSOLUTE -- excludes writing k as a proportion.
;; The pool has to sit where the two answers differ, and a small one
;; does not: with cap 8 and k 2, a quarter of 8 is also 2.  At cap 64 an
;; absolute k of 2 leaves 62 general slots while a quarter would leave
;; 48, so fifty sounding effects is room under one reading and a full
;; house under the other.  A first draft of this cell used two sfx in a
;; pool of 8 and then of 64: both readings answer #f to that, so it
;; excluded nothing.
(check "EVICT-K-ABSOLUTE: k does not scale with cap"
       (let ((pool (let build ((i 0) (out '()))
                     (if (= i 50)
                         (list->vector out)
                         (build (+ i 1)
                                (cons (v (string->symbol
                                          (string-append "s" (number->string i)))
                                         (fixnum->flonum i) 1 'sfx)
                                      out))))))
         (eq? #f (ev pool 64 2 9 'sfx))))
;; EVICT-LOOP-OVERFLOW -- excludes treating k as a ceiling on loops
(check "EVICT-LOOP-OVERFLOW: a loop may take a general slot"
       (eq? #f (ev (vector (v 'm 0.0 1 'loop) (v 'n 1.0 1 'loop)) 8 1 1 'loop)))
(check "EVICT-LOOP-OVERFLOW: and the sfx that follows is told why"
       (eq? 'reserved (ev (vector (v 'm 0.0 1 'loop) (v 'n 1.0 1 'loop)) 2 1 9 'sfx)))
;; EVICT-REFUSE -- excludes silent tolerance
(check "EVICT-REFUSE: a cap of zero or less is refused"
       (and (refuses? (lambda () (ev (vector) 0 0 1 'sfx)))
            (refuses? (lambda () (ev (vector) -1 0 1 'sfx)))))
(check "EVICT-REFUSE: a cap not greater than k is refused -- such a pool can never sound an sfx"
       (refuses? (lambda () (ev (vector) 4 4 1 'sfx))))
(check "EVICT-REFUSE: an unknown kind is refused"
       (refuses? (lambda () (ev (vector) 8 2 1 'music))))
;; EVICT-EXACT-PRIORITY -- excludes coercing one side of a comparison.
;;
;; The candidate's priority was coerced to a flonum and the residents'
;; were not, so `fl<?` met an exact integer and threw `illegal cast`.
;; The shape is worth naming, because it is the second time this batch
;; has met it: A and B are compared, the treatment is written for A
;; only, and the missing half is invisible whenever callers happen to
;; pass the same type on both sides.  It is also invisible whenever the
;; pool is not full -- there is nothing to compare until then -- so a
;; test that never fills a pool, and a test whose voices are all
;; flonums, both stay green while the field throws.
;;
;; Not merely "does not throw": the answer must be the SAME answer the
;; flonum spelling gives.  A coercion that treated an exact number as
;; weakest survives an assertion that only asks for the absence of a
;; trap -- and is caught below by the pair that crosses the type
;; boundary in both directions.
;;
;; A trap here cannot be turned into a named FAIL.  `illegal cast` is a
;; wasm trap and not a Scheme condition: a `(guard (e (#t ...)))` round
;; the call was written, run, and did not catch it, on either backend
;; (the JS target's `expected flonum` escaped the same guard).  So the
;; red these cells produce is one line of trap text with no cell name.
;; Whoever meets that line in this file should read this block.
;;
;; It also answers a question the design asked: a library cannot defend
;; against this by catching it.  The choices are to coerce before
;; comparing, or to test the type and refuse by name -- there is no
;; third one where the trap is absorbed.
;;
;; Measured, not argued: with the priority half coerced and the
;; start-time half left raw, every cell above this comment stays green,
;; and the age cell below is the only thing in the tree that reds.
(let ((flo (vector (v 'a 0.0 2.0 'sfx) (v 'b 1.0 3.0 'sfx)))
      (exa (vector (v 'a 0 2 'sfx)     (v 'b 1 3 'sfx))))
  (check "EVICT-EXACT-PRIORITY: exact priorities give the flonum answer"
         (eq? (ev flo 2 0 5.0 'sfx) (ev exa 2 0 5.0 'sfx)))
  (check "EVICT-EXACT-PRIORITY: and the answer is the weakest, not merely some id"
         (eq? 'a (ev exa 2 0 5.0 'sfx)))
  ;; the comparison has to cross the type boundary in BOTH directions
  (check "EVICT-EXACT-PRIORITY: an exact resident beats a fractional candidate"
         (eq? 'reject (ev (vector (v 'a 0 2 'sfx)) 1 0 1.5 'sfx)))
  (check "EVICT-EXACT-PRIORITY: and loses to one just above it"
         (eq? 'a (ev (vector (v 'a 0 1 'sfx)) 1 0 1.5 'sfx)))
  ;; start-time is the same field a second time: it is also compared,
  ;; and a fix that coerced only priority passes every cell above and
  ;; fails here.  The tie is broken by age, so age must be comparable.
  (check "EVICT-EXACT-PRIORITY: exact start times still break a tie by age"
         (eq? 'a (ev (vector (v 'b 7 4 'sfx) (v 'a 3 4 'sfx)) 2 0 9.0 'sfx)))
  ;; voice-weakest reads the same two fields through the same accessors
  (check "EVICT-EXACT-PRIORITY: voice-weakest answers for exact tuples too"
         (eq? 'a (voice-weakest exa))))
(display (= failed 0))
