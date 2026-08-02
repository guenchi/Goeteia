;; A library holding a mount point: its body's imports resolve in
;; their own scope, and both drivers must agree -- the text-level
;; driver only scanned the entry file until this case appeared.
(library (mountlib)
  (export lib-section)
  (import (rnrs))
  (define-wasm-js lib-section
    (import (web js))
    (display (js->number (js-eval "7")))))
