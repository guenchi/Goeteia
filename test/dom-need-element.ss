;; expect: #t
;; (web dom): the id lookup that insists, beside the one that shrugs.
;;
;; get-element-by-id answers whatever the document answers, which for a
;; missing id is a falsy value that then gets written to: text goes in,
;; nothing appears on the page, and nothing is raised.  A caller that
;; knows the element must be there wants to be told at the lookup, with
;; the id in hand, not three frames later.
;;
;; Both are kept.  The weaker one is not renamed out of the way -- it is
;; an existing export and renaming it would break callers -- but the new
;; one is named for what it does rather than being get-element-by-id
;; with a suffix, so neither reads like the default.
(import (rnrs) (web js) (web dom))

(js-eval "globalThis.document = { __els: { present: {id:'present'} },
  getElementById(id){ return (id in this.__els) ? this.__els[id] : null } };")

(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))
(define (has-sub? hay needle)
  (let ((h (string-length hay)) (n (string-length needle)))
    (let loop ((i 0))
      (cond ((> (+ i n) h) #f)
            ((string=? (substring hay i (+ i n)) needle) #t)
            (else (loop (+ i 1)))))))

(check "the insisting one answers the element when it is there"
       (js-truthy? (need-element-by-id "present")))
(check "the shrugging one still answers a falsy value when it is not"
       (not (js-truthy? (get-element-by-id "gone"))))
(check "the insisting one refuses, and names the id it was given"
       (guard (e ((error? e)
                  (and (has-sub? (condition-message e) "id")
                       (member "gone" (map (lambda (x) (if (string? x) x ""))
                                           (condition-irritants e)))
                       #t))
                 (else #f))
         (begin (need-element-by-id "gone") #f)))
(display (= failed 0))
