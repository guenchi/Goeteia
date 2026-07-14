;; expect: #t
;; (web component): element-attached css interned to generated
;; classes; define-component carries markup and style in one form.
(import (rnrs) (web css) (web component))

(define-component (chip label)
  (style (background "#eef1f9")
         (:hover (color (var lapis)))
         ("b" (font-weight 600))
         (@media 42 (padding (em 1))))
  (span "· " ,label))

(define a (chip "one"))
(define b (chip "two"))

(and
 ;; the generated class, then the template with its hole filled
 (equal? a '(span (@ (class "chip-0")) "· " "one"))
 ;; an equal style set interns to the SAME class
 (equal? b '(span (@ (class "chip-0")) "· " "two"))
 ;; the procedural form; a leading (@ ...) kid keeps its attributes
 (equal? (styled 'i 'x '((margin 0)) '(@ (id "k")) "t")
         '(i (@ (class "x-1") (id "k")) "t"))
 ;; splicing holes work through the implicit quasiquote
 (let ()
   (define-component (row . cells)
     (style (display flex))
     (div (b "r") ,@cells))
   (equal? (row "a" "b")
           '(div (@ (class "row-2")) (b "r") "a" "b")))
 ;; collected rules render in registration order: base, pseudo,
 ;; descendant, then the media block
 (string=?
  (css->string (styled-css))
  (string-append
   ".chip-0{background:#eef1f9;}"
   ".chip-0:hover{color:var(--lapis);}"
   ".chip-0 b{font-weight:600;}"
   "@media (max-width: 42em){.chip-0{padding:1em;}}"
   ".x-1{margin:0;}"
   ".row-2{display:flex;}")))
