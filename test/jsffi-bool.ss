;; expect: #t
;; Regression: a boolean passed as a non-first argument to js-method
;; must not corrupt the shared argStack.  ->js on #t/#f used to nest a
;; js-eval (itself a js-call) mid-marshalling, shifting the earlier
;; args -- classList.toggle(c, #f) degenerated into eval("active").
(import (web js))
(define obj
  (js-eval "({ probe: function (a, b) { return a + ':' + arguments.length + ':' + b; } })"))
(and
 ;; string arg followed by a boolean: both must arrive intact
 (string=? (js->string (js-method obj "probe" "active" #f)) "active:2:false")
 (string=? (js->string (js-method obj "probe" "active" #t)) "active:2:true")
 ;; boolean in first position still works
 (string=? (js->string (js-method obj "probe" #f "x")) "false:2:x")
 ;; the cached refs are the genuine JS booleans
 (js-eq? (->js #t) (js-eval "true"))
 (js-eq? (->js #f) (js-eval "false"))
 (js-truthy? (->js #t))
 (not (js-truthy? (->js #f))))
