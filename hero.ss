;; The Goeteia homepage — rendered by Goeteia, compiled in your browser.
;; Edit this source and press Run: the page below re-renders live.
(import (web sx) (web dom) (web reactive))

;; a signal you can wire up: try (signal-set! spell ...) from an event
(define spell (signal "commanding what lies beneath"))

(define (hero)
  (sx (div (@ (class "hero"))
        (h1 "Goeteia")
        (p (@ (class "tagline"))
           (span (@ (class "gname")) "Γοητεία")
           ": The black art of " ,(signal-ref spell) ".")
        (p (@ (class "sub")) "A self-hosting Scheme for the WebAssembly GC era.")
        (pre (@ (class "cmd")) "$ git clone https://github.com/guenchi/Goeteia")
        (div (@ (class "links"))
          (a (@ (class "btn primary") (href "#editor")) "Try it now")
          (a (@ (class "btn") (href "https://github.com/guenchi/Goeteia")) "GitHub")))))

(sx-mount (get-element-by-id "live") (hero))
