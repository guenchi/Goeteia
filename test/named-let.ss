;; expect: 500000
(import (rnrs))
(let loop ((i 0))
  (if (= i 500000) i (loop (+ i 1))))
