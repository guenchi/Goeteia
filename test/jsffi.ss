;; expect: #t
(import (web js))
(define G (js-global))
(and ;; property chains and method calls on real host objects
     (js-ref? G)
     (= (js->number (js-method (js-get G "Math") "floor" 3.7)) 3)
     (= (js->number (js-method (js-get G "Math") "max" 3 7 5)) 7)
     ;; string round trip
     (string=? (js->string (string->js "hello")) "hello")
     (string=? (js->string (js-method (string->js "abc") "toUpperCase")) "ABC")
     ;; numbers come back exact when integral
     (fixnum? (js->number (js-method (js-get G "Math") "floor" 3.7)))
     ;; constructors
     (let ((arr (js-new (js-get G "Array") 1 2 3)))
       (= (js->number (js-get arr "length")) 3))
     ;; identity and truthiness
     (js-eq? G G)
     (js-truthy? (string->js "x"))
     (not (js-truthy? (js-undefined)))
     ;; eval as an escape hatch
     (= (js->number (js-eval "6 * 7")) 42)
     ;; the crown jewel: a Scheme closure crossing into JS and being
     ;; called back with arguments
     (let* ((arr (js-eval "[1, 2, 3]"))
            (doubled (js-method arr "map"
                                (lambda (x . _)
                                  (number->js (* 2 (js->number x)))))))
       (and (= (js->number (js-index doubled 0)) 2)
            (= (js->number (js-index doubled 1)) 4)
            (= (js->number (js-index doubled 2)) 6))))
