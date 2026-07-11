;; Goeteia components for embedding into a React app -- see
;; react-embed.html.  Interior state lives in signals; React only
;; owns the host element and the props.
(import (web reactive) (web sx) (web js) (web react))

(react-component "Counter"
  (lambda (container props)
    (let* ((start (let ((v (props-ref props "start")))
                    (if v (js->number v) 0)))
           (n (signal start)))
      (sx-mount container
        (sx (div (@ (class "g-counter"))
              (button (@ (on-click ,(lambda _
                                      (signal-update! n
                                        (lambda (v) (- v 1))))))
                "-")
              (span ,(signal-ref n))
              (button (@ (on-click ,(lambda _
                                      (signal-update! n
                                        (lambda (v) (+ v 1))))))
                "+")))))))

(react-component "Ticker"
  (lambda (container props)
    (let ((n (signal 0)))
      (sx-mount container
        (sx (div (@ (class "g-ticker"))
              "alive for " (span ,(signal-ref n)) " s")))
      (let ((id (js-call (js-get (js-global) "setInterval") (js-undefined)
                         (lambda _ (signal-update! n (lambda (v) (+ v 1))))
                         1000)))
        (lambda ()
          (js-call (js-get (js-global) "clearInterval") (js-undefined) id)
          (remove-all-children! container))))))
