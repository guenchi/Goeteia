;; expect: #t
;; A full command region leaves the stream at the end of its last whole
;; command (R42, folded into R40: archive/goeteia-r40-design-2026-11-09.md,
;; 3.1 "(R42) No half command"; rows RB and S4b of section 4).
;;
;; THE DEFECT.  The encoder raised before the word that did not fit, so
;; a command could be left with only its first words.  A flush replays
;; it, and its missing operands are whatever the region holds after the
;; stop -- for cmd-ubo-data! the buffer it writes is one of them, so it
;; can write any buffer, one whose cached record says it is up to date
;; included.  And a caller that widened the limit and went on would have
;; the next command's words read as the half command's operands.
;;
;; THE RULE.  Each encoder records where its command begins before it
;; writes its first word; when a word does not fit, the write position
;; goes back there before the error is raised.  The draw counter counts
;; a draw after its words, so a draw rolled back is not counted.
;;
;; RB.  Every command encoder of lib/gfx/gl.ss, read from the file's
;; export list: an exported cmd- name that is not in the table below (nor
;; one of the procedures that encode no command) fails the row, so a new
;; encoder cannot be left out, however it is defined; and each must write
;; at least one word.  Each call is encoded right after one complete
;; preceding command, so it never starts where the previous command
;; started (an encoder that wrote its opcode without recording its start,
;; or recorded it after the first word, would roll back to the preceding
;; command).  For EVERY i in 0..n-1, n being the call's word count, and
;; for r in 0..3, the limit leaves room for i of its words and r more
;; bytes:
;;   (a) the overflow error is raised -- who cmd-region!, the message
;;       "command region overflow", the irritant where the word that did
;;       not fit would have gone; the write position is where the call
;;       began; no byte at or past the limit was written; the draw count
;;       is unchanged; and a flush replays the preceding command whole
;;       and nothing else;
;;   (b) the limit widened, the same call again, a flush: it replays
;;       the preceding command and the call, exactly once each, call
;;       for call as a control that never stopped.
;; (c) The control: a limit with room for all n words, exactly, and up to
;;     three bytes more.
;; The one-word encoders only have i = 0.  cmd-uniform-matrices! is
;; called with two matrices, and cmd-blend! in each of its branches.
;;
;; S4b.  A stream of ordinary commands, then cmd-uniform4f! (six words)
;; with room for two: the position after the error is its position
;; before the call, and the flush makes no uniform4f call at all.
;;
;; BASE.  (cmd-region! 0), a base alone, after a region with a limit of
;; 4096, removes that limit: 80,000 bytes of commands encode (last in
;; the file: they write over the staging above 64 KiB).
;;
;; ON THE TREE BEFORE THE CHANGE this cell is red by behaviour: the half
;; command stays, a draw is counted before its words, and the flush runs
;; the half command with whatever words follow it.
(import (rnrs) (web js) (gfx gl) (gfx fx) (glstate))

(define fails '())
(define nfails 0)
(define (fail! . what)
  (set! nfails (+ nfails 1))
  (when (< (length fails) 12) (set! fails (cons what fails))))

(fx-init! (glstate-canvas 64 64))
;; staging the replayer reads in place: buffers, indices, matrices,
;; pixels.  8-aligned, and wide enough for every operand below.
(define at (fx-alloc! 4096))
(define m1 (make-vector 16 0.5))
(define m2 (make-vector 16 0.25))

;; name, then a thunk making one call
(define table
  (list
   (list 'cmd-clear! (lambda () (cmd-clear! 0.25 0.5 0.75 1.0)))
   (list 'cmd-use-program! (lambda () (cmd-use-program! 3)))
   (list 'cmd-bind-buffer! (lambda () (cmd-bind-buffer! 4)))
   (list 'cmd-buffer-data! (lambda () (cmd-buffer-data! at 16)))
   (list 'cmd-vertex-attrib! (lambda () (cmd-vertex-attrib! 1 3 24 12)))
   (list 'cmd-vertex-attrib-h! (lambda () (cmd-vertex-attrib-h! 2 4 12 4)))
   (list 'cmd-uniform1f! (lambda () (cmd-uniform1f! 5 1.5)))
   (list 'cmd-uniform4f! (lambda () (cmd-uniform4f! 5 1.0 2.0 3.0 4.0)))
   (list 'cmd-draw-arrays! (lambda () (cmd-draw-arrays! GL-TRIANGLES 0 3)))
   (list 'cmd-bind-texture! (lambda () (cmd-bind-texture! 1 6)))
   (list 'cmd-bind-cubemap! (lambda () (cmd-bind-cubemap! 2 7)))
   (list 'cmd-bind-texture-array! (lambda () (cmd-bind-texture-array! 3 8)))
   (list 'cmd-unbind-cubemap! (lambda () (cmd-unbind-cubemap! 2)))
   (list 'cmd-unbind-texture! (lambda () (cmd-unbind-texture! 1)))
   (list 'cmd-bind-vao! (lambda () (cmd-bind-vao! 9)))
   (list 'cmd-unbind-vao! (lambda () (cmd-unbind-vao!)))
   (list 'cmd-bind-ubo! (lambda () (cmd-bind-ubo! 0 10)))
   (list 'cmd-ubo-data! (lambda () (cmd-ubo-data! 10 at 64)))
   (list 'cmd-tf-buffer! (lambda () (cmd-tf-buffer! 11)))
   (list 'cmd-tf-begin! (lambda () (cmd-tf-begin!)))
   (list 'cmd-tf-end! (lambda () (cmd-tf-end!)))
   (list 'cmd-uniform1i! (lambda () (cmd-uniform1i! 5 2)))
   (list 'cmd-uniform2f! (lambda () (cmd-uniform2f! 5 1.0 2.0)))
   (list 'cmd-uniform-viewport-height! (lambda () (cmd-uniform-viewport-height! 5)))
   (list 'cmd-uniform-viewport-size! (lambda () (cmd-uniform-viewport-size! 5)))
   (list 'cmd-uniform3f! (lambda () (cmd-uniform3f! 5 1.0 2.0 3.0)))
   (list 'cmd-uniform-matrix4! (lambda () (cmd-uniform-matrix4! 5 m1)))
   (list 'cmd-uniform-matrix4s! (lambda () (cmd-uniform-matrix4s! 5 at)))
   (list 'cmd-depth! (lambda () (cmd-depth! #t)))
   (list 'cmd-depth-write! (lambda () (cmd-depth-write! #f)))
   (list 'cmd-depth-func! (lambda () (cmd-depth-func! 'lequal)))
   (list 'cmd-polygon-offset! (lambda () (cmd-polygon-offset! 1.0 2.0)))
   (list 'cmd-color-mask! (lambda () (cmd-color-mask! #t #f #t #f)))
   (list 'cmd-cull-face! (lambda () (cmd-cull-face! 'back)))
   (list 'cmd-bind-index! (lambda () (cmd-bind-index! 12)))
   (list 'cmd-index-data32! (lambda () (cmd-index-data32! at 16)))
   (list 'cmd-draw-elements32! (lambda () (cmd-draw-elements32! GL-TRIANGLES 6)))
   (list 'cmd-index-data! (lambda () (cmd-index-data! at 12)))
   (list 'cmd-draw-elements! (lambda () (cmd-draw-elements! GL-TRIANGLES 6)))
   (list 'cmd-bind-target! (lambda () (cmd-bind-target! 13)))
   (list 'cmd-resolve-mrt! (lambda () (cmd-resolve-mrt! 14 15 2 4 4)))
   (list 'cmd-resolve! (lambda () (cmd-resolve! 14 15 4 4)))
   (list 'cmd-bind-canvas! (lambda () (cmd-bind-canvas!)))
   (list 'cmd-read-pixels! (lambda () (cmd-read-pixels! 0 0 2 2 at)))
   (list 'cmd-attrib-divisor! (lambda () (cmd-attrib-divisor! 1 1)))
   (list 'cmd-draw-elements-instanced!
         (lambda () (cmd-draw-elements-instanced! GL-TRIANGLES 6 2)))
   (list 'cmd-draw-elements-instanced32!
         (lambda () (cmd-draw-elements-instanced32! GL-TRIANGLES 6 2)))
   (list 'cmd-uniform-matrices! (lambda () (cmd-uniform-matrices! 5 (vector m1 m2))))
   (list 'cmd-uniform-matrices4s! (lambda () (cmd-uniform-matrices4s! 5 at 2)))
   (list 'cmd-viewport! (lambda () (cmd-viewport! 0 0 32 16)))
   (list 'cmd-blend! (lambda () (cmd-blend! 'alpha)))
   (list 'cmd-blend! (lambda () (cmd-blend! 'add)))
   (list 'cmd-blend! (lambda () (cmd-blend! 'premul)))
   (list 'cmd-blend! (lambda () (cmd-blend! 'off)))))

;; ---- every exported cmd- name of (gfx gl) is in the table ----
;; (or is one of the procedures that encode no command)
(define not-encoders
  '(cmd-region! cmd-begin! cmd-flush! cmd-pos cmd-draws
    cmd-stamp cmd-stamp-holds? cmd-stamp-in-stream? cmd-stream-program
    cmd-stream-viewport))
(define (prefix? p s)
  (and (>= (string-length s) (string-length p))
       (string=? (substring s 0 (string-length p)) p)))
;; (library (gfx gl) (export name ...) (import ...) body ...)
(define exported
  (let* ((lib (call-with-input-file "lib/gfx/gl.ss" read))
         (ex (caddr lib)))
    (unless (and (pair? ex) (eq? (car ex) 'export))
      (fail! 'listing "the third form of lib/gfx/gl.ss is not its export list"))
    (filter (lambda (n) (and (symbol? n) (prefix? "cmd-" (symbol->string n))))
            (if (pair? ex) (cdr ex) '()))))
(define table-names (map car table))
(when (< (length exported) 51)
  (fail! 'listing "fewer cmd- exports read from lib/gfx/gl.ss than exist"
         (length exported)))
(for-each (lambda (n)
            (unless (or (memq n table-names) (memq n not-encoders))
              (fail! 'listing "an exported command encoder is not in RB's table" n)))
          exported)
(for-each (lambda (n)
            (unless (memq n exported)
              (fail! 'listing "a table entry is not exported by (gfx gl)" n)))
          table-names)

;; ---- RB ----
(define wide 65536)
(define (preceding!) (cmd-depth-write! #t))
(define (flush-log)
  (glstate-reset!)
  (let ((r (glstate-attempt (lambda () (cmd-flush!)))))
    (cons r (glstate-calls))))
;; 'returned, or what was raised: (who message irritants)
(define (try-call thunk)
  (guard (e (#t (if (error? e)
                     (list (condition-who e) (condition-message e) (condition-irritants e))
                     (list 'not-an-error e))))
    (thunk)
    'returned))
(define (overflow-at a) (list 'cmd-region! "command region overflow" (list a)))

;; the preceding command alone, replayed: what (a) must replay
(define ref-preceding
  (begin (cmd-region! 0 wide) (cmd-begin!) (preceding!) (flush-log)))

(for-each
 (lambda (entry)
   (let ((name (car entry)) (call (cadr entry)))
     ;; the control, region wide: s, n, its replay and its draw count
     (cmd-region! 0 wide)
     (cmd-begin!)
     (preceding!)
     (let* ((s (cmd-pos)))
       (call)
       (let* ((n (quotient (- (cmd-pos) s) 4))
              (draws (cmd-draws))
              (ref (flush-log)))
         (unless (equal? (car ref) "ok")
           (fail! name 'control "the control's replay raised" (car ref)))
         (when (< n 1)
           (fail! name 'control "the encoder wrote no word"))
         ;; (c) room for exactly n words, and up to three bytes more
         (let fits ((r 0))
           (when (< r 4)
             (cmd-region! 0 (+ s (* 4 n) r))
             (cmd-begin!)
             (preceding!)
             (let ((x (try-call call)))
               (unless (and (eq? x 'returned) (= (cmd-pos) (+ s (* 4 n))))
                 (fail! name 'c r "a limit with room for all its words refused it" x (cmd-pos)))
               (unless (equal? (flush-log) ref)
                 (fail! name 'c r "the exact-fit replay differs from the control")))
             (fits (+ r 1))))
         ;; (a) and (b) for every i in 0..n-1 and r in 0..3
         (let each ((i 0))
           (when (< i n)
             (let bytes ((r 0))
               (when (< r 4)
                 (let ((word (+ s (* 4 i))))
                   (cmd-region! 0 (+ word r))
                   (cmd-begin!)
                   (preceding!)
                   ;; the word that will not fit, and what lies past the limit
                   (let mark ((b 0))
                     (when (< b 4) (%mem-u8-set! (+ word b) 165) (mark (+ b 1))))
                   (let ((x (try-call call)))
                     (unless (equal? x (overflow-at word))
                       (fail! name i r "not the overflow error for the word that did not fit" x))
                     (unless (= (cmd-pos) s)
                       (fail! name i r "the position after the error is not where the call began"
                              (cmd-pos) s))
                     (let past ((b r))
                       (when (< b 4)
                         (unless (= (%mem-u8-ref (+ word b)) 165)
                           (fail! name i r "a byte at or past the limit was written" (+ word b)))
                         (past (+ b 1))))
                     (unless (= (cmd-draws) 0)
                       (fail! name i r "a draw rolled back was counted" (cmd-draws)))
                     (unless (equal? (flush-log) ref-preceding)
                       (fail! name i r "the flush after the error is not the preceding command alone"))
                     (cmd-region! 0 wide)
                     (call)
                     (unless (= (cmd-draws) draws)
                       (fail! name i r "the draw count after the call again differs from the control"
                              (cmd-draws) draws))
                     (unless (equal? (flush-log) ref)
                       (fail! name i r "the replay after the call again differs from the control"))))
                 (bytes (+ r 1))))
             (each (+ i 1))))))))
 table)

;; ---- S4b: a realistic stream, cmd-uniform4f! with room for two words ----
(define q (fx-program! '((attribute vec2 a_pos)
                         (define (main) void (set! gl_Position (vec4 a_pos (fl 0) (fl 1)))))
                       '((precision mediump float) (uniform vec4 u_c)
                         (define (main) void (set! gl_FragColor u_c)))))
(define qbuf (fx-buffer!))
(define (s4b-prefix!)
  (cmd-viewport! 0 0 64 64)
  (fx-use! q qbuf)
  (fx-uniform! q 'u_c 0.5 0.5 0.5 1.0))
;; where cmd-uniform4f! will begin: measured on a stream of the same
;; commands (its VAO is set up the same way: a fresh buffer)
(define s4b-start
  (begin (cmd-region! 0 wide) (cmd-begin!)
         (cmd-viewport! 0 0 64 64)
         (fx-use! q (fx-buffer!))
         (fx-uniform! q 'u_c 0.25 0.5 0.5 1.0)
         (cmd-pos)))
(cmd-region! 0 (+ s4b-start 8))
(cmd-begin!)
(s4b-prefix!)
(let ((before (cmd-pos)))
  (unless (= before s4b-start)
    (fail! 'S4b "the stream before the call is not where it was measured" before s4b-start))
  (let ((r (try-call (lambda () (fx-uniform! q 'u_c 1.0 2.0 3.0 4.0)))))
    (unless (equal? r (overflow-at (+ s4b-start 8)))
      (fail! 'S4b "not the overflow error for the word that did not fit" r))
    (unless (= (cmd-pos) before)
      (fail! 'S4b "the position after the error is not its value before the call"
             (cmd-pos) before))
    (glstate-reset!)
    (glstate-attempt (lambda () (cmd-flush!)))
    (let ((u4 (filter (lambda (s) (prefix? "4f:" s)) (glstate-uniform-log))))
      (unless (equal? u4 '("4f:u_c:0.5,0.5,0.5,1"))
        (fail! 'S4b "the flush made a uniform4f call beyond the whole commands" u4)))))
(cmd-region! 0 wide)

;; ---- BASE: a base alone removes the limit ----
(define (clears! k) (let loop ((j 0)) (when (< j k) (cmd-clear! 0.0 0.0 0.0 1.0) (loop (+ j 1)))))
;; memory the unlimited stream writes over, so it cannot trap
(define scratch (fx-alloc! 262144))
(cmd-region! 0 4096)
(cmd-begin!)
;; the clear at 4080 has room for four of its five words: the fifth,
;; at 4096, does not fit, and the position goes back to 4080
(unless (equal? (try-call (lambda () (clears! 4000))) (overflow-at 4096))
  (fail! 'BASE "a limit of 4096 did not stop the commands at the word at 4096"))
(unless (= (cmd-pos) 4080)
  (fail! 'BASE "the position after the error is not the start of the clear at 4080" (cmd-pos)))
(cmd-region! 0)
(cmd-begin!)
(unless (eq? (try-call (lambda () (clears! 4000))) 'returned)
  (fail! 'BASE "a base alone after a limited region kept the limit"))
(cmd-region! 0 wide)

(display (if (= nfails 0) #t (list nfails 'failures (reverse fails))))
