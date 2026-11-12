;; expect: #t
;; (gfx sgpu)'s cached GPU state survives only what the replays did
;; (R40g: archive/goeteia-r40g-design-2026-11-12.md, 1.2 and 3.3).
;;
;; THE DEFECT.  Three records were believed whether or not the words
;; that establish them ran:
;;   I  an instance group's generation (group slot 10): the upload was
;;      skipped while the generation was unchanged, even when the frame
;;      that uploaded was dropped (gpu-begin!), cut off by a full region,
;;      or followed by sgpu-init! again (new, empty buffers);
;;   H  "the hi-Z pyramid is built": set when the reduction was encoded,
;;      so a dropped first frame, or two draws before the first flush,
;;      gave a cull against a pyramid nothing had reduced;
;;   R  the scene's ready flag: a re-init that raised part way left it
;;      true over half-replaced resources, and the scene drew with
;;      geometry never uploaded.
;;
;; THE RULE (3.3).  I: skip only while the generation is unchanged AND
;; the instance stamp (slot 16, taken after the upload's words) holds;
;; clear the stamp before storing a new generation (R0b).  H: occlusion
;; (env mode 1) only when a REPLAYED reduction exists this era
;; (gpu-stamp-replayed? of the newest reduction stamp or of the newest
;; one known replayed).  R: sgpu-init! clears ready, the instance stamps
;; and the H records first, and sets ready after its last geometry
;; flush returns.
;;
;; THE INSTRUMENT.  test/lib/gpustate.ss: every writeBuffer logs what it
;; read at replay as queue.read(<bytes>#<hash>); the env block is the
;; 224-byte read, an instance upload 128 bytes per node, the argument
;; reset 20.  gpustate-fail-write! makes the n-th upload from now throw.
;; The env block of a first frame (mode 0) and of a second (mode 1) are
;; read from a fresh scene below; every scene here has the same camera,
;; light and canvas, so their env blocks differ in the mode only.
;;
;; Rows (base = the tree before the change):
;;   I1  first frame dropped, next flushed: it uploads the instances
;;       (base: no instance upload, ever)
;;   I2  a first frame that overflows after its instance upload was
;;       encoded, caught; the next frame uploads (base: none)
;;   I3  the same overflow, and the cut-off frame flushed anyway: the
;;       next frame does NOT upload (green on base; a design that ignores
;;       the cut-off cell's replay re-uploads)
;;   I5  from a completed upload, a node moves, and the frame overflows
;;       at the replacement upload -- at its first word, and at an
;;       operand word; the next frame, with no further move, uploads the
;;       moved instances (base: none)
;;   I6  the same overflow at an operand word, and the cut-off frame
;;       flushed anyway (it replays up to the upload's start): the next
;;       frame still uploads the moved instances (R0a: the stamp is taken
;;       after the upload's words, so a stamp of words that never fit is
;;       never stored; base: none)
;;   I4  gpu-attach! and sgpu-init! again on the same scene, and
;;       sgpu-init! again without an attach: the next frame uploads
;;       (base: none)
;;   CI  two flushed frames of a steady scene: the instances are uploaded
;;       in the first only (green on base)
;;   H1  first frame dropped, next flushed: its env is mode 0 (base: 1)
;;   H2  a fresh scene drawn twice before its first flush: both env
;;       uploads are mode 0 (base: both 1)
;;   CH  two flushed frames: the second's env is mode 1; with
;;       sgpu-occlusion! off, mode 0 (green on base)
;;   CH2 a steady scene drawn twice per flush for two flushes: every env
;;       upload is mode 1 (green on base)
;;   H3  after a replayed reduction, a frame dropped, then a frame
;;       flushed: mode 1 (green on base)
;;   R3  two flushed frames, then sgpu-init! again on the same device: the
;;       next frame's env is mode 0, the one after mode 1 (green on base)
;;   R1  sgpu-init! again with the first geometry upload failing: the next
;;       frame draws nothing and uploads nothing (base: it draws); a
;;       completed sgpu-init! after it uploads the geometry, and the frame
;;       after that draws and uploads the instances
;;   R1b the same with two geometry groups, the failure on the second
;;       group's first upload (base: it draws)
;;   (cells r2, from the pre-review)
;;   MODES every env row also asserts the occlusion mode itself (the u32
;;       at offset 212 of the 224-byte read), not only a hash compared
;;       with the tree's own frames
;;   H4  a fresh scene's first frame overflows AT the reduction word and
;;       the cut-off frame is flushed anyway: the next frame is mode 0 (no
;;       reduction ran); the same after one replayed frame: mode 1
;;   CH3 a steady scene drawn three times in one flush: every env is mode
;;       1 (a promotion of an unreplayed stamp turns the third to 0)
;;   I7  a fresh scene drawn twice before its first flush uploads its
;;       instances once (the first upload holds in the current segment);
;;       with a move between the two draws, twice
;;   LAYOUT the positions the overflow rows use are found in the stream
;;       (the instance upload: opcode 4 with 128 bytes; the reduction:
;;       opcode 16 last), and each overflow row asserts where the cursor
;;       rolled back to
(import (rnrs) (web js) (web reactive) (gfx fx) (gfx gpu) (gfx mat) (gfx sgpu)
        (gpustate))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))

(define canvas (gpustate-canvas 64 64))
(gpu-attach! canvas (lambda () #t))
;; every env upload also logs its occlusion mode (env + 212)
(gpustate-watch-u32! 224 212)

(define (scene s)
  (sgl-gpu (camera (@ (fov 0.9) (position 0.0 2.0 8.0) (look-at 0.0 0.0 0.0)))
           (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
           (group (@ (rotation-y ,(signal-ref s)))
             (mesh (@ (geometry (box 1 1 1)) (position -1.0 0.0 0.0) (color 1.0 0.0 0.0))))))
(define (scene2 s)
  (sgl-gpu (camera (@ (fov 0.9) (position 0.0 2.0 8.0) (look-at 0.0 0.0 0.0)))
           (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
           (group (@ (rotation-y ,(signal-ref s)))
             (mesh (@ (geometry (box 1 1 1)) (position -1.0 0.0 0.0) (color 1.0 0.0 0.0))))
           (mesh (@ (geometry (sphere 1.0 8 4)) (position 2.0 0.0 0.0)))))
(define (fresh) (let ((sc (scene (signal 0.0)))) (sgpu-init! sc canvas) sc))

(define (prefix? p s)
  (and (>= (string-length s) (string-length p))
       (string=? (substring s 0 (string-length p)) p)))
;; the uploads since the last reset, as "<bytes>#<hash>"
(define (reads)
  (map (lambda (c) (substring c 11 (- (string-length c) 1)))
       (filter (lambda (c) (prefix? "queue.read(" c)) (gpustate-calls))))
(define (size r) (let loop ((i 0)) (if (char=? (string-ref r i) #\#) (substring r 0 i) (loop (+ i 1)))))
(define (sizes) (map size (reads)))
(define (envs) (filter (lambda (r) (string=? (size r) "224")) (reads)))
(define (insts) (filter (lambda (r) (string=? (size r) "128")) (reads)))
(define (modes)
  (map (lambda (c) (string->number (substring c 10 (- (string-length c) 1))))
       (filter (lambda (c) (prefix? "queue.u32(" c)) (gpustate-calls))))
(define (draws) (length (filter (lambda (c) (prefix? "RPass.drawIndexedIndirect" c)) (gpustate-calls))))

(define (begin+draw! sc) (gpu-begin!) (gpu-clear! 0.0 0.0 0.0 1.0) (sgpu-draw! sc))
(define (frame! sc) (begin+draw! sc) (gpu-flush!))
;; a frame, its log alone
(define (frame-log! sc) (gpustate-reset!) (frame! sc))
;; a frame whose words stop at limit: (overflowed? . where the cursor
;; rolled back to)
(define (overflowing-frame! sc limit)
  (gpu-region! 0 limit)
  (let* ((r (guard (e (#t (and (error? e) (eq? (condition-who e) 'gpu-region!))))
              (begin+draw! sc) #f))
         (at (gpu-pos)))
    (gpu-region! 0 65536)
    (cons r at)))

;; ---- references: a fresh scene's first and second frames ----
(define a (fresh))
(frame-log! a)
(define first-sizes (sizes))
(define env0 (envs))
(define inst0 (insts))
(define first-modes (modes))
(frame-log! a)
(define second-sizes (sizes))
(define env1 (envs))
(want "setup a first frame reads env, instances, args, in that order" first-sizes '("224" "128" "20"))
(want "MODES a fresh scene's first frame is mode 0" first-modes '(0))
(want "setup a second frame reads env and args" second-sizes '("224" "20"))
(want "setup the two env blocks differ (mode 0, mode 1)" (equal? env0 env1) #f)
(want "MODES its second frame is mode 1" (modes) '(1))
;; LAYOUT: where a fresh first frame's instance upload and reduction are,
;; read from the encoded words of a frame encoded and dropped on a scene
;; of its own: the instance upload is the one command [4 slot base 128];
;; the reduction is the frame's last word, opcode 16, after opcode 15
(define layout
  (let ((sc (fresh)))
    (begin+draw! sc)
    (let* ((end (gpu-pos))
           (hits (let loop ((i 0) (acc '()))
                   (if (> (+ i 16) end) (reverse acc)
                       (loop (+ i 4)
                             (if (and (= (%mem-i32-ref i) 4) (= (%mem-i32-ref (+ i 12)) 128))
                                 (cons i acc) acc))))))
      (want "setup LAYOUT one instance upload command in a first frame" (length hits) 1)
      (want "setup LAYOUT the frame ends with end-pass and the reduction"
            (list (%mem-i32-ref (- end 8)) (%mem-i32-ref (- end 4))) '(15 16))
      (gpu-begin!)
      (cons (if (pair? hits) (car hits) 0) (- end 4)))))
(define INST-AT (car layout))
(define HZB-AT (cdr layout))
;; a steady frame (after one replayed frame) has no instance upload, so
;; its reduction word is earlier: read it the same way
(define HZB-STEADY-AT
  (let ((sc (fresh)))
    (frame! sc)
    (begin+draw! sc)
    (let ((end (gpu-pos)))
      (want "setup LAYOUT a steady frame ends with end-pass and the reduction"
            (list (%mem-i32-ref (- end 8)) (%mem-i32-ref (- end 4))) '(15 16))
      (gpu-begin!)
      (- end 4))))
;; overflow in the command after the instance upload (the argument reset,
;; 16 bytes), at the upload's first word, at its first operand word
(define AFTER-INST (+ INST-AT 24))
(define AT-INST-OP INST-AT)
(define AT-INST-OPERAND (+ INST-AT 4))

;; ---- I1 / H1 ----
(define b (fresh))
(begin+draw! b)
(frame-log! b)
(want "I1 first frame dropped: the next uploads the instances" (insts) inst0)
(want "H1 first frame dropped: the next is mode 0" (envs) env0)
(want "H1 MODES" (modes) '(0))

;; ---- I2 ----
(define c (fresh))
(want "setup I2 the first frame overflows after the instance upload"
      (overflowing-frame! c AFTER-INST) (cons #t (+ INST-AT 16)))
(frame-log! c)
(want "I2 overflow after the upload was encoded: the next frame uploads" (insts) inst0)

;; ---- I3 ----
(define d (fresh))
(want "setup I3 the first frame overflows after the instance upload"
      (overflowing-frame! d AFTER-INST) (cons #t (+ INST-AT 16)))
(gpustate-reset!)
(gpu-flush!)
(want "setup I3 the cut-off frame's flush ran the instance upload" (insts) inst0)
(frame-log! d)
(want "I3 after the cut-off frame was flushed, no upload" (insts) '())

;; ---- I5 ----
(define (moved-reference)
  (let ((sc (scene (signal 1.0))))
    (sgpu-init! sc canvas) (frame-log! sc) (insts)))
(define inst-moved (moved-reference))
(want "setup I5 the moved instances differ from the unmoved" (equal? inst-moved inst0) #f)
(define (i5 limit flush-cut-off?)
  (let* ((s (signal 0.0)) (sc (scene s)))
    (sgpu-init! sc canvas)
    (frame! sc)
    (frame-log! sc)
    (let ((steady (insts)))
      (signal-set! s 1.0)
      (let ((ov (overflowing-frame! sc limit)))
        (when flush-cut-off? (gpu-flush!))
        (frame-log! sc)
        (list steady ov (insts))))))
(want "I5 overflow at the replacement upload's first word"
      (i5 AT-INST-OP #f) (list '() (cons #t INST-AT) inst-moved))
(want "I5 overflow at an operand word of the replacement upload"
      (i5 AT-INST-OPERAND #f) (list '() (cons #t INST-AT) inst-moved))
(want "I6 overflow at an operand word, the cut-off frame flushed: the next frame uploads"
      (i5 AT-INST-OPERAND #t) (list '() (cons #t INST-AT) inst-moved))

;; ---- I4 ----
(define f (fresh))
(frame! f) (frame! f)
(gpu-attach! canvas (lambda () #t))
(sgpu-init! f canvas)
(frame-log! f)
(want "I4 attach and init again: the next frame uploads" (insts) inst0)
(frame! f)
(sgpu-init! f canvas)
(frame-log! f)
(want "I4 init again, same device: the next frame uploads" (insts) inst0)

;; ---- CI / CH ----
(define g (fresh))
(frame-log! g)
(define ci1 (insts))
(frame-log! g)
(want "CI a steady scene uploads in the first frame only" (list ci1 (insts)) (list inst0 '()))
(want "CH the second frame is mode 1" (list (envs) (modes)) (list env1 '(1)))
(sgpu-occlusion! #f)
(frame-log! g)
(sgpu-occlusion! #t)
(want "CH occlusion off: mode 0" (list (envs) (modes)) (list env0 '(0)))

;; ---- H2 ----
(define h (fresh))
(gpustate-reset!)
(begin+draw! h) (sgpu-draw! h) (gpu-flush!)
(want "H2 two draws before the first flush: both mode 0"
      (list (envs) (modes)) (list (append env0 env0) '(0 0)))
(want "I7 two draws before the first flush: the instances are uploaded once" (insts) inst0)
(define i7 (let ((s (signal 0.0))) (let ((sc (scene s))) (sgpu-init! sc canvas) (cons s sc))))
(gpustate-reset!)
(begin+draw! (cdr i7)) (signal-set! (car i7) 1.0) (sgpu-draw! (cdr i7)) (gpu-flush!)
(want "I7 with a move between the two draws: uploaded twice" (length (insts)) 2)

;; ---- CH2 ----
(define k (fresh))
(frame! k)
(gpustate-reset!)
(begin+draw! k) (sgpu-draw! k) (gpu-flush!)
(begin+draw! k) (sgpu-draw! k) (gpu-flush!)
(want "CH2 two draws per flush, steady: every env is mode 1"
      (list (envs) (modes)) (list (append env1 env1 env1 env1) '(1 1 1 1)))
(define k3 (fresh))
(frame! k3)
(gpustate-reset!)
(begin+draw! k3) (sgpu-draw! k3) (sgpu-draw! k3) (gpu-flush!)
(want "CH3 three draws in one flush, steady: every env is mode 1" (modes) '(1 1 1))

;; ---- H3 ----
(define m (fresh))
(frame! m)
(begin+draw! m)
(frame-log! m)
(want "H3 a replayed reduction, a dropped frame: mode 1" (list (envs) (modes)) (list env1 '(1)))

;; ---- H4 ----
(define (h4 primed?)
  (let ((sc (fresh)))
    (when primed? (frame! sc))
    (let ((ov (overflowing-frame! sc (if primed? HZB-STEADY-AT HZB-AT))))
      (gpu-flush!)
      (frame-log! sc)
      (list ov (modes)))))
(want "H4 overflow at the reduction word, the cut-off frame flushed: mode 0"
      (h4 #f) (list (cons #t HZB-AT) '(0)))
(want "H4 the same after a replayed frame: mode 1" (h4 #t) (list (cons #t HZB-STEADY-AT) '(1)))

;; ---- R3 ----
(define n (fresh))
(frame! n) (frame! n)
(sgpu-init! n canvas)
(frame-log! n)
(define r3a (envs))
(define r3m0 (modes))
(frame-log! n)
(want "R3 init again after two frames: mode 0, then 1" (list r3a (envs)) (list env0 env1))
(want "R3 MODES" (list r3m0 (modes)) '((0) (1)))

;; ---- R1 ----
(define (r1 make which)
  (let ((sc (make (signal 0.0))))
    (sgpu-init! sc canvas)
    (frame! sc)
    (gpustate-fail-write! which)
    (let ((init (gpustate-attempt (lambda () (sgpu-init! sc canvas)))))
      (gpustate-reset!)
      (let* ((fr (gpustate-attempt (lambda () (frame! sc))))
             (after (list (draws) (reads))))
        (gpustate-reset!)
        (sgpu-init! sc canvas)
        (let ((geo (length (reads))))
          (frame-log! sc)
          (list init fr after (> geo 0) (> (draws) 0) (pair? (insts))))))))
(want "R1 a re-init whose first geometry upload fails: no draw, no upload; a completed re-init draws"
      (r1 scene 1) (list "raised:Error" "ok" (list 0 '()) #t #t #t))
(want "R1b two groups, the second group's first geometry upload fails: no draw, no upload"
      (r1 scene2 3) (list "raised:Error" "ok" (list 0 '()) #t #t #t))

(display (if (null? fails) #t (reverse fails)))
