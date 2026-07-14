;; DOM-free text layout: measure once, lay out anywhere.
;;
;; The (gfx glsl) of text -- layout is a pure function from prepared
;; metrics to line boxes, so heights are known before anything touches
;; the DOM (virtual scrolls, streaming chat) and text can be set in
;; canvas/WebGL scenes, where there is no layout engine at all.
;;
;; Two phases, after pretext (https://www.pretext.cool):
;;   (prepare text measure)           ; measure each distinct code point once
;;   (layout p max-width line-height) ; pure arithmetic; no DOM, no reflow
;;
;; `measure` maps a one-code-point string to its advance width and is
;; the only place a host appears: (web canvas) supplies one
;; backed by canvas measureText for browsers, tests pass arithmetic
;; stand-ins, a font-table parser could serve wasmtime.  Widths and
;; max-width share whatever unit `measure` returns (typically px).
;;
;;   (prepared-width p)     natural width: the widest line when
;;                          wrapping only at hard newlines
;;   (layout-height l) (layout-line-count l)
;;   (layout-lines l)       line records, top to bottom:
;;     (line-text ln) (line-width ln) (line-y ln)
;;
;; Breaking (greedy first-fit):
;;   #\newline is a hard break; a text always yields at least one line
;;   soft breaks fall at space runs; the spaces a soft wrap lands on
;;   vanish (as CSS collapses them), spaces after a hard break survive
;;   breaks may fall between CJK code points (ideographs, kana,
;;   hangul, fullwidth forms) with no space needed -- except kinsoku:
;;   closing punctuation never starts a line (it merges into the box
;;   before it) and opening brackets never end one (they stick to the
;;   box after them)
;;   a word wider than the line breaks inside, by code point
;;
;; The model is advance widths summed per code point -- no shaping,
;; kerning, ligatures, or bidi.  Widths are estimates for
;; DOM-rendered text (good for virtual-scroll heights) and exact for
;; text the caller renders glyph by glyph (canvas/GL).
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web typeset)
  (export prepare prepared? prepared-width
          layout layout? layout-height layout-line-count layout-lines
          line? line-text line-width line-y
          string-fold-cp)
  (import (rnrs))

  ;; strings are UTF-8 byte arrays; walk them by code point
  (define ($byte s i) (char->integer (string-ref s i)))
  (define ($cp-len b)                   ; sequence length from lead byte
    (cond ((< b #x80) 1) ((< b #xE0) 2) ((< b #xF0) 3) (else 4)))
  (define ($cp-at s i)                  ; code point with lead byte at i
    (let ((b0 ($byte s i)))
      (cond
       ((< b0 #x80) b0)
       ((< b0 #xE0) (+ (* (- b0 #xC0) 64) (- ($byte s (+ i 1)) #x80)))
       ((< b0 #xF0) (+ (* (- b0 #xE0) 4096)
                       (* (- ($byte s (+ i 1)) #x80) 64)
                       (- ($byte s (+ i 2)) #x80)))
       (else (+ (* (- b0 #xF0) 262144)
                (* (- ($byte s (+ i 1)) #x80) 4096)
                (* (- ($byte s (+ i 2)) #x80) 64)
                (- ($byte s (+ i 3)) #x80))))))

  ;; fold over a string's code points: proc gets (acc cp byte-start
  ;; byte-len) -- indices, not substrings, so the hot path allocates
  ;; nothing; slice with substring only when needed
  (define (string-fold-cp proc seed s)
    (let ((len (string-length s)))
      (let loop ((i 0) (acc seed))
        (if (= i len)
            acc
            (let ((n ($cp-len ($byte s i))))
              (loop (+ i n) (proc acc ($cp-at s i) i n)))))))

  ;; a break may fall on either side of these without a space
  (define ($cjk? cp)
    (or (and (<= #x3000 cp) (<= cp #x30FF))   ; CJK punct, hiragana, katakana
        (and (<= #x3400 cp) (<= cp #x4DBF))   ; ideographs ext A
        (and (<= #x4E00 cp) (<= cp #x9FFF))   ; unified ideographs
        (and (<= #xAC00 cp) (<= cp #xD7AF))   ; hangul syllables
        (and (<= #xF900 cp) (<= cp #xFAFF))   ; compat ideographs
        (and (<= #xFF00 cp) (<= cp #xFFEF)))) ; fullwidth forms

  ;; kinsoku: these may not START a line -- closing punctuation,
  ;; small kana, the prolonged-sound mark -- so they merge into the
  ;; box before them and wrap as one unit
  (define $no-start-cps
    '(#x3001 #x3002 #x30FB #x3005 #x309D #x309E #x30FD #x30FE #x30FC
      #x300D #x300F #x3009 #x300B #x3011 #x3015 #x2019 #x201D
      #x2025 #x2026
      #xFF01 #xFF09 #xFF0C #xFF0E #xFF1A #xFF1B #xFF1F #xFF5D
      #x3041 #x3043 #x3045 #x3047 #x3049 #x3063
      #x3083 #x3085 #x3087 #x308E
      #x30A1 #x30A3 #x30A5 #x30A7 #x30A9 #x30C3
      #x30E3 #x30E5 #x30E7 #x30EE #x30F5 #x30F6))
  ;; and these may not END a line -- opening brackets and quotes --
  ;; so they stick to whatever box comes next
  (define $no-end-cps
    '(#x300C #x300E #x3008 #x300A #x3010 #x3014 #x2018 #x201C
      #xFF08 #xFF5B))

  ;; tokens: an unbreakable box, droppable glue, or a hard break
  (define-record-type ($tok $make-tok $tok?)
    (fields (immutable kind $tok-kind)        ; box | glue | hard
            (immutable str $tok-str)
            (immutable w $tok-w)))

  (define-record-type (prepared $make-prepared prepared?)
    (fields (immutable toks $prepared-toks)
            (immutable wtab $prepared-wtab)   ; code point -> advance width
            (immutable width prepared-width)))

  (define-record-type ($layout $make-layout layout?)
    (fields (immutable height layout-height)
            (immutable line-count layout-line-count)
            (immutable lines layout-lines)))

  (define-record-type ($line $make-line line?)
    (fields (immutable text line-text)
            (immutable width line-width)
            (immutable y line-y)))

  (define ($natural-width toks)         ; widest hard-break-only line
    (let loop ((ts toks) (cur 0) (best 0))
      (cond
       ((null? ts) (max best cur))
       ((eq? ($tok-kind (car ts)) 'hard) (loop (cdr ts) 0 (max best cur)))
       (else (loop (cdr ts) (+ cur ($tok-w (car ts))) best)))))

  ;; one pass over the bytes; measure runs once per distinct code
  ;; point.  The pending run's kind is glue | word | cjk (word grows
  ;; with word chars, cjk is closed); sticky means the pending box may
  ;; not end a line yet -- the next box char merges into it.
  (define (prepare text measure)
    (let ((wtab (make-eq-hashtable))
          (len (string-length text)))
      (define (cp-w cp i n)             ; cached advance width
        (let ((w (hashtable-ref wtab cp #f)))
          (or w
              (let ((w (measure (substring text i (+ i n)))))
                (hashtable-set! wtab cp w)
                w))))
      (define (flush kind st i w toks)  ; end the pending run
        (if kind
            (cons ($make-tok (if (eq? kind 'glue) 'glue 'box)
                             (substring text st i) w)
                  toks)
            toks))
      (let loop ((i 0) (kind #f) (st 0) (w 0) (toks '()) (sticky #f))
        (if (= i len)
            (let ((ts (reverse (flush kind st i w toks))))
              ($make-prepared ts wtab ($natural-width ts)))
            (let* ((cp ($cp-at text i))
                   (n ($cp-len ($byte text i))))
              (cond
               ((= cp 10)               ; hard break
                (loop (+ i n) #f (+ i n) 0
                      (cons ($make-tok 'hard "\n" 0)
                            (flush kind st i w toks))
                      #f))
               ((or (= cp 32) (= cp 9)) ; glue run
                (let ((cw (cp-w cp i n)))
                  (if (eq? kind 'glue)
                      (loop (+ i n) 'glue st (+ w cw) toks #f)
                      (loop (+ i n) 'glue i cw
                            (flush kind st i w toks) #f))))
               ((memq cp $no-start-cps) ; merge into the box before it
                (let ((cw (cp-w cp i n)))
                  (if (memq kind '(word cjk))
                      (loop (+ i n) 'cjk st (+ w cw) toks sticky)
                      ;; nothing to hold on to (line start, after glue)
                      (loop (+ i n) 'cjk i cw
                            (flush kind st i w toks) #f))))
               ((memq cp $no-end-cps)   ; stick to the box after it
                (let ((cw (cp-w cp i n)))
                  (if (and sticky (memq kind '(word cjk)))
                      (loop (+ i n) 'cjk st (+ w cw) toks #t)
                      (loop (+ i n) 'cjk i cw
                            (flush kind st i w toks) #t))))
               (($cjk? cp)              ; its own box, breakable both sides
                (let ((cw (cp-w cp i n)))
                  (if (and sticky (memq kind '(word cjk)))
                      (loop (+ i n) 'cjk st (+ w cw) toks #f)
                      (loop (+ i n) 'cjk i cw
                            (flush kind st i w toks) #f))))
               (else                    ; word run
                (let ((cw (cp-w cp i n)))
                  (cond
                   ((and sticky (memq kind '(word cjk)))
                    (loop (+ i n) 'word st (+ w cw) toks #f))
                   ((eq? kind 'word)
                    (loop (+ i n) 'word st (+ w cw) toks #f))
                   (else
                    (loop (+ i n) 'word i cw
                          (flush kind st i w toks) #f)))))))))))

  ;; pure arithmetic over the prepared tokens
  (define (layout p max-width line-height)
    (let ((wtab ($prepared-wtab p)))
      ;; an over-wide box: fill by code point, at least one per line;
      ;; full lines go to acc, the tail returns as (str w acc)
      (define (split-box str acc)
        (let ((n (string-length str)))
          (let loop ((i 0) (st 0) (w 0) (acc acc))
            (if (= i n)
                (list (substring str st i) w acc)
                (let ((k ($cp-len ($byte str i)))
                      (cw (hashtable-ref wtab ($cp-at str i) 0)))
                  (if (and (> (+ w cw) max-width) (< st i))
                      (loop i i 0 (cons (cons (substring str st i) w) acc))
                      (loop (+ i k) st (+ w cw) acc)))))))
      (define (line<- cur w)            ; cur is the reversed piece list
        (cons (apply string-append (reverse cur)) w))
      (define (finish acc)              ; assign y, count, total height
        (let* ((ls (reverse acc))
               (n (length ls)))
          (let loop ((ls ls) (i 0) (out '()))
            (if (null? ls)
                ($make-layout (* n line-height) n (reverse out))
                (loop (cdr ls) (+ i 1)
                      (cons ($make-line (caar ls) (cdar ls)
                                        (* i line-height))
                            out))))))
      ;; cur/curw: the line so far; pend/pendw: trailing glue, kept
      ;; only until a soft wrap lands on it; dropg: eat leading glue
      ;; on the line after a soft wrap
      (let loop ((ts ($prepared-toks p))
                 (cur '()) (curw 0) (pend '()) (pendw 0) (dropg #f)
                 (acc '()))
        (if (null? ts)
            (finish (cons (line<- (append pend cur) (+ curw pendw)) acc))
            (let ((t (car ts)))
              (cond
               ((eq? ($tok-kind t) 'hard)
                (loop (cdr ts) '() 0 '() 0 #f
                      (cons (line<- (append pend cur) (+ curw pendw)) acc)))
               ((eq? ($tok-kind t) 'glue)
                (if (and dropg (null? cur))
                    (loop (cdr ts) cur curw pend pendw dropg acc)
                    (loop (cdr ts) cur curw
                          (cons ($tok-str t) pend) (+ pendw ($tok-w t))
                          dropg acc)))
               ;; a box
               ((<= (+ curw pendw ($tok-w t)) max-width)
                (loop (cdr ts)
                      (cons ($tok-str t) (append pend cur))
                      (+ curw pendw ($tok-w t))
                      '() 0 dropg acc))
               ((pair? cur)             ; soft wrap; the glue vanishes
                (loop ts '() 0 '() 0 #t (cons (line<- cur curw) acc)))
               ((pair? pend)            ; lone leading glue can't hold it
                (loop ts '() 0 '() 0 #t acc))
               (else                    ; wider than the line by itself
                (let ((r (split-box ($tok-str t) acc)))
                  (loop (cdr ts) (list (car r)) (cadr r) '() 0 #t
                        (caddr r)))))))))))
