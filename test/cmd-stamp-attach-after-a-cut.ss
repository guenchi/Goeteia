;; expect: #t
;; An attach forgets the segment a stale event cut off (R40: archive/
;; goeteia-r40-design-2026-11-09.md, 3.1 "Why `$cut`"; row S6b of
;; section 4).
;;
;; A flush while stale that returns makes the cut-off segment hold: it
;; ran that segment's words, whole and from the stream's own base.  After
;; gl-attach! the replay goes to ANOTHER replayer, whose slots name other
;; objects, so the words it runs establish nothing the records describe.
;; So gl-attach! clears the cut-off segment; a flush after it marks
;; nothing.
;;
;; S6b: B (t), cmd-region! with the same base (t is cut off), gl-attach!
;; on the same canvas, F (the stream is empty; it returns).  t does not
;; hold after F.  It rejects an attach that keeps the cut-off segment
;; (MCa).  test/cmd-stamp-follows-the-stream.ss row S6a cannot: there
;; the attach comes right after a cmd-begin!, which clears the cut-off
;; segment by itself.
;;
;; The attach retires every slot made before it, so the row is alone in
;; its file.  ON THE TREE BEFORE THE CHANGE this cell does not compile:
;; the stamp procedures do not exist there.
(import (rnrs) (web js) (gfx gl) (gfx fx) (glstate))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))

(define canvas (glstate-canvas 64 64))
(fx-init! canvas)

(cmd-begin!)
(let ((t (cmd-stamp)))
  (want "S6b a stamp taken after a begin is a segment" (and t #t) #t)
  (cmd-region! 0 65536)
  (want "S6b the region change cuts it off" (cmd-stamp-holds? t) #f)
  (gl-attach! canvas)
  (want "S6b the flush after the attach returns"
        (glstate-attempt (lambda () (cmd-flush!))) "ok")
  (want "S6b the segment cut off before the attach does not hold" (cmd-stamp-holds? t) #f))

(display (if (null? fails) #t (reverse fails)))
