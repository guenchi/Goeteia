;; expect: #t
;; What a drop or a full region costs the next frame: the records whose
;; words never ran are established again, once, and nothing else is
;; (R40: archive/goeteia-r40-design-2026-11-09.md, 3.3 "Size" and 3.5;
;; rows CAP and CAP2 of section 4).
;;
;; CAP.  m1, m2, m3 of one size.  m1 and m2 are first used in separate
;; flushed frames (sizes c1, c2), then drawn together warm (size w).  A
;; limit L with max(w, c1) <= L < c1 + c2: the warm pair fits, the pair
;; established again does not.  A frame that first uses m3 is dropped;
;; then a frame draws m1 and m2 -- it fits L and uploads nothing, since
;; nothing of theirs was dropped; then a frame draws m3 -- it uploads m3
;; alone.  Rejects one invalidation for every record (the pair would not
;; fit), and a dropped record that still holds (m3 would never upload).
;;
;; CAP2.  m1, m2 of one size, never used.  The limit, set before the
;; frame's cmd-begin!, is the command boundary after m2's attribute
;; setup in a cold frame drawing m1 then m2.  That frame's full region
;; is caught and the frame flushed anyway -- the whole commands before
;; the stop run, m1's upload and m2's setup among them.  The same frame
;; again fits, uploads m2 alone, and both draws read a whole box.
;; Rejects a cut-off segment that a flush running it never marks: the
;; frame would establish m1 again every time and stop at the same word.
;;
;; Mock: test/lib/glstate.ss.
(import (rnrs) (web js) (gfx gl) (gfx fx) (gfx mesh) (glstate))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
(define (try thunk) (guard (e (#t 'raised)) (thunk) 'returned))

(fx-init! (glstate-canvas 64 64))
(define wide 65536)
(define lit (fx-program! mesh-lit-vs mesh-lit-fs))
(define (box) (fx-mesh! (mesh-box 1.0 1.0 1.0)))
(define (use+draw m) (fx-mesh-use! lit m) (fx-mesh-draw! m))
;; one flushed frame; its size in bytes (the region's base is 0)
(define (frame-size thunk)
  (cmd-begin!) (thunk)
  (let ((n (cmd-pos))) (glstate-reset!) (cmd-flush!) n))

(define box-draw
  (let ((m (box)))
    (cmd-begin!) (use+draw m) (glstate-reset!) (cmd-flush!)
    (car (glstate-draws))))

;; ---- CAP ----
(let* ((m1 (box)) (m2 (box)) (m3 (box))
       (c1 (frame-size (lambda () (use+draw m1))))
       (c2 (frame-size (lambda () (use+draw m2))))
       (w (frame-size (lambda () (use+draw m1) (use+draw m2))))
       (limit (- (+ c1 c2) 4)))
  (want "CAP precondition: max(w, c1) < c1 + c2" (< (max w c1) (+ c1 c2)) #t)
  (cmd-region! 0 limit)
  (cmd-begin!)
  (want "CAP the frame first using m3 fits" (try (lambda () (use+draw m3))) 'returned)
  (cmd-begin!)
  (want "CAP the frame drawing m1 and m2 after the drop fits"
        (try (lambda () (use+draw m1) (use+draw m2))) 'returned)
  (glstate-reset!) (cmd-flush!)
  (want "CAP and uploads nothing" (length (glstate-uploads)) 0)
  (cmd-begin!) (use+draw m3) (glstate-reset!) (cmd-flush!)
  (want "CAP the frame drawing m3 uploads m3 only" (length (glstate-uploads)) 2)
  (want "CAP and draws a whole box" (glstate-draws) (list box-draw))
  (cmd-region! 0 wide))

;; ---- CAP2 ----
(let* ((m1 (box)) (m2 (box))
       ;; a cold use and draw of one mesh, and a cold attribute setup of
       ;; the same program on another buffer, each measured on fresh
       ;; objects in a stream that is then dropped
       (c (begin (cmd-region! 0 wide) (cmd-begin!) (use+draw (box)) (cmd-pos)))
       (a (begin (cmd-begin!) (fx-use! lit (fx-buffer!)) (cmd-pos)))
       (limit (+ c a)))
  (cmd-region! 0 limit)
  (cmd-begin!)
  (want "CAP2 the cold frame stops after m2's attribute setup"
        (try (lambda () (use+draw m1) (use+draw m2))) 'raised)
  (want "CAP2 at the boundary measured" (cmd-pos) limit)
  (cmd-flush!)
  (cmd-begin!)
  (want "CAP2 the same frame again fits"
        (try (lambda () (use+draw m1) (use+draw m2))) 'returned)
  (glstate-reset!) (cmd-flush!)
  (want "CAP2 and uploads m2 only"
        (map (lambda (u) (substring u 0 2)) (glstate-uploads)) '("AB" "EA"))
  (want "CAP2 and both draws read a whole box" (glstate-draws) (list box-draw box-draw))
  (cmd-region! 0 wide))

(display (if (null? fails) #t (reverse fails)))
