;; Glyphs that live: explode an element's text into per-glyph spans
;; -- the layout does not move -- and let them dodge the pointer with
;; a little spring-and-repulsion life.
;;
;; Two ways in, one group out:
;;
;;   (glyphs! el)         plain text.  (web typeset) re-sets it: pen
;;                        positions from (web canvas) advances,
;;                        normalized against the whole-string width
;;                        (per-code-point sums miss kerning by ~1%),
;;                        letter-spacing honoured, text-align center
;;                        and right respected.  A hidden copy of the
;;                        original text keeps the element's box.
;;                        Gradient text (background-clip: text) gets
;;                        per-glyph colours sampled along the run --
;;                        absolute spans fall outside the clip.
;;
;;   (glyphs-mixed! el)   inline markup (em, code, a).  Re-setting
;;                        would eat the tags, so each character's
;;                        rect comes from a DOM Range instead; glyph
;;                        spans sit INSIDE their own parents (an em's
;;                        glyphs stay italic, a link's glyphs click),
;;                        and the original runs hide behind
;;                        opacity:0, which never moves layout.
;;
;; Then either hand the groups over --
;;
;;   (glyphs-dodge! groups)   listeners + an own rAF loop
;;
;; -- or drive the steps from a loop you already run:
;;
;;   (glyphs-track! groups)   pointer/scroll/resize listeners only
;;   (glyphs-step! group)     one spring step, call it per frame
;;
;; (glyphs-rebuild! group) restores the original markup and explodes
;; again at the current geometry; track!'s resize handler calls it.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web glyphs)
  (export glyphs! glyphs-mixed! glyphs-group?
          glyphs-track! glyphs-step! glyphs-dodge! glyphs-rebuild!)
  (import (rnrs) (web js) (web dom) (web typeset) (web canvas))

  (define ($fl v) (if (flonum? v) v (exact->inexact v)))

  ;; a group: one exploded element; a char is
  ;; #(style cx cy dx dy vx vy), its rest CENTER in element-local px
  (define-record-type ($group $make-group glyphs-group?)
    (fields (immutable el $g-el)
            (immutable html $g-html)   ; to restore on rebuild
            (immutable kind $g-kind)   ; plain | mixed
            (mutable left $g-left $g-left!)
            (mutable top $g-top $g-top!)
            (mutable chars $g-chars $g-chars!)))

  ;; the numbers in a computed style string, e.g. the two rgb() stops
  ;; of "linear-gradient(120deg, rgb(21, 80, 196), rgb(71, 136, 238))"
  (define $numbers
    (js-eval "(s => { const m = String(s).match(/\\d+/g);
                      return m ? m.map(Number) : []; })"))

  ;; gradient text clips the ELEMENT's background to its own text --
  ;; absolute glyph spans come out invisible.  Sample a solid colour
  ;; per glyph instead; across the heading the eye reads the blend.
  (define ($gradient-sampler cs w)
    (and (string=? (js->string (js-get cs "color")) "rgba(0, 0, 0, 0)")
         (let ((ns (js-call $numbers (js-undefined)
                            (js-get cs "backgroundImage"))))
           (let ((n (js->number (js-get ns "length"))))
             (and (>= n 6)
                  (let ((c (lambda (i) ; the last six are r g b r g b
                             ($fl (js->number
                                   (js-index ns (+ (- n 6) i)))))))
                    (lambda (x)
                      (let* ((t (fl/ x (if (fl<? 1.0 w) w 1.0)))
                             (t (cond ((fl<? t 0.0) 0.0)
                                      ((fl<? 1.0 t) 1.0)
                                      (else t)))
                             (ch (lambda (i)
                                   (number->string
                                    (%fl->fx
                                     (fl+ (c i)
                                          (fl* t (fl- (c (+ i 3))
                                                      (c i)))))))))
                        (string-append "color:rgb(" (ch 0) "," (ch 1)
                                       "," (ch 2) ");")))))))))

  ;; the whole text's width as the BROWSER renders it: an invisible
  ;; nowrap probe inside the element (so font, spacing, features all
  ;; inherit).  Canvas metrics drift from the DOM's -- Firefox
  ;; especially -- so canvas supplies only the per-glyph PROPORTIONS
  ;; and this supplies the absolute scale: a line the DOM fits, the
  ;; typeset layout then fits by construction.
  (define ($dom-text-width el text)
    (let ((probe (create-element "span")))
      (set-attribute! probe "style"
        "position:absolute;visibility:hidden;white-space:nowrap")
      (set-text! probe text)
      (append-child! el probe)
      (let ((w ($fl (js->number
                     (js-get (js-method probe "getBoundingClientRect")
                             "width")))))
        (remove-child! el probe)
        w)))

  ;; ---- the plain path: typeset re-sets the text ----
  (define ($explode-plain! el)
    (let* ((text (js->string (js-get el "textContent")))
           (cs (js-method (js-global) "getComputedStyle" el))
           (size (computed-px el "fontSize" 16.0))
           (lh (computed-px el "lineHeight" (fl* size 1.3)))
           (ls (computed-px el "letterSpacing" 0.0))
           (align (computed-style el "textAlign"))
           (font (string-append (js->string (js-get cs "fontStyle")) " "
                                (js->string (js-get cs "fontWeight")) " "
                                (js->string (js-get cs "fontSize")) " "
                                (js->string (js-get cs "fontFamily"))))
           (raw (canvas-measurer font))
           ;; canvas advances give the glyphs' proportions; the DOM
           ;; probe gives the true total (kerning, features, engine
           ;; quirks included), minus what letter-spacing adds per
           ;; code point -- we re-add that per glyph below
           (counted (string-fold-cp
                     (lambda (acc cp start len)
                       (cons (fl+ (car acc)
                                  (raw (substring text start (+ start len))))
                             (+ (cdr acc) 1)))
                     (cons 0.0 0) text))
           (cpsum (car counted))
           (whole (fl- ($dom-text-width el text)
                       (fl* ls (fixnum->flonum (cdr counted)))))
           (factor (if (and (fl<? 0.0 cpsum) (fl<? 0.0 whole))
                       (fl/ whole cpsum)
                       1.0))
           (measure (lambda (s) (fl+ (fl* (raw s) factor) ls)))
           ;; fractional width plus slack: a shrink-to-fit element is
           ;; EXACTLY as wide as its text, and integer clientWidth or
           ;; measurement noise must not wrap what the browser didn't
           (bw ($fl (js->number
                     (js-get (js-method el "getBoundingClientRect")
                             "width"))))
           (l (layout (prepare text measure) (fl+ (fl* bw 1.01) 2.0) lh))
           (grad ($gradient-sampler cs bw))
           (acc '()))
      (set-style! el "position" "relative")
      (set-text! el "")
      (let ((sizer (create-element "span"))) ; holds the original box
        (set-attribute! sizer "style" "visibility:hidden")
        (set-text! sizer text)
        (append-child! el sizer))
      (for-each
       (lambda (ln)
         (let* ((y (line-y ln))
                (lt (line-text ln))
                (x0 (cond ((string=? align "center")
                           (fl/ (fl- bw (line-width ln)) 2.0))
                          ((string=? align "right")
                           (fl- bw (line-width ln)))
                          (else 0.0))))
           (string-fold-cp
            (lambda (pen cp start len)
              (let* ((g (substring lt start (+ start len)))
                     (cw (measure g)))
                (unless (= cp 32)
                  (let ((span (create-element "span")))
                    (set-attribute! span "style"
                      (string-append
                       "position:absolute;left:"
                       (number->string (fl+ x0 pen)) "px;top:"
                       (number->string y) "px;"
                       (if grad
                           (grad (fl+ x0 (fl+ pen (fl/ cw 2.0))))
                           "")))
                    (set-text! span g)
                    (append-child! el span)
                    (set! acc (cons (vector (js-get span "style")
                                            (fl+ x0 (fl+ pen (fl/ cw 2.0)))
                                            (fl+ y (fl/ lh 2.0))
                                            0.0 0.0 0.0 0.0)
                                    acc))))
                (fl+ pen cw)))
            0.0 lt)))
       (layout-lines l))
      (list->vector (reverse acc))))

  ;; ---- the mixed path: the browser tells us where glyphs are ----
  (define ($explode-mixed! el)
    (let* ((erect (js-method el "getBoundingClientRect"))
           (ex ($fl (js->number (js-get erect "left"))))
           (ey ($fl (js->number (js-get erect "top"))))
           (range (js-method (document) "createRange"))
           (acc '())
           (texts '()))
      (set-style! el "position" "relative")
      (let walk ((n (js-get el "firstChild")))
        (when (js-truthy? n)
          (let ((ty (js->number (js-get n "nodeType"))))
            (cond ((= ty 3) (set! texts (cons n texts)))
                  ((= ty 1) (walk (js-get n "firstChild")))))
          (walk (js-get n "nextSibling"))))
      (for-each
       (lambda (tn)
         (let ((s (js->string (js-get tn "nodeValue")))
               (parent (js-get tn "parentNode")))
           ;; Range offsets count utf-16 units, not utf-8 bytes --
           ;; fold the code points and track units ourselves
           (string-fold-cp
            (lambda (u16 cp start len)
              (let ((units (if (< cp #x10000) 1 2)))
                (unless (or (= cp 32) (= cp 9) (= cp 10) (= cp 160))
                  (js-method range "setStart" tn u16)
                  (js-method range "setEnd" tn (+ u16 units))
                  (let* ((r (js-method range "getBoundingClientRect"))
                         (x (fl- ($fl (js->number (js-get r "left"))) ex))
                         (y (fl- ($fl (js->number (js-get r "top"))) ey))
                         (w ($fl (js->number (js-get r "width"))))
                         (h ($fl (js->number (js-get r "height"))))
                         (span (create-element "span")))
                    (set-attribute! span "style"
                      (string-append "position:absolute;left:"
                                     (number->string x) "px;top:"
                                     (number->string y) "px"))
                    (set-text! span (substring s start (+ start len)))
                    (append-child! parent span)
                    (set! acc (cons (vector (js-get span "style")
                                            (fl+ x (fl/ w 2.0))
                                            (fl+ y (fl/ h 2.0))
                                            0.0 0.0 0.0 0.0)
                                    acc))))
                (+ u16 units)))
            0 s)
           ;; hide the measured run in place; opacity keeps layout
           ;; (and the accessibility tree)
           (let ((hider (create-element "span")))
             (set-style! hider "opacity" "0")
             (insert-before! parent hider tn)
             (append-child! hider tn))))
       (reverse texts))
      (list->vector (reverse acc))))

  (define ($group-of kind el)
    (let ((g ($make-group el (js->string (js-get el "innerHTML"))
                          kind 0.0 0.0
                          (if (eq? kind 'plain)
                              ($explode-plain! el)
                              ($explode-mixed! el)))))
      ($rect! g)
      g))
  (define (glyphs! el) ($group-of 'plain el))
  (define (glyphs-mixed! el) ($group-of 'mixed el))

  (define (glyphs-rebuild! g)
    (set-inner-html! ($g-el g) ($g-html g))
    ($g-chars! g (if (eq? ($g-kind g) 'plain)
                     ($explode-plain! ($g-el g))
                     ($explode-mixed! ($g-el g))))
    ($rect! g))

  ;; the element's viewport rect, cached: reading it every frame
  ;; would force a layout pass -- it moves only on scroll and resize
  (define ($rect! g)
    (let ((r (js-method ($g-el g) "getBoundingClientRect")))
      ($g-left! g ($fl (js->number (js-get r "left"))))
      ($g-top! g ($fl (js->number (js-get r "top"))))))

  ;; the pointer, in viewport coordinates (as the cached rects are)
  (define $px -9999.0)
  (define $py -9999.0)

  (define (glyphs-track! groups)
    (add-event-listener! (js-global) "pointermove"
      (lambda (e)
        (set! $px ($fl (js->number (js-get e "clientX"))))
        (set! $py ($fl (js->number (js-get e "clientY"))))
        (js-undefined)))
    (add-event-listener! (js-global) "scroll"
      (lambda (e) (for-each $rect! groups) (js-undefined)))
    (add-event-listener! (js-global) "resize"
      (lambda (e) (for-each glyphs-rebuild! groups) (js-undefined))))

  ;; one spring step: repulsion within ~110px of the pointer, a
  ;; spring home, critical-ish damping; the DOM is touched only
  ;; while a glyph still moves
  (define (glyphs-step! g)
    (let ((mx (fl- $px ($g-left g)))
          (my (fl- $py ($g-top g)))
          (chars ($g-chars g)))
      (let each ((i 0))
        (when (< i (vector-length chars))
          (let* ((c (vector-ref chars i))
                 (hx (vector-ref c 1))
                 (hy (vector-ref c 2))
                 (dx (vector-ref c 3)) (dy (vector-ref c 4))
                 (vx (vector-ref c 5)) (vy (vector-ref c 6))
                 (px (fl- (fl+ hx dx) mx))
                 (py (fl- (fl+ hy dy) my))
                 (r2 (fl+ (fl+ (fl* px px) (fl* py py)) 40.0))
                 (inf (let ((v (fl- 1.0 (fl/ r2 12100.0))))
                        (if (fl<? v 0.0) 0.0 v)))
                 (k (fl* (fl/ 42000.0 r2) inf))
                 (ax (fl- (fl* px k) (fl* dx 30.0)))
                 (ay (fl- (fl* py k) (fl* dy 30.0)))
                 (nvx (fl* (fl+ vx (fl* ax 0.016)) 0.86))
                 (nvy (fl* (fl+ vy (fl* ay 0.016)) 0.86))
                 (ndx (fl+ dx (fl* nvx 0.016)))
                 (ndy (fl+ dy (fl* nvy 0.016))))
            (vector-set! c 3 ndx) (vector-set! c 4 ndy)
            (vector-set! c 5 nvx) (vector-set! c 6 nvy)
            (when (fl<? 0.001 (fl+ (fl+ (fl* ndx ndx) (fl* ndy ndy))
                                   (fl+ (fl* nvx nvx) (fl* nvy nvy))))
              (js-set! (vector-ref c 0) "transform"
                       (string-append "translate("
                                      (number->string ndx) "px,"
                                      (number->string ndy) "px)"))))
          (each (+ i 1))))))

  ;; the standalone driver: listeners plus an own rAF loop
  (define (glyphs-dodge! groups)
    (glyphs-track! groups)
    (letrec ((tick (lambda (t)
                     (for-each glyphs-step! groups)
                     (js-method (js-global) "requestAnimationFrame" tick)
                     (js-undefined))))
      (js-method (js-global) "requestAnimationFrame" tick))))
