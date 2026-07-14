;; Components: css attached at the element, compiled to classes.
;;
;; The React lesson, taken at build time: the author writes styles ON
;; the element -- values are ordinary bindings, so changing one
;; changes every use -- and the library interns each distinct style
;; set to one generated class, so nine identical cards cost one rule.
;;
;;   (define-component (card title . body)
;;     (style (background (var bg2))
;;            (:hover (border-color (var lapis)))   ; pseudo-class
;;            ("h3" (margin 0))                     ; descendant
;;            (@media 42 (padding (em 1))))         ; max-width, em
;;     (div (h3 ,title) (p ,@body)))
;;
;; The template is implicitly quasiquoted -- an unquote is a hole --
;; the tag comes off its head, and the component's name doubles as
;; the class prefix.  (styled tag name style-set kid ...) is the
;; procedural form underneath; a leading (@ ...) kid contributes the
;; element's other attributes.  (styled-css) returns every interned
;; rule, in registration order, as a (web css) rule list -- append it
;; to the page's stylesheet before rendering.
;;
;; Discipline: interned classes are static and self-contained.
;; Runtime-dynamic styling belongs to signals and CSS variables, not
;; here -- the registry fills while the page is BUILT and renders
;; once, which is what keeps this free of the css-in-js runtime tax.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web component)
  (export styled styled-css define-component)
  (import (rnrs))

  (define $styled '())                  ; ((style-set . class) ...), newest first

  (define (intern-style! name sty)
    (cond
     ((assoc sty $styled) => cdr)       ; equal? style set -> same class
     (else
      (let ((cls (string-append (symbol->string name) "-"
                                (number->string (length $styled)))))
        (set! $styled (cons (cons sty cls) $styled))
        cls))))

  (define (styled tag name sty . kids)
    (let ((cls (intern-style! name sty)))
      (if (and (pair? kids) (pair? (car kids)) (eq? (car (car kids)) '@))
          `(,tag (@ (class ,cls) ,@(cdr (car kids))) ,@(cdr kids))
          `(,tag (@ (class ,cls)) ,@kids))))

  ;; every interned rule, in registration order, ready for css->string
  (define (styled-css)
    (apply append
           (map (lambda (e) ($styled-rules (cdr e) (car e)))
                (reverse $styled))))

  (define ($styled-rules cls sty)
    (let ((base (string-append "." cls)))
      (let loop ((ds sty) (plain '()) (extra '()))
        (if (null? ds)
            (cons (cons base (reverse plain)) (reverse extra))
            (let ((d (car ds)))
              (cond
               ((string? (car d))       ; ("h3" decls...): descendant
                (loop (cdr ds) plain
                      (cons (cons (string-append base " " (car d)) (cdr d))
                            extra)))
               ((eq? (car d) '@media)   ; (@media 42 decls...): max-width em
                (loop (cdr ds) plain
                      (cons `(@media ,(string-append "(max-width: "
                                                     (number->string (cadr d))
                                                     "em)")
                              ,(cons base (cddr d)))
                            extra)))
               ((and (symbol? (car d))  ; (:hover decls...): pseudo
                     (char=? (string-ref (symbol->string (car d)) 0) #\:))
                (loop (cdr ds) plain
                      (cons (cons (string-append base (symbol->string (car d)))
                                  (cdr d))
                            extra)))
               (else (loop (cdr ds) (cons d plain) extra))))))))

  ;; the markup and its css, one form.  The kids quasiquote as ONE
  ;; list, so a splicing hole may stand alone as a child --
  ;; (div (b "r") ,@cells) -- then apply spreads them.
  (define-syntax define-component
    (syntax-rules (style)
      ((_ (name . args) (style decl ...) (tag kid ...))
       (define (name . args)
         (apply styled 'tag 'name
                (quasiquote (decl ...))
                (quasiquote (kid ...))))))))
