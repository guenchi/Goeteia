;; The Why page's typeset effect: every plain-text heading is re-set
;; with (web typeset) -- the text measured by (web canvas), broken
;; into the same lines by (layout ...), each glyph its own absolute
;; span at the pen position the code-point walk assigns -- and the
;; glyphs dodge the cursor with a little spring-and-repulsion life.
;; The page's layout does not move: a hidden copy of the original
;; text keeps each heading's box; only the visible glyphs float.
;; Compiled ahead of time by build.sh; why-fx.js loads the wasm.
(import (rnrs) (web js) (web dom) (web typeset) (web canvas))

(define ($fl v) (if (flonum? v) v (exact->inexact v)))

(define (px s fallback)                 ; "28.5px" -> 28.5
  (let ((v ($fl (js->number (js-call (js-get (js-global) "parseFloat")
                                     (js-undefined) s)))))
    (if (fl=? v v) v fallback)))        ; NaN ("normal") -> fallback

;; one group per heading -- #(el html left top chars); a char is
;; #(style cx cy dx dy vx vy), its rest CENTER in element-local px
(define groups '())

;; the numbers in a computed style string, e.g. the two rgb() stops
;; of "linear-gradient(120deg, rgb(21, 80, 196), rgb(71, 136, 238))"
(define $numbers
  (js-eval "(s => { const m = String(s).match(/\\d+/g);
                    return m ? m.map(Number) : []; })"))

;; gradient text (background-clip: text + transparent color) clips
;; the ELEMENT's background to its own text -- absolute glyph spans
;; come out invisible.  Give each glyph a solid color sampled from
;; the gradient at its pen position instead; across the heading the
;; eye reads the same blend.
(define (gradient-sampler cs w)
  (and (string=? (js->string (js-get cs "color")) "rgba(0, 0, 0, 0)")
       (let ((ns (js-call $numbers (js-undefined)
                          (js-get cs "backgroundImage"))))
         (let ((n (js->number (js-get ns "length"))))
           (and (>= n 6)
                (let ((c (lambda (i)  ; the last six are r g b r g b
                           ($fl (js->number (js-index ns (+ (- n 6) i)))))))
                  (lambda (x)
                    (let* ((t (fl/ x (if (fl<? 1.0 w) w 1.0)))
                           (t (cond ((fl<? t 0.0) 0.0)
                                    ((fl<? 1.0 t) 1.0)
                                    (else t)))
                           (ch (lambda (i)
                                 (number->string
                                  (%fl->fx (fl+ (c i) (fl* t (fl- (c (+ i 3))
                                                                  (c i)))))))))
                      (string-append "color:rgb(" (ch 0) "," (ch 1) ","
                                     (ch 2) ");")))))))))

(define (build-el! el)
  (let* ((text (js->string (js-get el "textContent")))
         (cs (js-method (js-global) "getComputedStyle" el))
         (size (px (js->string (js-get cs "fontSize")) 16.0))
         (lh (px (js->string (js-get cs "lineHeight")) (fl* size 1.3)))
         (ls (px (js->string (js-get cs "letterSpacing")) 0.0))
         (font (string-append (js->string (js-get cs "fontStyle")) " "
                              (js->string (js-get cs "fontWeight")) " "
                              (js->string (js-get cs "fontSize")) " "
                              (js->string (js-get cs "fontFamily"))))
         (raw (canvas-measurer font))
         ;; per-code-point advances miss kerning, so their sum runs
         ;; ~1% past the whole-string width; scale them back so the
         ;; pen lands where the browser's text ends
         (whole (raw text))
         (cpsum (string-fold-cp
                 (lambda (acc cp start len)
                   (fl+ acc (raw (substring text start (+ start len)))))
                 0.0 text))
         (factor (if (fl<? 0.0 cpsum) (fl/ whole cpsum) 1.0))
         (measure (lambda (s) (fl+ (fl* (raw s) factor) ls)))
         ;; fractional width plus slack: a shrink-to-fit heading is
         ;; EXACTLY as wide as its text, and integer clientWidth or
         ;; measurement noise must not wrap what the browser didn't
         (bw ($fl (js->number
                   (js-get (js-method el "getBoundingClientRect") "width"))))
         (l (layout (prepare text measure) (fl+ (fl* bw 1.01) 2.0) lh))
         (grad (gradient-sampler cs bw))
         (html (js->string (js-get el "innerHTML")))
         (acc '()))
    (set-style! el "position" "relative")
    (set-text! el "")
    (let ((sizer (create-element "span")))  ; holds the original box
      (set-attribute! sizer "style" "visibility:hidden")
      (set-text! sizer text)
      (append-child! el sizer))
    (for-each
     (lambda (ln)
       (let ((y (line-y ln))
             (lt (line-text ln)))
         (string-fold-cp
          (lambda (pen cp start len)
            (let* ((g (substring lt start (+ start len)))
                   (cw (measure g)))
              (unless (= cp 32)
                (let ((span (create-element "span")))
                  (set-attribute! span "style"
                    (string-append "position:absolute;left:"
                                   (number->string pen) "px;top:"
                                   (number->string y) "px;"
                                   (if grad (grad (fl+ pen (fl/ cw 2.0))) "")))
                  (set-text! span g)
                  (append-child! el span)
                  (set! acc (cons (vector (js-get span "style")
                                          (fl+ pen (fl/ cw 2.0))
                                          (fl+ y (fl/ lh 2.0))
                                          0.0 0.0 0.0 0.0)
                                  acc))))
              (fl+ pen cw)))
          0.0 lt)))
     (layout-lines l))
    (vector el html 0.0 0.0 (list->vector (reverse acc)))))

;; a heading with inline markup (the em in a .sub) cannot go through
;; the plain-text path -- re-typesetting would eat the markup.  Ask
;; the browser instead: a Range around each character of each text
;; node yields its rendered rect; the glyph span goes INSIDE the
;; character's own parent (so an em's glyphs stay italic), and the
;; original run hides behind opacity:0, which never moves layout.
(define (build-mixed! el)
  (let* ((html (js->string (js-get el "innerHTML")))
         (erect (js-method el "getBoundingClientRect"))
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
         ;; Range offsets count utf-16 units, not the bridge's utf-8
         ;; bytes -- fold the code points and track units ourselves
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
         ;; hide the measured run in place; opacity keeps its layout
         (let ((hider (create-element "span")))
           (set-style! hider "opacity" "0")
           (insert-before! parent hider tn)
           (append-child! hider tn))))
     (reverse texts))
    (vector el html 0.0 0.0 (list->vector (reverse acc)))))

;; the elements' viewport rects, cached: reading them every frame
;; would force a layout pass -- they move only on scroll and resize
(define (rect! g)
  (let ((r (js-method (vector-ref g 0) "getBoundingClientRect")))
    (vector-set! g 2 ($fl (js->number (js-get r "left"))))
    (vector-set! g 3 ($fl (js->number (js-get r "top"))))))
(define (rects!) (for-each rect! groups))

(define (plain? el)                     ; markup goes the Range way
  (= 0 (js->number (js-get el "childElementCount"))))

(define (build!)
  (let* ((els (js-method (document) "querySelectorAll"
                         "h1, h2, .era, .lede, .note-sub, .sub"))
         (n (js->number (js-get els "length"))))
    (set! groups '())
    (let loop ((i 0))
      (when (< i n)
        (let ((el (js-index els i)))
          (set! groups (cons (if (plain? el) (build-el! el) (build-mixed! el))
                             groups)))
        (loop (+ i 1))))
    (rects!)))

(define (rebuild!)                      ; resize: restore, re-measure
  (for-each (lambda (g) (set-inner-html! (vector-ref g 0) (vector-ref g 1)))
            groups)
  (build!))

;; the pointer, in viewport coordinates (as the cached rects are)
(define pcx -9999.0)
(define pcy -9999.0)

;; the same spring-and-repulsion life as the hero's subtitle
(define (step-group! g)
  (let ((mx (fl- pcx (vector-ref g 2)))
        (my (fl- pcy (vector-ref g 3)))
        (chars (vector-ref g 4)))
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
          ;; touch the DOM only while it moves
          (when (fl<? 0.001 (fl+ (fl+ (fl* ndx ndx) (fl* ndy ndy))
                                 (fl+ (fl* nvx nvx) (fl* nvy nvy))))
            (js-set! (vector-ref c 0) "transform"
                     (string-append "translate("
                                    (number->string ndx) "px,"
                                    (number->string ndy) "px)"))))
        (each (+ i 1))))))

(define (tick t)
  (for-each step-group! groups)
  (js-method (js-global) "requestAnimationFrame" tick)
  (js-undefined))

;; a reader who asked for still text gets still text
(unless (js-truthy? (js-get (js-method (js-global) "matchMedia"
                                       "(prefers-reduced-motion: reduce)")
                            "matches"))
  (build!)
  (add-event-listener! (js-global) "pointermove"
    (lambda (e)
      (set! pcx ($fl (js->number (js-get e "clientX"))))
      (set! pcy ($fl (js->number (js-get e "clientY"))))
      (js-undefined)))
  (add-event-listener! (js-global) "resize"
    (lambda (e) (rebuild!) (js-undefined)))
  (add-event-listener! (js-global) "scroll"
    (lambda (e) (rects!) (js-undefined)))
  (js-method (js-global) "requestAnimationFrame" tick))
