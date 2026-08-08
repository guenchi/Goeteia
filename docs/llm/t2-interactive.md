# T2 — an interactive page

**New at this layer.** Controls do not come with the page. The program
creates each `<input>`, sets its attributes, appends it to `#app` and
wires it with `add-event-listener!`; the callback returns
`(js-undefined)`, and the value it reads off the event target is a
STRING. The two numeric rules that break most pages appear here for
real: `js->number` hands back a **fixnum** at every integral value and
the `fl` operators trap on fixnums, so a `num` helper normalizes once
at the boundary; and `fl->fx` truncates, so rounding is
`(exact (flfloor (fl+ x 0.5)))`. Hundredths are formatted with exact
integer arithmetic — the flonum printer is noisy. Plain mutable state
plus one `render!` is enough at this size; `(web reactive)`'s
`signal` / `effect` works at the top level too, and re-runs an effect
whenever a signal it read changes.

```scheme
;; T2 -- an interactive page.  Same shape as T1: this file IS the
;; browser half.  Controls do not come with the page -- the program
;; creates them, appends them, wires them, and reads them back.
(import (rnrs) (web js) (web dom))

(define app (get-element-by-id "app"))

;; js->number answers a FIXNUM whenever the JS value is integral -- a
;; range input at any stop is integral -- and every fl operator TRAPS
;; on a fixnum.  Normalize once, at the boundary.  num takes a JS
;; value; a Scheme number goes through exact->inexact instead
;; (js->number on a Scheme fixnum is itself an illegal cast).
(define (num v) (exact->inexact (js->number v)))

;; fl->fx TRUNCATES, so rounding needs the +0.5
(define (round->fx f) (exact (flfloor (fl+ f 0.5))))

;; hundredths as an exact two-place decimal: flonum printing is
;; noisy, integer arithmetic is not
(define (fmt2 n)
  (let ((w (quotient n 100)) (f (remainder n 100)))
    (string-append (number->string w) "."
                   (if (< f 10) "0" "") (number->string f))))

;; A control is four set-attribute! calls and an append-child!.  The
;; id is for the program's own benefit; nothing outside can see it.
(define (slider id lo hi start)
  (let ((s (create-element "input")))
    (set-attribute! s "type" "range")
    (set-attribute! s "min" lo)
    (set-attribute! s "max" hi)
    (set-attribute! s "step" "1")
    (set-attribute! s "value" start)
    (set-attribute! s "id" id)
    (append-child! app s)
    s))

(define bill-in (slider "bill" "0" "20000" "4500"))
(define rate-in (slider "rate" "0" "40" "15"))
(define readout (create-element "p"))
(append-child! app readout)

;; Plain mutable state and one render! is enough for a page this
;; size.  (web reactive) offers signal / effect -- an effect re-runs
;; whenever a signal it READ changes, so there is no manual
;; invalidation -- and works here at the top level just as well.
(define $bill 4500)                     ; cents, exact
(define $rate 15)                       ; percent, exact

(define (render!)
  (let ((tip (quotient (+ (* $bill $rate) 50) 100)))
    (set-text! readout
               (string-append "bill " (fmt2 $bill)
                              " + " (number->string $rate) "% tip "
                              (fmt2 tip) " = " (fmt2 (+ $bill tip))))))

;; A DOM value is a STRING; js->number converts it, num makes it a
;; flonum whatever the string looked like.  Event callbacks return
;; (js-undefined).
(define (on-slide! el receive)
  (add-event-listener! el "input"
    (lambda (ev)
      (receive (round->fx (num (js-get (js-get ev "target") "value"))))
      (render!)
      (js-undefined))))

(on-slide! bill-in (lambda (v) (set! $bill v)))
(on-slide! rate-in (lambda (v) (set! $rate v)))

(render!)                               ; the first paint is the program's job
```
