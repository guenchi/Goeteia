;; T1 -- a static page.  This file IS the browser half: the page is
;; already open, this program's TOP LEVEL runs inside it, and every
;; word it shows it BUILDS through (web dom).  Nothing is generated
;; ahead of time and no file is ever written.
(import (rnrs) (web js) (web dom) (web css))

;; The two hosts the page guarantees: <div id="app"> for markup and
;; <canvas id="c"> (800x600) for pixels.  get-element-by-id on any
;; other id answers null, and the first call through a null reference
;; takes the whole program down -- so look the hosts up once, up top.
(define app (get-element-by-id "app"))

;; css->string is a pure function from a list of rules to CSS text,
;; so `append` composes stylesheets.  A unit's SECOND argument is the
;; fraction in HUNDREDTHS, padded to two places: (em 1 20) is 1.2em,
;; (em 0 90) is 0.9em, (em 0 9) is 0.09em.  Delicate values are safer
;; written as strings.  palette->root emits :root custom properties
;; that (var ink) reads back.
(define page-css
  `(,(palette->root '((ink "#14203a") (dim "#5b6580") (accent "#1550c4")))
    (body (margin 0) (color (var ink)) (line-height (dec 1 55))
          (font-family "system-ui, sans-serif"))
    ("#app" (max-width (em 46)) (margin 0 auto) (padding (em 3) (em 1 20)))
    (h1 (font-size (em 2 40)) (margin 0 0 (em 0 30)) (color (var accent)))
    (".lede" (color (var dim)) (font-size (em 1 10)))
    (footer (margin-top (em 2)) (color (var dim)) (font-size (em 0 90)))))

;; The stylesheet goes in the head, where its text is styling rather
;; than page content.
(let ((sheet (create-element "style")))
  (set-text! sheet (css->string page-css))
  (append-child! (js-get (document) "head") sheet))

;; create-element + set-text! + append-child! is the whole vocabulary
;; for putting content on a page.  set-inner-html! also exists, but it
;; hands one STRING to the host: a headless run stores that string and
;; parses no elements out of it, so a page built that way has nothing
;; to show and nothing to wire.  Build elements.
(define (add! tag class text)
  (let ((n (create-element tag)))
    (set-text! n text)                  ; textContent: no escaping dance
    (when class (set-attribute! n "class" class))
    (append-child! app n)
    n))

(add! "h1" #f "Built by a program")
(add! "p" "lede"
      "This page's markup and every CSS rule are one Scheme program, and it runs in the browser.")
(add! "p" #f
      "Text arrives through set-text!, attributes through set-attribute!, one inline property at a time through set-style!.")
(add! "p" #f
      "Source is read bytewise as latin-1, so non-ASCII text is fine to display but opaque to string-length and string-ref.")
(add! "footer" #f "Five blocks of text, every one of them built at run time.")

;; set-style! writes ONE inline property, and inline wins over a sheet
(set-style! app "border-top" "3px solid #1550c4")

(console-log "static page mounted")
