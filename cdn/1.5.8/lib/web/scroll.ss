;; A virtual scroller for variable-height text: the use case that
;; motivated (web typeset).  Chat threads and streaming feeds need an
;; item's height BEFORE it mounts -- the DOM can't say without a
;; forced reflow -- so heights come from typeset's pure layout over
;; the same font, and the DOM stays a write-only surface.
;;
;;   (define vs (make-vscroll parent 420 600 "15px system-ui" 22))
;;   (vscroll-append! vs "a message")     ; sticks to the bottom when
;;   ...                                  ; the user is already there
;;
;; Only the visible window (plus a small overscan) is ever in the
;; DOM; items are absolutely positioned at prefix-sum offsets over
;; the estimated heights.  Estimates are just estimates -- font
;; fallback and subpixel wrapping drift -- so each newly mounted item
;; is measured once (offsetHeight: the items are in the DOM anyway,
;; one batched reflow per render) and the offsets correct themselves.
;;
;; The wrap width the estimator uses IS the item div's CSS width, and
;; the font string feeds both the canvas measurer and the item style,
;; so the two layouts agree up to shaping.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web scroll)
  (export make-vscroll vscroll? vscroll-element vscroll-count
          vscroll-append! vscroll-render!)
  (import (rnrs) (web js) (web dom) (web typeset) (web canvas))

  (define $vs-pad 2)                    ; overscan items above/below
  (define $vs-bar 18)                   ; scrollbar allowance, px

  (define-record-type (vscroll $make-vscroll vscroll?)
    (fields (immutable outer vscroll-element)
            (immutable inner $vs-inner)
            (immutable wrapw $vs-wrapw)
            (immutable h $vs-h)
            (immutable lh $vs-lh)
            (immutable font $vs-font)
            (immutable measure $vs-measure)
            (mutable texts $vs-texts $vs-texts!)
            (mutable heights $vs-heights $vs-heights!)
            (mutable offs $vs-offs $vs-offs!)     ; length cap+1 prefix sums
            (mutable cap $vs-cap $vs-cap!)
            (mutable n $vs-n $vs-n!)
            (mutable mounted $vs-mounted $vs-mounted!)))  ; ((idx . div) ...)

  (define (vscroll-count vs) ($vs-n vs))

  (define (make-vscroll parent w h font lh)
    (let ((outer (create-element "div"))
          (inner (create-element "div")))
      (set-style! outer "width" (string-append (number->string w) "px"))
      (set-style! outer "height" (string-append (number->string h) "px"))
      (set-style! outer "overflowY" "auto")
      (set-style! outer "position" "relative")
      (set-style! inner "position" "relative")
      (set-style! inner "height" "0px")
      (append-child! outer inner)
      (append-child! parent outer)
      (let ((vs ($make-vscroll outer inner (- w $vs-bar) h lh font
                               (canvas-measurer font)
                               (make-vector 16 #f) (make-vector 16 0)
                               (make-vector 17 0) 16 0 '())))
        (add-event-listener! outer "scroll"
                             (lambda _ (vscroll-render! vs) (js-undefined)))
        vs)))

  (define ($vs-grow! vs)                ; double the item storage
    (let* ((cap ($vs-cap vs))
           (ncap (* 2 cap))
           (nt (make-vector ncap #f))
           (nh (make-vector ncap 0))
           (no (make-vector (+ ncap 1) 0)))
      (let cp ((i 0))
        (when (< i ($vs-n vs))
          (vector-set! nt i (vector-ref ($vs-texts vs) i))
          (vector-set! nh i (vector-ref ($vs-heights vs) i))
          (vector-set! no i (vector-ref ($vs-offs vs) i))
          (cp (+ i 1))))
      (vector-set! no ($vs-n vs) (vector-ref ($vs-offs vs) ($vs-n vs)))
      ($vs-texts! vs nt) ($vs-heights! vs nh) ($vs-offs! vs no)
      ($vs-cap! vs ncap)))

  ;; rebuild prefix sums from item i on
  (define ($vs-resum! vs i)
    (let ((offs ($vs-offs vs)) (hs ($vs-heights vs)) (n ($vs-n vs)))
      (let loop ((j i))
        (when (< j n)
          (vector-set! offs (+ j 1)
                       (+ (vector-ref offs j) (vector-ref hs j)))
          (loop (+ j 1))))))

  (define ($vs-total vs) (vector-ref ($vs-offs vs) ($vs-n vs)))

  (define ($vs-spacer! vs)
    (set-style! ($vs-inner vs) "height"
                (string-append (number->string ($vs-total vs)) "px")))

  ;; largest i in [0, n) whose offset is <= y
  (define ($vs-find vs y)
    (let ((offs ($vs-offs vs)))
      (let loop ((lo 0) (hi (- ($vs-n vs) 1)))
        (if (>= lo hi)
            lo
            (let ((mid (quotient (+ lo hi 1) 2)))
              (if (<= (vector-ref offs mid) y)
                  (loop mid hi)
                  (loop lo (- mid 1))))))))

  (define ($vs-place! vs entry)         ; (idx . div) at its offset
    (set-style! (cdr entry) "top"
                (string-append
                 (number->string (vector-ref ($vs-offs vs) (car entry)))
                 "px")))

  (define ($vs-make-item vs i)
    (let ((div (create-element "div")))
      (set-style! div "position" "absolute")
      (set-style! div "left" "0px")
      (set-style! div "width"
                  (string-append (number->string ($vs-wrapw vs)) "px"))
      (set-style! div "font" ($vs-font vs))
      (set-style! div "lineHeight"
                  (string-append (number->string ($vs-lh vs)) "px"))
      (set-style! div "whiteSpace" "pre-wrap")
      (set-style! div "overflowWrap" "break-word")
      (set-text! div (vector-ref ($vs-texts vs) i))
      (append-child! ($vs-inner vs) div)
      (cons i div)))

  ;; mount the visible window, unmount the rest, then measure the
  ;; newly mounted once and let the offsets correct themselves
  (define (vscroll-render! vs)
    (let ((n ($vs-n vs)))
      (when (> n 0)
        (let* ((st (js->number (js-get (vscroll-element vs) "scrollTop")))
               (first ($vs-find vs st))
               (last (let seek ((i first))
                       (if (or (= i (- n 1))
                               (> (vector-ref ($vs-offs vs) (+ i 1))
                                  (+ st ($vs-h vs))))
                           i
                           (seek (+ i 1)))))
               (lo (max 0 (- first $vs-pad)))
               (hi (min (- n 1) (+ last $vs-pad))))
          ;; drop what left the window
          (let split ((ms ($vs-mounted vs)) (keep '()))
            (if (null? ms)
                ($vs-mounted! vs keep)
                (let ((e (car ms)))
                  (if (or (< (car e) lo) (> (car e) hi))
                      (begin (remove-child! ($vs-inner vs) (cdr e))
                             (split (cdr ms) keep))
                      (split (cdr ms) (cons e keep))))))
          ;; mount what entered; batch the corrective reads after
          (let mount ((i lo) (fresh '()))
            (if (> i hi)
                (let correct ((fs fresh) (dirty n))
                  (if (null? fs)
                      (when (< dirty n)           ; something re-measured
                        ($vs-resum! vs dirty)
                        ($vs-spacer! vs)
                        (for-each (lambda (e) ($vs-place! vs e))
                                  ($vs-mounted vs)))
                      (let* ((e (car fs))
                             (oh (js->number (js-get (cdr e) "offsetHeight"))))
                        (if (and (> oh 0)
                                 (not (= oh (vector-ref ($vs-heights vs)
                                                        (car e)))))
                            (begin
                              (vector-set! ($vs-heights vs) (car e) oh)
                              (correct (cdr fs) (min dirty (car e))))
                            (correct (cdr fs) dirty)))))
                (if (assv i ($vs-mounted vs))
                    (mount (+ i 1) fresh)
                    (let ((e ($vs-make-item vs i)))
                      ($vs-place! vs e)
                      ($vs-mounted! vs (cons e ($vs-mounted vs)))
                      (mount (+ i 1) (cons e fresh))))))))))

  ;; append one item; if the view is at the bottom it stays there
  (define (vscroll-append! vs text)
    (when (= ($vs-n vs) ($vs-cap vs)) ($vs-grow! vs))
    (let* ((outer (vscroll-element vs))
           (st (js->number (js-get outer "scrollTop")))
           (stick (>= (+ st ($vs-h vs)) (- ($vs-total vs) 2)))
           (est (layout-height
                 (layout (prepare text ($vs-measure vs))
                         ($vs-wrapw vs) ($vs-lh vs))))
           (n ($vs-n vs)))
      (vector-set! ($vs-texts vs) n text)
      (vector-set! ($vs-heights vs) n est)
      ($vs-n! vs (+ n 1))
      ($vs-resum! vs n)
      ($vs-spacer! vs)
      (when stick
        (js-set! outer "scrollTop" ($vs-total vs)))
      (vscroll-render! vs)
      (when stick                       ; corrections may move the end
        (js-set! outer "scrollTop" ($vs-total vs))))))
