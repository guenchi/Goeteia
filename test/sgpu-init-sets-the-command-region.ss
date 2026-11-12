;; expect: #t
;; Under sgpu-init!, the WebGPU command words have a region of their own,
;; [0, 64 KiB), and a frame that does not fit raises before it writes
;; over anything (R52: archive/goeteia-r52-2026-11-11.md).
;;
;; THE DEFECT.  (gfx gpu) had no limit, and fx-alloc! hands out staging
;; from 64 KiB up -- the scene's env block, its instance packs and vertex
;; sources among it.  A frame past 64 KiB wrote its command words over
;; those bytes, and the uploads read them when replayed: measured, an
;; sgpu scene of 800 groups (about 11 + 25 words a group) drew with its
;; view-projection, frustum planes and light replaced by command words.
;;
;; THE RULE.  sgpu-init! sets (gpu-region! 0 65536), as fx-init! sets the
;; (gfx gl) region.  A word past it raises a Scheme error before it is
;; written.
;;
;; Rows:
;;   R0  the region is exactly [0, 64 KiB): 16,384 words of commands
;;       encode, and one word more raises the overflow error for the word
;;       at 65536
;;   R1  after sgpu-init!, 16,500 words of commands (more than 64 KiB):
;;       the encoding raises the overflow error, and no staged byte above
;;       64 KiB changes
;;   R2  the scene's own frame after it encodes and replays as before
;;
;; ON THE TREE BEFORE THE CHANGE R1 is red: nothing raises, and the
;; command words overwrite the scene's staging.  Mock:
;; test/lib/gpustate.ss.
(import (rnrs) (web js) (gfx fx) (gfx gpu) (gfx mat) (gfx sgpu) (gpustate))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))

(define canvas (gpustate-canvas 64 64))
(define ready #f)
(gpu-attach! canvas (lambda () (set! ready #t)))
(want "setup the mock device attached" ready #t)

(define sc
  (sgl-gpu
   (camera (@ (fov 0.9) (position 0.0 2.0 8.0) (look-at 0.0 0.0 0.0)))
   (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
   (mesh (@ (geometry (box 1 1 1)) (position -1.0 0.0 0.0) (color 1.0 0.0 0.0)))
   (mesh (@ (geometry (sphere 1.0 8 4)) (position 2.0 0.0 0.0)))))
(sgpu-init! sc canvas)
(define (frame!) (gpu-begin!) (gpu-clear! 0.0 0.0 0.0 1.0) (sgpu-draw! sc) (gpu-flush!))
(frame!)

;; a checksum of the staging the scene was handed: [64 KiB, the level)
(define level (fx-mark))
(define (staged-sum)
  (let loop ((a 65536) (h 0))
    (if (>= a level)
        h
        (loop (+ a 1) (mod (+ (* h 31) (%mem-u8-ref a)) 4294967296)))))
(want "setup the scene was handed staging above 64 KiB" (> level 65536) #t)

;; 'returned, or what was raised: (who message irritants)
(define (try-call thunk)
  (guard (e (#t (if (error? e)
                     (list (condition-who e) (condition-message e) (condition-irritants e))
                     (list 'not-an-error e))))
    (thunk)
    'returned))
(define (clears! k) (let loop ((j 0)) (when (< j k) (gpu-clear! 0.0 0.0 0.0 1.0) (loop (+ j 1)))))

;; R0: 3,276 clears and one 4-word upload command are 16,384 words
(want "R0 16,384 words of commands fit"
      (try-call (lambda () (gpu-begin!) (clears! 3276) (gpu-buffer-data! 1 65536 4)))
      'returned)
(want "R0 and one word more raises the overflow error for the word at 65536"
      (try-call (lambda () (gpu-end-pass!)))
      (list 'gpu-region! "command region overflow" (list 65536)))

;; R1: 3,300 clears of 5 words each -- 66,000 bytes from the base
(define before (staged-sum))
(want "R1 more than 64 KiB of commands raises the overflow error"
      (try-call (lambda () (gpu-begin!) (clears! 3300)))
      (list 'gpu-region! "command region overflow" (list 65536)))
(want "R1 and no staged byte above 64 KiB changed" (staged-sum) before)

;; R2: the scene's frame after it
(gpustate-reset!)
(want "R2 the scene's frame encodes and replays"
      (gpustate-attempt (lambda () (frame!))) "ok")
;; does s contain p?
(define (contains? s p)
  (let ((n (string-length s)) (k (string-length p)))
    (let scan ((i 0))
      (and (<= (+ i k) n)
           (or (string=? (substring s i (+ i k)) p) (scan (+ i 1)))))))
(want "R2 and draws"
      (> (length (filter (lambda (e) (contains? e ".drawIndexedIndirect("))
                         (gpustate-calls)))
         0)
      #t)

(display (if (null? fails) #t (reverse fails)))
