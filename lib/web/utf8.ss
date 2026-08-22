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
;; ⚠ THIS IS FOR WRITERS.  A reader's acceptance surface is a wire
;; contract: (web json) and (web sexpr) both deliberately ACCEPT some
;; malformed input because the readers they are paired with -- in
;; igropyr, a separate repository -- accept it too, and tightening one
;; side alone means one side takes a document the other refuses.  If
;; you are about to wire this into a reader, that is a lockstep change:
;; confirm the counterpart first.  Refusing to EMIT malformed bytes has
;; no such counterpart, which is why the writers may use it freely.
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
               ((< b 245)
                (and (cont 1) (cont 2) (cont 3)
                     (let ((cp (+ (* (- b 240) 262144)
                                  (* (- (b2 1) 128) 4096)
                                  (* (- (b2 2) 128) 64)
                                  (- (b2 3) 128))))
                       (and (>= cp 65536) (<= cp 1114111)))
                     (loop (+ i 4))))
               (else #f)))))))
  )
