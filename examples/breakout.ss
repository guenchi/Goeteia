;; Breakout over (web sprite): paddle, ball, bricks and score in one
;; quad batch -- one buffer upload and one draw call per frame.  The
;; score text is typeset by (web typeset) with the atlas's own
;; measurer, so layout and rendering agree glyph for glyph.
;; Arrows or the mouse move the paddle; click restarts.
(import (rnrs) (web js) (web dom) (web gl) (web fx) (web sprite)
        (web typeset))

(define W 800.0)
(define H 600.0)

(fx-init! (get-element-by-id "c"))
(fx-init-input!)
(define at (make-atlas "bold 20px system-ui" 20))
(define bt (make-batch at))
(define measure (atlas-measurer at))
(define lh (atlas-line-height at))

;; ---- state ----
(define COLS 10)
(define ROWS 5)
(define BW 72.0)                         ; brick size and grid origin
(define BH 24.0)
(define BX0 22.0)
(define BY0 80.0)
(define bricks (make-vector (* COLS ROWS) #t))
(define paddle-x 340.0)                  ; left edge; 120 x 14 at y 560
(define ball-x 400.0)
(define ball-y 400.0)
(define ball-vx 220.0)
(define ball-vy -320.0)
(define score 0)
(define mode 'play)                      ; play | over | win
(define last-px -1.0)

(define (reset!)
  (let fill ((i 0))
    (when (< i (vector-length bricks))
      (vector-set! bricks i #t)
      (fill (+ i 1))))
  (set! paddle-x 340.0)
  (set! ball-x 400.0) (set! ball-y 400.0)
  (set! ball-vx 220.0) (set! ball-vy -320.0)
  (set! score 0)
  (set! mode 'play))

;; ---- text, re-typeset only when it changes ----
(define score-lay #f)
(define shown-score -1)
(define (score-layout!)
  (unless (= shown-score score)
    (set! shown-score score)
    (set! score-lay
          (layout (prepare (string-append "SCORE " (number->string score))
                           measure)
                  W lh))))
(define (centered-lay text)              ; (layout . x) centered on W
  (let ((p (prepare text measure)))
    (cons (layout p W lh) (/ (fl- W (prepared-width p)) 2.0))))
(define over-lay (centered-lay "GAME OVER - CLICK TO RESTART"))
(define win-lay (centered-lay "YOU WIN - CLICK TO RESTART"))

;; ---- update ----
(define (clamp v lo hi) (if (fl<? v lo) lo (if (fl<? hi v) hi v)))

(define (brick-at i)                     ; (x . y) of brick i
  (cons (fl+ BX0 (fl* 76.0 (fixnum->flonum (remainder i COLS))))
        (fl+ BY0 (fl* 28.0 (fixnum->flonum (quotient i COLS))))))

(define (step! dt)
  ;; paddle: arrows at 500 px/s; a pointer move sets it directly
  (when (key-down? "ArrowLeft")
    (set! paddle-x (fl- paddle-x (fl* 500.0 dt))))
  (when (key-down? "ArrowRight")
    (set! paddle-x (fl+ paddle-x (fl* 500.0 dt))))
  (unless (fl=? (pointer-x) last-px)
    (set! last-px (pointer-x))
    (set! paddle-x (fl- last-px 60.0)))
  (set! paddle-x (clamp paddle-x 0.0 680.0))
  ;; ball
  (set! ball-x (fl+ ball-x (fl* ball-vx dt)))
  (set! ball-y (fl+ ball-y (fl* ball-vy dt)))
  (when (or (and (fl<? ball-x 8.0) (fl<? ball-vx 0.0))
            (and (fl<? 792.0 ball-x) (fl<? 0.0 ball-vx)))
    (set! ball-vx (fl- 0.0 ball-vx)))
  (when (and (fl<? ball-y 8.0) (fl<? ball-vy 0.0))
    (set! ball-vy (fl- 0.0 ball-vy)))
  ;; the paddle: bounce with a little english
  (when (and (fl<? 0.0 ball-vy)
             (fl<? 552.0 ball-y) (fl<? ball-y 574.0)
             (fl<? (fl- paddle-x 8.0) ball-x)
             (fl<? ball-x (fl+ paddle-x 128.0)))
    (set! ball-vy (fl- 0.0 ball-vy))
    (set! ball-vx (fl+ ball-vx (fl* 3.0 (fl- ball-x (fl+ paddle-x 60.0))))))
  ;; bricks
  (let scan ((i 0))
    (when (< i (vector-length bricks))
      (if (and (vector-ref bricks i)
               (let* ((p (brick-at i)) (bx (car p)) (by (cdr p)))
                 (and (fl<? bx (fl+ ball-x 8.0))
                      (fl<? (fl- ball-x 8.0) (fl+ bx BW))
                      (fl<? by (fl+ ball-y 8.0))
                      (fl<? (fl- ball-y 8.0) (fl+ by BH)))))
          (begin (vector-set! bricks i #f)
                 (set! score (+ score 10))
                 (set! ball-vy (fl- 0.0 ball-vy))
                 (when (= score (* 10 COLS ROWS)) (set! mode 'win)))
          (scan (+ i 1)))))
  ;; the floor
  (when (fl<? 608.0 ball-y) (set! mode 'over)))

;; ---- render: everything is one batch ----
(define row-colors
  '#((0.95 0.35 0.35) (0.95 0.65 0.30) (0.95 0.90 0.35)
     (0.45 0.85 0.45) (0.40 0.60 0.95)))

(define (render!)
  (cmd-clear! 0.05 0.06 0.10 1.0)
  (batch-begin! bt)
  (let draw ((i 0))
    (when (< i (vector-length bricks))
      (when (vector-ref bricks i)
        (let ((p (brick-at i))
              (c (vector-ref row-colors (quotient i COLS))))
          (rect! bt (car p) (cdr p) BW BH
                 (car c) (cadr c) (caddr c) 1.0)))
      (draw (+ i 1))))
  (rect! bt paddle-x 560.0 120.0 14.0 0.30 0.60 1.00 1.0)
  (rect! bt (fl- ball-x 8.0) (fl- ball-y 8.0) 16.0 16.0 1.0 1.0 1.0 1.0)
  (score-layout!)
  (draw-text! bt score-lay 12.0 8.0 1.0 1.0 1.0 1.0)
  (when (eq? mode 'over)
    (draw-text! bt (car over-lay) (cdr over-lay) 280.0 1.0 0.5 0.5 1.0))
  (when (eq? mode 'win)
    (draw-text! bt (car win-lay) (cdr win-lay) 280.0 0.5 1.0 0.6 1.0))
  (batch-draw! bt))

(fx-loop!
 (lambda (t dt)
   (if (eq? mode 'play)
       (step! (if (fl<? 0.05 dt) 0.05 dt))   ; clamp a tab-switch dt
       (when (pointer-down?) (reset!)))
   (render!)))
