;; expect: #t
;; fx-uniform! skips a set only when the same value was set earlier IN
;; THE SAME STREAM, after a use of the program in that stream (R40:
;; archive/goeteia-r40-design-2026-11-09.md, 3.3 U and claim B; rows
;; U1-U10 and CU of section 4).
;;
;; THE DEFECT.  The cache kept the last value it ENCODED, and a command
;; takes effect only when a flush replays it.  A set encoded and then
;; dropped by cmd-begin!, cut off by a region change, refused at the
;; full region, or made while another program was current (GL ignores
;; it), was remembered, and the next set of that value -- the one that
;; would have reached GL -- was skipped.  And a stream replayed again (a
;; second flush) started from what the previous replay left, so a set
;; skipped against an EARLIER stream was missing from this stream's own
;; words: a stream that sets 3, draws, sets 4, draws, flushed twice, drew
;; [3,4,4,4].
;;
;; THE RULE.  A record is a value and a stamp.  The set is skipped only
;; when the record is of the current stream (cmd-stamp-in-stream?) and
;; the value is equal.  A sent value stores (cmd-stamp) only when the
;; stream's last cmd-use-program! named this program, else #f: GL
;; applies a uniform call only to the program in use.  The viewport
;; helpers store #f.  Nothing is trusted across a cmd-begin!: the first
;; set of each uniform in each stream is sent (a cost, deliberate).
;;
;; Mock: test/lib/glstate.ss -- uniform storage per program, a call
;; whose location's program is not current is rejected, and each draw
;; records the value it reads.  The helper's value is the viewport
;; height, 64 here, so it is never one of the literals.
;;
;; Rows, and the wrong implementation each rejects (base is the tree
;; before the change):
;;   U1  a set dropped by cmd-begin! (base)
;;   U2  a set made after a completed flush, then dropped (base)
;;   U3  a set refused at the full region: its first word does not fit,
;;       the limit set before the stream's cmd-begin! (base: it recorded
;;       before encoding)
;;   U4  a set cut off by a region change past it (base)
;;   U5  a set made while another program was current (base; no gate)
;;   U6  after a helper, a literal is sent once and then deduplicates
;;       (the old never-again mark, a cost)
;;   U8  a stream replayed twice draws its own values both times (base;
;;       a record trusted across streams)
;;   U9  the same with helper writes (a record trusted across streams;
;;       green on base, by the old mark)
;;   U10 a helper between two equal literals: the second is sent (a
;;       helper that leaves the stamp)
;;   CU  one send per stream for a steady value (no cache; a record
;;       trusted across streams)
;;   CU2 a repeat after a flush in the middle of the stream is still a
;;       repeat in that stream: the stream's words hold one set (a flush
;;       that opens its next segment in a new stream, a cost)
;;   CT  the same for every dispatch branch -- vec2, vec3, vec4, and the
;;       one int/sampler branch, through an int and a sampler: one call per
;;       stream, repeats in a stream skipped (a branch that never records
;;       what it sent, a cost)
;;   CV2 a change in a vector's LAST component is sent (a comparison that
;;       ignores trailing components)
;;   U11 a set after a region change moved the base, in the same stream:
;;       sent, though the same value was set before the change (a record
;;       trusted while the encoder is stale -- the flush replays from the
;;       new base, and the first set is not among the words it runs)
(import (rnrs) (web js) (gfx gl) (gfx fx) (glstate))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
(define (try thunk) (guard (e (#t 'raised)) (thunk) 'returned))

(fx-init! (glstate-canvas 64 64))
(define wide 65536)
(define (prog)
  (fx-program! '((attribute vec2 a_pos)
                 (define (main) void (set! gl_Position (vec4 a_pos (fl 0) (fl 1)))))
               '((precision mediump float) (uniform float u_k)
                 (define (main) void (set! gl_FragColor (vec4 u_k (fl 0) (fl 0) (fl 1)))))))
(define buf (fx-buffer!))
(define (use p) (fx-use! p buf))
(define (U p x) (fx-uniform! p 'u_k x))
(define (helper p) (fx-uniform-viewport-height! p 'u_k))
(define (D) (cmd-draw-arrays! GL-TRIANGLES 0 3))
;; what the draws of the flushes after the last reset read
(define (draw-reads) (glstate-draw-values 'u_k))
;; how many uniform1f calls of u_k with this value since the last reset
(define (sends v)
  (let ((s (string-append "1f:u_k:" (number->string v))))
    (length (filter (lambda (e) (string=? e s)) (glstate-uniform-log)))))
(define (all-sends)
  (length (filter (lambda (e) (and (>= (string-length e) 7)
                                   (string=? (substring e 0 7) "1f:u_k:")))
                  (glstate-uniform-log))))

;; U1: 200 flushed; 100 encoded and dropped; 100 again
(let ((p (prog)))
  (cmd-begin!) (use p) (U p 200.0) (cmd-flush!)
  (cmd-begin!) (use p) (U p 100.0)
  (cmd-begin!) (use p) (U p 100.0) (D)
  (glstate-reset!) (cmd-flush!)
  (want "U1 a set dropped by a begin does not suppress the next" (draw-reads) '(100)))

;; U2: after a complete flush, a set without a begin; then a stream
(let ((p (prog)))
  (cmd-begin!) (cmd-flush!)
  (use p) (U p 7.0)
  (cmd-begin!) (use p) (U p 7.0) (D)
  (glstate-reset!) (cmd-flush!)
  (want "U2 a set after a completed flush, then dropped, does not suppress the next"
        (draw-reads) '(7)))

;; U3: the set's first word does not fit; the limit set before the begin
(let* ((p (prog))
       (limit (begin (cmd-region! 0 wide) (cmd-begin!)
                     (fx-use! p (fx-buffer!)) (cmd-pos))))
  (cmd-region! 0 limit)
  (cmd-begin!)
  (use p)
  (want "U3 the set does not fit" (try (lambda () (U p 5.0))) 'raised)
  (cmd-region! 0 wide)
  (cmd-begin!) (use p) (U p 5.0) (D)
  (glstate-reset!) (cmd-flush!)
  (want "U3 a set refused at the full region does not suppress the next" (draw-reads) '(5)))

;; U4: a set cut off by a region change past it
(let ((p (prog)))
  (cmd-begin!) (use p) (U p 9.0)
  (cmd-region! (cmd-pos) wide)
  (cmd-flush!)
  (cmd-region! 0 wide)
  (cmd-begin!) (use p) (U p 9.0) (D)
  (glstate-reset!) (cmd-flush!)
  (want "U4 a set cut off by a region change does not suppress the next" (draw-reads) '(9)))

;; U5: P's uniform set while Q is in use (GL rejects it), then P used
(let ((p (prog)) (q (prog)))
  (cmd-begin!) (use q) (U p 4.0) (use p) (U p 4.0) (D)
  (glstate-reset!) (cmd-flush!)
  (want "U5 the set made while another program was current is rejected by GL"
        (glstate-rejected) 1)
  (want "U5 and does not suppress the set after the program's use" (draw-reads) '(4)))

;; U6: a helper, then the same literal twice
(let ((p (prog)))
  (cmd-begin!) (use p) (helper p) (U p 480.0) (U p 480.0)
  (glstate-reset!) (cmd-flush!)
  (want "U6 after a helper a literal is sent once, then deduplicates" (sends 480) 1))

;; U8: 3 flushed; then a stream setting 3, 4 around two draws, flushed twice
(let ((p (prog)))
  (cmd-begin!) (use p) (U p 3.0) (cmd-flush!)
  (cmd-begin!) (use p) (U p 3.0) (D) (U p 4.0) (D)
  (glstate-reset!) (cmd-flush!) (cmd-flush!)
  (want "U8 a stream replayed twice draws its own values both times" (draw-reads) '(3 4 3 4)))

;; U9: the same with helper writes, after a helper and a literal in
;; earlier streams
(let ((p (prog)))
  (cmd-begin!) (use p) (helper p) (cmd-flush!)
  (cmd-begin!) (use p) (U p 480.0) (cmd-flush!)
  (cmd-begin!) (use p) (U p 480.0) (D) (helper p) (D)
  (glstate-reset!) (cmd-flush!) (cmd-flush!)
  (want "U9 a literal and a helper, replayed twice" (draw-reads) '(480 64 480 64)))

;; U10: a literal, a helper, the same literal
(let ((p (prog)))
  (cmd-begin!) (use p) (U p 480.0) (helper p) (U p 480.0) (D)
  (glstate-reset!) (cmd-flush!)
  (want "U10 the literal after a helper is sent" (sends 480) 2)
  (want "U10 and the draw reads it" (draw-reads) '(480)))

;; CU: a steady value over two streams
(let ((p (prog)))
  (glstate-reset!)
  (cmd-begin!) (use p) (U p 3.0) (U p 3.0) (cmd-flush!)
  (cmd-begin!) (use p) (U p 3.0) (cmd-flush!)
  (want "CU a steady value is sent once in each stream, and repeats in a stream are not"
        (all-sends) 2))

;; CU2: a set, a flush, the same set, a draw, a flush
(let ((p (prog)))
  (cmd-begin!) (use p) (U p 3.0) (cmd-flush!)
  (U p 3.0) (D)
  (glstate-reset!) (cmd-flush!)
  (want "CU2 the stream's words hold one set of the value" (all-sends) 1)
  (want "CU2 and its draw reads it" (draw-reads) '(3)))

;; CT and CV2: every dispatch branch
(define (prog-typed)
  (fx-program! '((attribute vec2 a_pos)
                 (define (main) void (set! gl_Position (vec4 a_pos (fl 0) (fl 1)))))
               '((precision mediump float)
                 (uniform vec2 u_v2) (uniform vec3 u_v3) (uniform vec4 u_v4)
                 (uniform int u_i) (uniform sampler2D u_s)
                 (define (main) void
                   (set! gl_FragColor (vec4 u_v2.x u_v3.y u_v4.z (fl 1)))))))
;; how many calls of this kind on this uniform since the last reset
(define (calls kind name)
  (let ((p (string-append kind ":" (symbol->string name) ":")))
    (length (filter (lambda (e)
                      (and (>= (string-length e) (string-length p))
                           (string=? (substring e 0 (string-length p)) p)))
                    (glstate-uniform-log)))))
(define (set-typed! p)
  (fx-uniform! p 'u_v2 1.0 2.0)
  (fx-uniform! p 'u_v3 1.0 2.0 3.0)
  (fx-uniform! p 'u_v4 1.0 2.0 3.0 4.0)
  (fx-uniform! p 'u_i 3)
  (fx-uniform! p 'u_s 1))
(let ((p (prog-typed)))
  (glstate-reset!)
  (cmd-begin!) (use p) (set-typed! p) (set-typed! p) (cmd-flush!)
  (cmd-begin!) (use p) (set-typed! p) (cmd-flush!)
  (want "CT one call per stream for each branch"
        (list (calls "2f" 'u_v2) (calls "3f" 'u_v3) (calls "4f" 'u_v4)
              (calls "1i" 'u_i) (calls "1i" 'u_s))
        '(2 2 2 2 2)))
(let ((p (prog-typed)))
  (glstate-reset!)
  (cmd-begin!) (use p)
  (fx-uniform! p 'u_v2 1.0 2.0) (fx-uniform! p 'u_v2 1.0 3.0)
  (fx-uniform! p 'u_v3 1.0 2.0 3.0) (fx-uniform! p 'u_v3 1.0 2.0 4.0)
  (fx-uniform! p 'u_v4 1.0 2.0 3.0 4.0) (fx-uniform! p 'u_v4 1.0 2.0 3.0 5.0)
  (cmd-flush!)
  (want "CV2 a change in the last component is sent"
        (list (calls "2f" 'u_v2) (calls "3f" 'u_v3) (calls "4f" 'u_v4))
        '(2 2 2)))

;; U11: a set, a region change past it, the same set, a draw
(let ((p (prog)))
  (cmd-begin!) (use p) (U p 9.0)
  (cmd-region! (cmd-pos) wide)
  (cmd-use-program! (fx-program-slot p)) (U p 9.0) (D)
  (glstate-reset!) (cmd-flush!)
  (want "U11 after a region change the set is sent again, and the draw reads it"
        (draw-reads) '(9))
  (cmd-region! 0 wide))

(display (if (null? fails) #t (reverse fails)))
