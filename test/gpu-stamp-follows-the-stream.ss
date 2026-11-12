;; expect: #t
;; (gfx gpu)'s stamps follow what the stream's words become (R40g:
;; archive/goeteia-r40g-design-2026-11-12.md, 3.1).
;;
;; THE RULE.  A STREAM runs from one gpu-begin! to the next; a SEGMENT
;; from a gpu-begin! or a completed flush to the next completed flush,
;; gpu-begin!, gpu-bundle! or stale event.  The encoder is STALE from a
;; gpu-region!, a full region, a gpu-attach! or a replay that raises,
;; until the next gpu-begin!.  (gpu-stamp) is the current segment's
;; cell, #f while stale.  (gpu-stamp-holds? s): s is of the current era,
;; and is the current segment or was replayed.  (gpu-stamp-replayed? s):
;; s is of the current era and a completed flush replayed it.  A cell
;; cut off by a stale event is marked replayed by a flush made while
;; stale from the same base; a flush from a moved base starts a new era,
;; and so does gpu-attach!.  A bundled segment is never replayed.
;;
;; THE INSTRUMENT.  test/lib/gpustate.ss as the device;
;; gpustate-fail-write! makes the next upload throw inside the replay.
;;
;; Rows:
;;   E1  a stamp of the current segment holds and is not replayed; after
;;       a completed flush it holds and is replayed; after the next
;;       gpu-begin! it still holds
;;   E2  a stamp of a segment dropped by gpu-begin! neither holds nor is
;;       replayed
;;   E3  cut off by a full region and not flushed: does not hold; cut
;;       off by a full region and flushed while stale from the same base:
;;       holds and is replayed
;;   E4  cut off by gpu-region! to another base, then flushed: does not
;;       hold, and a stamp replayed before it does not either (the era);
;;       gpu-region! to the same base, then flushed: holds
;;   E5  gpu-attach!: no stamp made before it holds
;;   E6  gpu-bundle!: a stamp of the bundled segment does not hold
;;   E7  while stale (gpu-stamp) is #f; #f and things that are not
;;       stamps answer #f from both predicates
;;   E8  replayed: #f for the current segment's stamp, #t once a
;;       completed flush ran it (E1); #f after E2's, E3's unflushed, E4's
;;       moved, E5's and E6's events
;;   X1  a replay that raises (an upload throws): the segment's stamp
;;       neither holds nor is replayed, and the encoder is stale
;;   (cells r2, from the pre-review)
;;   F1  after a completed flush the encoder has a NEW current segment:
;;       its stamp holds and is not replayed; encoding and flushing again
;;       without gpu-begin! makes it replayed
;;   F2  after a flush while stale the encoder is still stale: (gpu-stamp)
;;       is #f until the next gpu-begin!, and again after a second stale
;;       flush; after gpu-begin! a fresh stamp holds
;;   F3  a bundle call that raises (a non-draw word) changes nothing: the
;;       same current segment, holding, not replayed
;;   F4  a stale flush that raises does not mark the cut-off cell; a
;;       later stale flush from the same base that completes does
;;   L1  the moved base is a latch until gpu-begin!: a second gpu-region!
;;       to the new base, or a move away and back, then a flush: the
;;       older replayed stamp does not hold
;;
;; ON THE TREE BEFORE THE CHANGE this file does not compile: gpu-stamp,
;; gpu-stamp-holds? and gpu-stamp-replayed? are not exported.
(import (rnrs) (web js) (gfx gpu) (gpustate))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
(define (both s) (list (gpu-stamp-holds? s) (gpu-stamp-replayed? s)))

(define canvas (gpustate-canvas 64 64))
(gpu-attach! canvas (lambda () #t))
;; one buffer, so an upload has a destination
(gpu-buffer! 0 64)
(define DATA 8192)
;; one command of five words (20 bytes)
(define (word!) (gpu-clear! 0.0 0.0 0.0 1.0))
(define (overflow?) (guard (e (#t (and (error? e) (eq? (condition-who e) 'gpu-region!))))
                      (word!) #f))

;; E1
(gpu-region! 0 4096)
(gpu-begin!) (word!)
(define s1 (gpu-stamp))
(want "E1 the current segment's stamp is a stamp" (and s1 #t) #t)
(want "E1/E8 current segment: holds, not replayed" (both s1) '(#t #f))
(gpu-flush!)
(want "E1/E8 after a completed flush: holds, replayed" (both s1) '(#t #t))
(want "E1 after the flush the segment is a new one" (eq? (gpu-stamp) s1) #f)
(gpu-begin!)
(want "E1 after the next gpu-begin!: still holds" (both s1) '(#t #t))

;; E2
(gpu-begin!) (word!)
(define s2 (gpu-stamp))
(gpu-begin!)
(want "E2/E8 dropped by gpu-begin!" (both s2) '(#f #f))

;; E3
(gpu-region! 0 36)
(gpu-begin!) (word!)
(define s3 (gpu-stamp))
(want "setup E3 the second command overflows" (overflow?) #t)
(want "E3/E7 stale after a full region: no current stamp" (gpu-stamp) #f)
(want "E3/E8 cut off, not flushed" (both s3) '(#f #f))
(gpustate-reset!)
(gpu-flush!)
(want "setup E3 the stale flush ran a replay"
      (and (member "dev.createCommandEncoder()" (gpustate-calls)) #t) #t)
(want "E3 cut off, flushed while stale from the same base" (both s3) '(#t #t))
(gpu-region! 0 4096)

;; E4
(gpu-begin!) (word!)
(define s4old (gpu-stamp))
(gpu-flush!)
(gpu-begin!) (word!)
(define s4 (gpu-stamp))
(gpu-region! 4096 8192)
(gpu-flush!)
(want "E4/E8 cut off by a region at another base, flushed" (both s4) '(#f #f))
(want "E4 an older replayed stamp: a new era" (both s4old) '(#f #f))
(gpu-region! 0 4096)
(gpu-begin!) (word!)
(define s4same (gpu-stamp))
(gpu-region! 0 4096)
(gpu-flush!)
(want "E4 cut off by a region at the same base, flushed" (both s4same) '(#t #t))

;; E5
(gpu-begin!) (word!)
(define s5 (gpu-stamp))
(gpu-flush!)
(want "setup E5 replayed before the attach" (both s5) '(#t #t))
(gpu-attach! canvas (lambda () #t))
(gpu-buffer! 0 64)
(want "E5/E8 made before gpu-attach!" (both s5) '(#f #f))
(want "E5 stale after gpu-attach!" (gpu-stamp) #f)

;; E6: a bundle takes draw commands only
(gpu-region! 0 4096)
(gpu-begin!) (gpu-draw! 3)
(define s6 (gpu-stamp))
(want "setup E6 the bundle is made"
      (gpustate-attempt (lambda () (gpu-bundle! 1))) "ok")
(want "E6/E8 the bundled segment" (both s6) '(#f #f))

;; E7
(gpu-region! 0 4096)
(want "E7 stale after gpu-region!: no current stamp" (gpu-stamp) #f)
(want "E7 #f" (both #f) '(#f #f))
(want "E7 a symbol" (both 'stamp) '(#f #f))
(want "E7 a vector" (both (vector 1 2 3 4)) '(#f #f))
(want "E7 a list" (both '(1 2 3 4)) '(#f #f))

;; F1
(gpu-region! 0 4096)
(gpu-begin!) (word!)
(gpu-flush!)
(define f1 (gpu-stamp))
(want "F1 after a completed flush: a new current segment, holding, not replayed" (both f1) '(#t #f))
(word!)
(gpu-flush!)
(want "F1 encoded and flushed again without gpu-begin!: replayed" (both f1) '(#t #t))

;; F2
(gpu-region! 0 36)
(gpu-begin!) (word!)
(define f2 (gpu-stamp))
(want "setup F2 the second command overflows" (overflow?) #t)
(gpu-flush!)
(want "F2 a stale flush leaves the encoder stale" (gpu-stamp) #f)
(want "F2 the cut-off cell is replayed" (both f2) '(#t #t))
(gpu-flush!)
(want "F2 a second stale flush: still stale" (gpu-stamp) #f)
(gpu-region! 0 4096)
(gpu-begin!) (word!)
(want "F2 after gpu-begin! a fresh stamp holds" (both (gpu-stamp)) '(#t #f))

;; F3: the bundle decoder refuses a clear
(gpu-begin!) (word!)
(define f3 (gpu-stamp))
(want "setup F3 the bundle call raises" (gpustate-attempt (lambda () (gpu-bundle! 2))) "raised:Error")
(want "F3 a raising bundle: the same current segment" (eq? (gpu-stamp) f3) #t)
(want "F3 a raising bundle: holding, not replayed" (both f3) '(#t #f))

;; F4: an upload in the cut-off prefix (16 bytes), the stale flush made
;; to raise; the clear after it (20 bytes) does not fit in 32
(gpu-region! 0 32)
(gpu-begin!)
(%mem-i32-set! DATA 9)
(gpu-buffer-data! 0 DATA 16)
(define f4 (gpu-stamp))
(want "setup F4 the next command overflows" (overflow?) #t)
(gpustate-fail-write! 1)
(want "setup F4 the stale flush raises" (gpustate-attempt (lambda () (gpu-flush!))) "raised:Error")
(want "F4 a raising stale flush does not mark the cut-off cell" (both f4) '(#f #f))
(gpu-flush!)
(want "F4 a completed stale flush from the same base marks it" (both f4) '(#t #t))
(gpu-region! 0 4096)

;; L1
(define (latch-case moves)
  (gpu-region! 0 4096)
  (gpu-begin!) (word!)
  (let ((old (gpu-stamp)))
    (gpu-flush!)
    (for-each (lambda (b) (gpu-region! b (+ b 4096))) moves)
    (gpu-flush!)
    (both old)))
(want "L1 two gpu-region! calls to the new base, then a flush" (latch-case '(4096 4096)) '(#f #f))
(want "L1 a move away and back, then a flush" (latch-case '(4096 0)) '(#f #f))
(gpu-region! 0 4096)

;; X1
(gpu-begin!)
(%mem-i32-set! DATA 7)
(gpu-buffer-data! 0 DATA 16)
(define sx (gpu-stamp))
(gpustate-fail-write! 1)
(want "setup X1 the replay raises" (gpustate-attempt (lambda () (gpu-flush!))) "raised:Error")
(want "X1 the raising replay's segment" (both sx) '(#f #f))
(want "X1 stale after a raising replay" (gpu-stamp) #f)

(display (if (null? fails) #t (reverse fails)))
