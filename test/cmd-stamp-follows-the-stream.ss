;; expect: #t
;; A record about GPU state is believed only while the words that wrote
;; it are known to have reached GL (R40: archive/goeteia-r40-design-
;; 2026-11-09.md, 3.1-3.2; rows S1-S9b and S6a of section 4).
;;
;; (cmd-stamp) names the current SEGMENT of encoding -- from a
;; cmd-begin!, or from a completed flush, to the next completed flush,
;; cmd-begin! or stale event -- and is #f while the encoder is STALE (from
;; a cmd-region!, a full region, a gl-attach! or a replay that raises,
;; until the next cmd-begin!).  (cmd-stamp-holds? t) is true while t's
;; segment is the current one or a completed flush replayed it, and no
;; flush has run from a moved base since.  A flush while stale that
;; returns, not from a moved base, replays the segment the stale event
;; cut off -- its words are whole and lie in order from the stream's own
;; base -- and so makes it hold.  After gl-attach! the replay goes to
;; another replayer, and nothing is marked.
;;
;; Each row names the wrong implementation it rejects:
;;   S1  every cmd-begin! invalidates every record (EB, a cost)
;;   S1b a begin that drops any word invalidates every record (PBs)
;;   S2  a dropped segment's record still holds (NBs)
;;   S3  no stale on a region change (NSr); a cut-off segment never
;;       marked by a flush that runs it (NCut)
;;   S4  no stale on a full region (NSf); NCut -- the limit is set BEFORE
;;       the stream's cmd-begin!, since a region change inside it would
;;       make it stale by itself
;;   S5  the stream's program not reset at cmd-begin! (NR), or reset at
;;       a flush (NRF)
;;   S7  a segment marked replayed although its replay raised (NRp)
;;   S7b NRp; NCut, through a replay that raises once
;;   S7c the same for a flush while stale: a cut-off segment marked
;;       before the replay that raised
;;   S8  a completed flush that does not open a new segment (NF), in
;;       either form: the old, now replayed segment kept current, or the
;;       encoder left without one
;;   S9  no new era on a flush from a moved base (NE)
;;   S9c the new era taken only after that flush's replay returns: a
;;       replay from a moved base that raises must still invalidate
;;   S9b every flush while stale starts a new era (SE, a cost)
;;   S6a (last: the attach retires every slot made before it) no stale on
;;       an attach (NSa); an attach that cuts the current segment off the
;;       way the other stale events do (MCb)
;; S6b, an attach after a cut, is test/cmd-stamp-attach-after-a-cut.ss.
;;
;; ON THE TREE BEFORE THE CHANGE this cell does not compile: the stamp
;; procedures do not exist there.  That red reads nothing; the rows that
;; read the old tree are in test/cached-gpu-state-after-a-drop.ss.
(import (rnrs) (web js) (gfx gl) (gfx fx) (gfx mesh) (glstate))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
(define (try thunk) (guard (e (#t 'raised)) (thunk) 'returned))

(define canvas (glstate-canvas 64 64))
(fx-init! canvas)
(define wide 65536)
(define lit (fx-program! mesh-lit-vs mesh-lit-fs))
(define (mesh) (fx-mesh! (mesh-box 1.0 1.0 1.0)))
(define (use m) (fx-mesh-use! lit m))
(define (use+draw m) (fx-mesh-use! lit m) (fx-mesh-draw! m))
(define (holds? t) (cmd-stamp-holds? t))
(define (cell? t) (and t #t))

;; what a draw of a fully uploaded box reads, for comparisons
(define box-draw
  (let ((m (mesh)))
    (cmd-begin!) (use+draw m) (glstate-reset!) (cmd-flush!)
    (car (glstate-draws))))

;; S1: B, use (t), F, B, B
(let ((m (mesh)))
  (cmd-begin!) (use m)
  (let ((t (cmd-stamp)))
    (want "S1 a stamp taken inside a stream is a segment" (cell? t) #t)
    (cmd-flush!) (cmd-begin!) (cmd-begin!)
    (want "S1 a replayed record holds through two begins" (holds? t) #t)))

;; S1b: B, use (t), F, B, a word, B -- the second begin drops a word
(let ((m (mesh)))
  (cmd-begin!) (use m)
  (let ((t (cmd-stamp)))
    (cmd-flush!) (cmd-begin!) (cmd-viewport! 0 0 64 64) (cmd-begin!)
    (want "S1b a replayed record holds through a begin that drops an unrelated word"
          (holds? t) #t)))

;; S2: B, use (t), B (no flush); then F, B
(let ((m (mesh)))
  (cmd-begin!) (use m)
  (let ((t (cmd-stamp)))
    (cmd-begin!)
    (want "S2 a dropped segment's record does not hold" (holds? t) #f)
    (cmd-flush!)
    (want "S2 nor after a flush of the next stream" (holds? t) #f)
    (cmd-begin!)
    (want "S2 nor after another begin" (holds? t) #f)))

;; S3: B (t), cmd-region! with the same base and limit, F, B
(begin
  (cmd-begin!)
  (let ((t (cmd-stamp)))
    (cmd-region! 0 wide)
    (want "S3 no segment after a region change" (cmd-stamp) #f)
    (want "S3 the cut-off segment does not hold" (holds? t) #f)
    (cmd-flush!)
    (want "S3 a flush that runs the cut-off segment makes it hold" (holds? t) #t)
    (cmd-begin!)
    (want "S3 and it holds after the next begin" (holds? t) #t)
    (let ((t2 (cmd-stamp)))
      (want "S3 the next begin opens a new segment" (and (cell? t2) (not (eq? t2 t))) #t))))

;; S4: the limit at the end of one mesh's first use, set before B; the
;; second mesh's first word does not fit
(let* ((m1 (mesh)) (m2 (mesh))
       (limit (begin (cmd-region! 0 wide) (cmd-begin!) (use (mesh)) (cmd-pos))))
  (cmd-region! 0 limit)
  (cmd-begin!)
  (use m1)
  (want "S4 the first use fits the region exactly" (cmd-pos) limit)
  (let ((t (cmd-stamp)))
    (want "S4 the second use does not fit" (try (lambda () (use m2))) 'raised)
    (want "S4 no segment after a full region" (cmd-stamp) #f)
    (want "S4 the cut-off segment does not hold" (holds? t) #f)
    (cmd-flush!)
    (want "S4 a flush that runs the cut-off segment makes it hold" (holds? t) #t)
    (cmd-region! 0 wide)
    (cmd-begin!)
    (want "S4 and it holds after the next begin" (holds? t) #t)
    (glstate-reset!)
    (use+draw m1) (use+draw m2) (cmd-flush!)
    (want "S4 the next frame uploads the second mesh only"
          (map (lambda (u) (substring u 0 2)) (glstate-uploads)) '("AB" "EA"))
    (want "S4 and both draws read a whole box" (glstate-draws) (list box-draw box-draw))))

;; S5: the stream's program
(let ((s (fx-program-slot lit)))
  (cmd-begin!)
  (want "S5 no program after a begin" (cmd-stream-program) #f)
  (cmd-use-program! s)
  (want "S5 the program used" (cmd-stream-program) s)
  (cmd-flush!)
  (want "S5 kept across a flush" (cmd-stream-program) s)
  (cmd-begin!)
  (want "S5 reset by the next begin" (cmd-stream-program) #f))

;; S7: B, use (t), an upload whose replay raises; F under a JS try
(let ((m (mesh)) (b (fx-buffer!)))
  (cmd-begin!) (use m)
  (let ((t (cmd-stamp)))
    (cmd-bind-buffer! b)
    (cmd-buffer-data! 268435456 8)
    (want "S7 the replay raises" (glstate-attempt (lambda () (cmd-flush!)))
          "raised:RangeError")
    (want "S7 no segment after a replay that raised" (cmd-stamp) #f)
    (want "S7 the segment it was replaying does not hold" (holds? t) #f)
    (cmd-begin!)
    (want "S7 nor after the next begin" (holds? t) #f)))

;; S7b: a mock whose next upload throws, once: F (raises), F
(let ((m (mesh)))
  (cmd-begin!) (use m)
  (let ((t (cmd-stamp)))
    (glstate-fail-next-upload!)
    (want "S7b the first replay raises" (glstate-attempt (lambda () (cmd-flush!)))
          "raised:Error")
    (want "S7b the segment does not hold after it" (holds? t) #f)
    (glstate-reset!)
    (want "S7b the second replay returns" (glstate-attempt (lambda () (cmd-flush!))) "ok")
    (want "S7b it ran the whole segment" (length (glstate-uploads)) 2)
    (want "S7b and the segment holds after it" (holds? t) #t)))

;; S7c: B, use (t), a region change cutting it off, the next upload
;; throws: F while stale (raises), F while stale (returns)
(let ((m (mesh)))
  (cmd-begin!) (use m)
  (let ((t (cmd-stamp)))
    (cmd-region! 0 wide)
    (glstate-fail-next-upload!)
    (want "S7c the flush while stale raises" (glstate-attempt (lambda () (cmd-flush!)))
          "raised:Error")
    (want "S7c the cut-off segment does not hold after it" (holds? t) #f)
    (want "S7c the next flush while stale returns" (glstate-attempt (lambda () (cmd-flush!)))
          "ok")
    (want "S7c and the cut-off segment holds after it" (holds? t) #t)))

;; S8: B, use a (ta), F, use b (tb), B
(let ((a (mesh)) (b (mesh)))
  (cmd-begin!) (use a)
  (let ((ta (cmd-stamp)))
    (cmd-flush!)
    (let ((after (cmd-stamp)))
      (want "S8 a completed flush opens a new segment"
            (and (cell? after) (not (eq? after ta))) #t))
    (use b)
    (let ((tb (cmd-stamp)))
      (want "S8 a record of the open segment holds" (holds? tb) #t)
      (cmd-begin!)
      (want "S8 the flushed segment's record holds" (holds? ta) #t)
      (want "S8 the dropped segment's record does not" (holds? tb) #f)
      (glstate-reset!)
      (use+draw a) (use+draw b) (cmd-flush!)
      (want "S8 the next frame uploads b only"
            (map (lambda (u) (substring u 0 2)) (glstate-uploads)) '("AB" "EA"))
      (want "S8 and both draws read a whole box" (glstate-draws) (list box-draw box-draw)))))

;; S9: B, use (t), F; cmd-region! to a base equal to (cmd-pos); F;
;; region restored, B
(let ((m (mesh)))
  (cmd-begin!) (use m)
  (let ((t (cmd-stamp)))
    (cmd-flush!)
    (cmd-region! (cmd-pos) wide)
    (cmd-flush!)
    (want "S9 a flush from a moved base invalidates the record" (holds? t) #f)
    (cmd-region! 0 wide)
    (cmd-begin!)
    (want "S9 and it stays invalid after the next begin" (holds? t) #f)
    (glstate-reset!)
    (use+draw m) (cmd-flush!)
    (want "S9 the next frame uploads the mesh again" (length (glstate-uploads)) 2)))

;; S9c: a replayed record; in a later stream a whole command, then an
;; upload; the base moved to the boundary between them; the replay of
;; the upload raises
(let ((m (mesh)) (b (fx-buffer!)) (at (fx-alloc! 16)))
  (cmd-begin!) (use m)
  (let ((t (cmd-stamp)))
    (cmd-flush!)
    (cmd-begin!)
    (cmd-viewport! 0 0 64 64)
    (let ((boundary (cmd-pos)))
      (cmd-bind-buffer! b) (cmd-buffer-data! at 16)
      (cmd-region! boundary wide)
      (glstate-fail-next-upload!)
      (want "S9c the replay from the moved base raises"
            (glstate-attempt (lambda () (cmd-flush!))) "raised:Error")
      (want "S9c the record is invalid although the replay raised" (holds? t) #f)
      (cmd-region! 0 wide)
      (cmd-begin!)
      (want "S9c and it stays invalid after the next begin" (holds? t) #f))))

;; S9b: B, use (t), F; cmd-region! with the same base; F; B
(let ((m (mesh)))
  (cmd-begin!) (use m)
  (let ((t (cmd-stamp)))
    (cmd-flush!)
    (want "S9b holds after the flush" (holds? t) #t)
    (cmd-region! 0 wide)
    (want "S9b holds after a region change that keeps the base" (holds? t) #t)
    (cmd-flush!)
    (want "S9b holds after a flush while stale from the same base" (holds? t) #t)
    (cmd-begin!)
    (want "S9b holds after the next begin" (holds? t) #t)))

;; S6a, LAST: B (t), gl-attach! on the same canvas, F (an empty stream)
(begin
  (cmd-begin!)
  (let ((t (cmd-stamp)))
    (gl-attach! canvas)
    (want "S6a no segment after an attach" (cmd-stamp) #f)
    (want "S6a the segment open at the attach does not hold" (holds? t) #f)
    (want "S6a the flush returns" (glstate-attempt (lambda () (cmd-flush!))) "ok")
    (want "S6a nor does it hold after a flush" (holds? t) #f)))

(display (if (null? fails) #t (reverse fails)))
