;; expect: #t
;; REGRESSION GUARD (written as a red witness at b6e9fcb; green since).
;; The defect as it then was: styled emits a second class attribute when
;; the caller's attribute list already has one.
;;
;;   <div class="card-0" class="mine" id="x">hi</div>
;;
;; The consequence is not "invalid markup".  A duplicate attribute
;; is a parse error and every browser keeps the FIRST, so the class the
;; author wrote is silently discarded -- their own styling does
;; nothing, on an element that looks correct in the source.
;;
;; The expectation is "one class attribute carrying both names", not
;; a particular spelling of it.  Attribute-internal order does not
;; affect CSS, so pinning "card-0 mine" rather than "mine card-0" would
;; promote an irrelevant detail into a contract and refuse a correct
;; fix that happened to order them the other way.  -> The cells below
;; count the attribute and look for both tokens.
;;
;; The controls are the two shapes that already work and a fix could
;; break: no attribute list at all, and an attribute list with no class
;; in it, whose other attributes must survive.
(import (rnrs) (web component) (web html))
(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))

;; count occurrences of `needle` in `s`
(define (occurs s needle)
  (let* ((n (string-length needle)) (e (- (string-length s) n)))
    (let loop ((i 0) (k 0))
      (cond ((> i e) k)
            ((string=? (substring s i (+ i n)) needle) (loop (+ i 1) (+ k 1)))
            (else (loop (+ i 1) k))))))
(define (has? s needle) (> (occurs s needle) 0))

(define a (sxml->html (styled 'div 'card '((color "red"))
                              (list '@ (list 'class "mine") (list 'id "x")) "hi")))
(want 'w03-one-class-attribute (occurs a "class=") 1)
(want 'w03-keeps-callers-class (has? a "mine") #t)
(want 'w03-keeps-styled-class (has? a "card-") #t)
(want 'w03-keeps-other-attrs (has? a "id=\"x\"") #t)

;; ---- controls ----
(define b (sxml->html (styled 'div 'plain '((color "blue")) "hi")))
(want 'w03-CONTROL-no-attrs (occurs b "class=") 1)
(define c (sxml->html (styled 'div 'other '((color "green"))
                              (list '@ (list 'id "y")) "hi")))
(want 'w03-CONTROL-attrs-without-class (occurs c "class=") 1)
(want 'w03-CONTROL-other-attrs-survive (has? c "id=\"y\"") #t)

(if (null? fails) (display #t) (begin (display fails) (newline)))
