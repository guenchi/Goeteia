;; Is a byte string well-formed UTF-8?
;;
;; Goeteia strings are UTF-8 byte strings, so "is this text" and "is
;; this valid" are separate questions, and every codec that puts a
;; string on a wire has to ask the second one.  It lived inside
;; (web sexpr) until (web json) needed the same answer; copying it
;; would have made two implementations of one rule, and importing the
;; s-expression codec from the JSON codec would have dragged a whole
;; format into four consumers to reach twenty lines.  So it moved here,
;; unchanged.
;;
;; ⚠ WHERE THIS MAY BE USED, and where using it is a decision someone
;; else has to be part of.  Today:
;;
;;   (web sexpr) writer   uses it     refusing to emit is unilateral
;;   (web json)  writer   uses it     same
;;   (web sexpr) reader   USES IT     that codec's counterpart validates
;;                                    too, so the two acceptance surfaces
;;                                    still match -- it was a lockstep
;;                                    decision, not a local one
;;   (web json)  reader   does NOT    and must not start without one:
;;                                    the reader it is paired with, in
;;                                    igropyr, accepts malformed bytes
;;
;; So the rule is not "writers only" -- an earlier version of this note
;; said that, and it was already false about (web sexpr) when it was
;; written.  The rule is about WHO ELSE IS AFFECTED:
;;
;;   refusing to EMIT malformed bytes narrows what leaves, and nothing
;;   downstream can be broken by receiving less; it is unilateral.
;;   refusing to ACCEPT them narrows what a wire carries, and the peer
;;   on that wire may still send it -- that is a lockstep change, and
;;   the counterpart has to move with it.
;;
;; Wiring this into a reader is therefore allowed, and is a
;; conversation, not a commit.
;;
;; One predicate, deliberately.  No "lenient" variant belongs here: a
;; weaker sibling under a friendlier name is a wrong answer left where
;; the next person will reach for it first.
;;
;; This module imports nothing from (web ...) and must stay that way.
;; It is the bottom of the stack, and an out-edge would turn it back
;; into a node in the graph -- which is the thing moving it here was
;; meant to stop.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web utf8)
  (export utf8-well-formed?)
  (import (rnrs))

  (define (utf8-cont? b) (and (>= b 128) (< b 192)))
  (define (utf8-well-formed? s)
    (let ((n (string-length s)))
      (let loop ((i 0))
        (if (>= i n)
            #t
            (let ((b (char->integer (string-ref s i))))
              (define (cont k) (and (< (+ i k) n)
                                    (utf8-cont? (char->integer
                                                 (string-ref s (+ i k))))))
              (define (b2 k) (char->integer (string-ref s (+ i k))))
              (cond
               ((< b 128) (loop (+ i 1)))
               ((< b 194) #f)                      ; continuation or overlong
               ((< b 224) (and (cont 1) (loop (+ i 2))))
               ((< b 240)
                (and (cont 1) (cont 2)
                     ;; no overlong, no surrogate half
                     (let ((cp (+ (* (- b 224) 4096)
                                  (* (- (b2 1) 128) 64)
                                  (- (b2 2) 128))))
                       (and (>= cp 2048) (not (and (>= cp 55296) (< cp 57344)))))
                     (loop (+ i 3))))
               ;; 245 and the codepoint ceiling below SHADOW EACH OTHER.
               ;; For a lead byte of 245..247 the codepoint works out
               ;; above 1114111, so the ceiling refuses those sequences
               ;; even with this bound gone -- and the bound refuses
               ;; them even with the ceiling raised.
               ;;
               ;; What that means if you are here to change it: RELAX
               ;; THIS BOUND ALONE AND NO TEST WILL GO RED.  Measured,
               ;; both directions, one at a time and then together --
               ;; only the pair mutated at once turns
               ;; "0xF5..0xFF are never lead bytes" (test/sexpr-limits.ss)
               ;; red.  A green suite is not evidence that this line is
               ;; unused; it is evidence that the other one is still
               ;; there.
               ((< b 245)
                (and (cont 1) (cont 2) (cont 3)
                     (let ((cp (+ (* (- b 240) 262144)
                                  (* (- (b2 1) 128) 4096)
                                  (* (- (b2 2) 128) 64)
                                  (- (b2 3) 128))))
                       ;; the ceiling half of the pair described at
                       ;; the `(< b 245)` line above: RELAX 1114111
                       ;; ALONE AND NO TEST WILL GO RED either, because
                       ;; that bound still refuses every lead byte that
                       ;; could reach past it.  Both have to move
                       ;; before anything notices.
                       (and (>= cp 65536) (<= cp 1114111)))
                     (loop (+ i 4))))
               (else #f)))))))
  )
