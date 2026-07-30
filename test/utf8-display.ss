;; expect: café 世界
;; Program output is a UTF-8 byte stream; the Node host must decode it
;; before handing text to the CLI.
(display "café 世界")
