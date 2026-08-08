;; A range slider driving a readout: the handler reads the event
;; target's value and rewrites the text with it.
(import (rnrs) (web js) (web dom))

(define app (get-element-by-id "app"))

(define slider (create-element "input"))
(set-attribute! slider "type" "range")
(set-attribute! slider "min" "-40")
(set-attribute! slider "max" "120")
(set-attribute! slider "value" "20")
(set-attribute! slider "id" "c-in")

(define out (create-element "p"))
(set-attribute! out "id" "readout")

(define (show c)
  (set-text! out (string-append (number->string c)
                                " C = "
                                (number->string (+ 32 (quotient (* c 9) 5)))
                                " F")))

(add-event-listener!
 slider "input"
 (lambda (ev)
   (show (exact (floor (js->number (js-get (js-get ev "target") "value")))))))

(append-child! app slider)
(append-child! app out)
(show 20)
