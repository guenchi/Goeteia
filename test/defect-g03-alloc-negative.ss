;; expect: #t
;; RED ON PURPOSE: fx-alloc! does not check its size, so a negative one
;; moves the bump pointer BACKWARDS and the next allocation hands out
;; bytes that are still in use.
;;
;; THE SHAPE, and it is what makes this more than a missing check:
;; the hazard is already understood on the OTHER path.  fx-release! --
;; the documented way to move the water level down -- is guarded on
;; both sides, and its comment says exactly why: a mark below the
;; command region hands out the encoder's own bytes, one above the
;; water level hands out memory that was never allocated.  fx-alloc!
;; moves the same pointer, can move it down by any amount, and asks
;; nothing.  -> One hazard, two entrances, a guard on one of them.
;;
;; In linear memory the ordinary case does not crash.  Nothing traps
;; and nothing is logged; two live objects become one, and the symptom
;; turns up wherever the older is next read.
;;
;; CELL ORDER IS LOAD-BEARING and the file learned it the hard way.
;; The allocator is one global water level, so a cell that damages it
;; damages every cell after it: an early probe walked the level below
;; zero, and everything downstream trapped on `memory access out of
;; bounds`, taking the file's whole verdict with it.  -> Controls run
;; first while the heap is sane, the overlap probe uses a small
;; negative that stays in range, and the probes that wreck the level
;; run last and never dereference what they get.
;;
;; A THIRD THING, found while ordering them: once fx-alloc! has
;; pulled the level down, fx-release! CANNOT put it back -- the old
;; mark is now above the water level, which is the very thing its
;; second guard refuses.  The guard that protects the good path also
;; blocks recovery from the bad one.
(import (rnrs) (gfx fx))
(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))
(define (refuses? thunk) (guard (e ((error? e) #t) (else #f)) (begin (thunk) #f)))

;; ---- controls first: what a fix must not break ----
(define c (fx-alloc! 16))
(define d (fx-alloc! 16))
(want 'g03-CONTROL-disjoint (>= d (+ c 16)) #t)
(want 'g03-CONTROL-zero (integer? (fx-alloc! 0)) #t)
(let* ((m (fx-mark)) (e1 (fx-alloc! 32)))
  (fx-release! m)
  ;; release! is MEANT to hand the same bytes back.  A fix that made
  ;; the water level monotonic would take out the only form of freeing
  ;; this allocator has, and this cell is what would say so.
  (want 'g03-CONTROL-release-reuses (fx-alloc! 32) e1))

;; ---- red: live memory comes back out ----
;; `a` is live throughout; nothing below is entitled to touch it.
(define a (fx-alloc! 64))
(%mem-u8-set! a 111)
(%mem-u8-set! (+ a 32) 222)
(guard (e (#t 'refused)) (fx-alloc! -64))
(define b (fx-alloc! 64))
(%mem-u8-set! b 7)
(%mem-u8-set! (+ b 32) 7)
(want 'g03-live-block-survives
      (list (%mem-u8-ref a) (%mem-u8-ref (+ a 32))) (list 111 222))
(want 'g03-blocks-are-disjoint (>= b (+ a 64)) #t)

;; ---- red, and destructive: run last, and do not dereference ----
(let ((before (fx-mark)))
  (guard (e (#t 'refused)) (fx-alloc! -1024))
  (want 'g03-water-level-holds (>= (fx-mark) before) #t))
(want 'g03-negative-refused (refuses? (lambda () (fx-alloc! -64))) #t)
;; the line fx-release! will not cross, reached without being asked
(want 'g03-below-command-region
      (refuses? (lambda () (fx-alloc! (- 0 (+ (fx-mark) 4096))))) #t)

(if (null? fails) (display #t) (begin (display fails) (newline)))
