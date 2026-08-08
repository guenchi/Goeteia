;; A page with a heading, three paragraphs and a footer, built into
;; the host page's <div id="app">.
(import (rnrs) (web js) (web dom))

(define app (get-element-by-id "app"))

(define (el tag text)
  (let ((n (create-element tag)))
    (set-text! n text)
    n))

(append-child! app (el "h1" "Tea"))
(append-child! app (el "p" "Tea is made by pouring hot water over cured leaves of Camellia sinensis."))
(append-child! app (el "p" "Green, oolong and black tea come from the same plant; oxidation is what separates them."))
(append-child! app (el "p" "Water temperature and steeping time decide how much of the leaf ends up in the cup."))
(append-child! app (el "footer" "Brewed with Goeteia."))
(console-log "static page mounted")
