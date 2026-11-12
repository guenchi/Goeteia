;; expect: #t
;; The WebGPU command encoder has a region, and a full region leaves the
;; stream at the end of its last whole command (R52: archive/goeteia-r52-
;; 2026-11-11.md; the (gfx gl) twin is test/gl-full-region-leaves-whole-
;; commands.ss).
;;
;; THE DEFECT.  (gfx gpu) wrote its words from address 0 with no limit and
;; compared the position with nothing; the replayer read from 0.  A frame
;; past 64 KiB wrote its commands over the staging fx-alloc! hands out
;; above it, and an upload of those bytes read command words when it was
;; replayed; with memory not yet grown, the encode trapped instead.
;;
;; THE RULE.  (gpu-region! base . limit) sets where the encoder writes and
;; an optional byte limit; gpu-begin! starts at the base; gpu-flush! and
;; gpu-bundle! hand the replayer the base and the word count.  Each
;; encoder records where its command begins before it writes its first
;; word; a word that does not fit puts the position back there and raises
;; a Scheme error, so the stream never holds part of a command.  (gpu-pos)
;; reads the position.
;;
;; RB.  Every command encoder (gfx gpu) exports, read from its export
;; list (each must write at least one word): an exported gpu- name that
;; is neither in the table below nor one of the procedures that encode
;; no command fails the row.  Each call is encoded right after one
;; complete preceding command (gpu-buffer-data!, whose upload shows in
;; the log), so it never starts where the previous command started.  For
;; EVERY i in 0..n-1, n being the call's word count, and for r in 0..3,
;; the limit leaves room for i of its words and r more bytes:
;;   (a) the overflow error is raised -- who gpu-region!, the message
;;       "command region overflow", the irritant where the word that did
;;       not fit would have gone; the position is where the call began; no
;;       byte at or past the limit was written; a flush replays the
;;       preceding command alone (call log equal);
;;   (b) the limit widened, the same call again, a flush: call for call
;;       what a control that never stopped replays.
;; (c) The control: a limit with room for exactly n words (and up to three
;;     bytes more).
;; REG.  At a base of 8192 the position starts at the base, nothing below
;;       it is written, and a flush replays what was encoded there.
;; BUN.  A bundle recorded at that base holds the draws encoded there, and
;;       the position is back at the base after it.
;; LIM.  A limit before its base is refused.
;; DEF.  Before any gpu-region!, there is no limit: 80,000 bytes of
;;       commands encode from 0.  And (gpu-region! 0), a base alone, after
;;       a region with a limit of 4096, removes that limit: the same 80,000
;;       bytes encode.
;;
;; Mock: test/lib/gpustate.ss, which logs every call.  ON THE TREE BEFORE
;; THE CHANGE this cell does not compile: gpu-region! and gpu-pos do not
;; exist there.  test/sgpu-init-sets-the-command-region.ss reads the old
;; tree.
(import (rnrs) (web js) (gfx fx) (gfx gpu) (gpustate))

(define fails '())
(define nfails 0)
(define (fail! . what)
  (set! nfails (+ nfails 1))
  (when (< (length fails) 12) (set! fails (cons what fails))))
;; 'returned, or what was raised: (who message irritants)
(define (try-call thunk)
  (guard (e (#t (if (error? e)
                     (list (condition-who e) (condition-message e) (condition-irritants e))
                     (list 'not-an-error e))))
    (thunk)
    'returned))
(define (overflow-at a) (list 'gpu-region! "command region overflow" (list a)))

(define ready #f)
(gpu-attach! (gpustate-canvas 64 64) (lambda () (set! ready #t)))
(unless ready (fail! 'setup "the mock device did not attach"))
;; the depth pyramid gpu-hzb! reduces into
(gpu-hzb-init! 10 64 64)
;; memory the unlimited rows below may write over, so they cannot trap
(define scratch (fx-alloc! 262144))

;; ---- DEF: no limit before any gpu-region!, nor with a base alone ----
(define (clears! k) (let loop ((j 0)) (when (< j k) (gpu-clear! 0.0 0.0 0.0 1.0) (loop (+ j 1)))))
(gpu-begin!)
(unless (= (gpu-pos) 0)
  (fail! 'DEF "with no region the position after gpu-begin! is not 0" (gpu-pos)))
(unless (eq? (try-call (lambda () (clears! 4000))) 'returned)
  (fail! 'DEF "with no region 80,000 bytes of commands raised"))
(gpu-region! 0 4096)
(gpu-begin!)
;; the clear at 4080 has room for four of its five words: the fifth,
;; at 4096, does not fit, and the position goes back to 4080
(unless (equal? (try-call (lambda () (clears! 4000))) (overflow-at 4096))
  (fail! 'DEF "a limit of 4096 did not stop the commands at the word at 4096"))
(unless (= (gpu-pos) 4080)
  (fail! 'DEF "the position after the error is not the start of the clear at 4080" (gpu-pos)))
(gpu-region! 0)
(gpu-begin!)
(unless (eq? (try-call (lambda () (clears! 4000))) 'returned)
  (fail! 'DEF "a base alone after a limited region kept the limit"))

;; staging the replayer reads in place
(define at (fx-alloc! 4096))
(let fill ((i 0))
  (when (< i 1024)
    (%mem-f32-set! (+ at (* 4 i)) (* 0.5 (fixnum->flonum i)))
    (fill (+ i 1))))
(define wide 65536)

;; name, then a thunk making one call
(define table
  (list
   (list 'gpu-clear! (lambda () (gpu-clear! 0.25 0.5 0.75 1.0)))
   (list 'gpu-use-pipeline! (lambda () (gpu-use-pipeline! 2)))
   (list 'gpu-bind-vbuf! (lambda () (gpu-bind-vbuf! 3)))
   (list 'gpu-buffer-data! (lambda () (gpu-buffer-data! 4 (+ at 64) 32)))
   (list 'gpu-draw! (lambda () (gpu-draw! 3)))
   (list 'gpu-set-group! (lambda () (gpu-set-group! 5)))
   (list 'gpu-bind-ibuf! (lambda () (gpu-bind-ibuf! 6)))
   (list 'gpu-draw-indexed! (lambda () (gpu-draw-indexed! 6)))
   (list 'gpu-dispatch! (lambda () (gpu-dispatch! 7 8 2)))
   (list 'gpu-bind-vbuf2! (lambda () (gpu-bind-vbuf2! 9)))
   (list 'gpu-draw-instanced! (lambda () (gpu-draw-instanced! 3 2)))
   (list 'gpu-end-pass! (lambda () (gpu-end-pass!)))
   (list 'gpu-hzb! (lambda () (gpu-hzb!)))
   (list 'gpu-draw-indexed-indirect! (lambda () (gpu-draw-indexed-indirect! 11 0)))
   (list 'gpu-draw-indirect! (lambda () (gpu-draw-indirect! 11 4)))
   (list 'gpu-execute! (lambda () (gpu-execute! 12)))))

;; ---- every exported command encoder of (gfx gpu) is in the table ----
(define not-encoders
  '(gpu-attach! gpu-pipeline! gpu-pipeline2! gpu-pipeline2-blend!
    gpu-buffer! gpu-index! gpu-uniforms! gpu-storage! gpu-indirect!
    gpu-compute-group*! gpu-hzb-init! gpu-compute-groupx!
    gpu-texture! gpu-texture-data! gpu-sampler! gpu-bindgroup! gpu-texgroup!
    gpu-compute! gpu-compute-group! gpu-begin! gpu-flush! gpu-bundle!
    gpu-gpu-timer! gpu-gpu-ms gpu-region! gpu-pos))
(define (prefix? p s)
  (and (>= (string-length s) (string-length p))
       (string=? (substring s 0 (string-length p)) p)))
;; (library (gfx gpu) (export name ...) (import ...) body ...)
(define exported
  (let* ((lib (call-with-input-file "lib/gfx/gpu.ss" read))
         (ex (caddr lib)))
    (unless (and (pair? ex) (eq? (car ex) 'export))
      (fail! 'listing "the third form of lib/gfx/gpu.ss is not its export list"))
    (filter (lambda (n) (and (symbol? n) (prefix? "gpu-" (symbol->string n))))
            (if (pair? ex) (cdr ex) '()))))
(define table-names (map car table))
(when (< (length exported) 40)
  (fail! 'listing "fewer gpu- exports read from lib/gfx/gpu.ss than exist" (length exported)))
(for-each (lambda (n)
            (unless (or (memq n table-names) (memq n not-encoders))
              (fail! 'listing "an exported command encoder is not in RB's table" n)))
          exported)
(for-each (lambda (n)
            (unless (memq n exported)
              (fail! 'listing "a table entry is not exported by (gfx gpu)" n)))
          table-names)

;; ---- RB ----
(define (preceding!) (gpu-buffer-data! 3 at 16))
(define (flush-log)
  (gpustate-reset!)
  (let ((r (gpustate-attempt (lambda () (gpu-flush!)))))
    (cons r (gpustate-calls))))

(define ref-preceding
  (begin (gpu-region! 0 wide) (gpu-begin!) (preceding!) (flush-log)))

(for-each
 (lambda (entry)
   (let ((name (car entry)) (call (cadr entry)))
     (gpu-region! 0 wide)
     (gpu-begin!)
     (preceding!)
     (let ((s (gpu-pos)))
       (call)
       (let* ((n (quotient (- (gpu-pos) s) 4))
              (ref (flush-log)))
         (unless (equal? (car ref) "ok")
           (fail! name 'control "the control's replay raised" (car ref)))
         (when (< n 1)
           (fail! name 'control "the encoder wrote no word"))
         ;; (c) room for exactly n words, and up to three bytes more
         (let fits ((r 0))
           (when (< r 4)
             (gpu-region! 0 (+ s (* 4 n) r))
             (gpu-begin!)
             (preceding!)
             (let ((x (try-call call)))
               (unless (and (eq? x 'returned) (= (gpu-pos) (+ s (* 4 n))))
                 (fail! name 'c r "a limit with room for all its words refused it" x (gpu-pos)))
               (unless (equal? (flush-log) ref)
                 (fail! name 'c r "the exact-fit replay differs from the control")))
             (fits (+ r 1))))
         ;; (a) and (b) for every i in 0..n-1 and r in 0..3
         (let each ((i 0))
           (when (< i n)
             (let bytes ((r 0))
               (when (< r 4)
                 (let ((word (+ s (* 4 i))))
                   (gpu-region! 0 (+ word r))
                   (gpu-begin!)
                   (preceding!)
                   ;; the word that will not fit, and what lies past the limit
                   (let mark ((b 0))
                     (when (< b 4) (%mem-u8-set! (+ word b) 165) (mark (+ b 1))))
                   (let ((x (try-call call)))
                     (unless (equal? x (overflow-at word))
                       (fail! name i r "not the overflow error for the word that did not fit" x))
                     (unless (= (gpu-pos) s)
                       (fail! name i r "the position after the error is not where the call began"
                              (gpu-pos) s))
                     (let past ((b r))
                       (when (< b 4)
                         (unless (= (%mem-u8-ref (+ word b)) 165)
                           (fail! name i r "a byte at or past the limit was written" (+ word b)))
                         (past (+ b 1))))
                     (unless (equal? (flush-log) ref-preceding)
                       (fail! name i r "the flush after the error is not the preceding command alone"))
                     (gpu-region! 0 wide)
                     (call)
                     (unless (equal? (flush-log) ref)
                       (fail! name i r "the replay after the call again differs from the control"))))
                 (bytes (+ r 1))))
             (each (+ i 1))))))))
 table)

;; ---- REG: a base above 0 ----
(define base 8192)
(define (stream!) (gpu-clear! 0.25 0.5 0.75 1.0) (preceding!) (gpu-draw! 3))
(define ref-stream
  (begin (gpu-region! 0 wide) (gpu-begin!) (stream!) (flush-log)))
(let loop ((i 0))
  (when (< i 16) (%mem-i32-set! (* 4 i) (+ 1000 i)) (loop (+ i 1))))
(gpu-region! base wide)
(gpu-begin!)
(unless (= (gpu-pos) base)
  (fail! 'REG "the position after gpu-begin! is not the base" (gpu-pos)))
(stream!)
(unless (= (gpu-pos) (+ base (* 4 11)))
  (fail! 'REG "the words were not written from the base" (gpu-pos)))
(let loop ((i 0))
  (when (< i 16)
    (unless (= (%mem-i32-ref (* 4 i)) (+ 1000 i))
      (fail! 'REG "a word below the base was written" (* 4 i)))
    (loop (+ i 1))))
(unless (equal? (flush-log) ref-stream)
  (fail! 'REG "the flush did not replay the words encoded at the base"))

;; ---- BUN: a bundle recorded at the base ----
(define (bundle-draws log)
  (filter (lambda (e) (and (prefix? "BE" e)
                           (let ((k (string-length ".draw(3)")))
                             (and (>= (string-length e) k)
                                  (string=? (substring e (- (string-length e) k)
                                                       (string-length e))
                                            ".draw(3)")))))
          log))
(gpu-region! base wide)
(gpu-begin!)
(gpu-use-pipeline! 2) (gpu-bind-vbuf! 3) (gpu-draw! 3)
(gpustate-reset!)
(let ((r (gpustate-attempt (lambda () (gpu-bundle! 13)))))
  (unless (equal? r "ok") (fail! 'BUN "recording the bundle raised" r))
  (unless (= (length (bundle-draws (gpustate-calls))) 1)
    (fail! 'BUN "the bundle does not hold the draw encoded at the base"
           (gpustate-calls))))
(unless (= (gpu-pos) base)
  (fail! 'BUN "the position after the bundle is not the base" (gpu-pos)))

;; ---- LIM: a limit before its base ----
(unless (equal? (try-call (lambda () (gpu-region! 4096 2048)))
                (list 'gpu-region! "limit precedes command base" (list 2048)))
  (fail! 'LIM "a limit before its base was not refused with its own error"))
(gpu-region! 0 wide)

(display (if (= nfails 0) #t (list nfails 'failures (reverse fails))))
