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
            (= (js->number (js-index doubled 2)) 6)))
     ;; a raise inside a callback answers undefined -- it must not
     ;; tear down the host's event loop -- but it must NOT be silent:
     ;; the default channel reports who and message on the console.
     ;; (A per-frame error once ran unreported for a whole project.)
     (begin
       (js-eval "globalThis.__cberr = [];
                 globalThis.__cbconsole = console.error;
                 console.error = (...a) =>
                   globalThis.__cberr.push(a.join(' '))")
       (let ((r (js-method (js-eval "[1]") "map"
                           (lambda _ (error 'boom "dies here" 42)))))
         (js-eval "console.error = globalThis.__cbconsole")
         (and (js-truthy? (js-eval "__cberr.length === 1"))
              (js-truthy? (js-eval "__cberr[0].includes('boom')"))
              (js-truthy? (js-eval "__cberr[0].includes('dies here')"))
              ;; the callback itself answered undefined, not a crash
              (not (js-truthy? (js-index r 0))))))
     ;; the channel is replaceable: a custom hook receives the
     ;; condition itself; #f restores the default
     (let ((got #f))
       (js-callback-error! (lambda (e) (set! got e)))
       (js-method (js-eval "[1]") "map"
                  (lambda _ (error 'hooked "custom" 9)))
       (js-callback-error! #f)
       (and (error? got)
            (eq? (condition-who got) 'hooked)
            (string=? (condition-message got) "custom")))
     ;; a non-condition raise still reports and still answers
     (begin
       (js-eval "globalThis.__cberr = [];
                 globalThis.__cbconsole = console.error;
                 console.error = (...a) =>
                   globalThis.__cberr.push(a.join(' '))")
       (js-method (js-eval "[1]") "map" (lambda _ (raise 'plain)))
       (js-eval "console.error = globalThis.__cbconsole")
       (js-truthy? (js-eval "__cberr.length === 1"))))
