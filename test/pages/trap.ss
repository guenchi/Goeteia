;; Compiles clean and traps on its first run: car of something that is
;; not a pair is a wasm type assertion (illegal cast), and the message
;; carries no source position.  The value comes from string->number, so
;; no pass can see at compile time that it is not a pair.
;;
;; Until batch M50 (ledger R76) this page trapped on
;; (bitwise-and (* 100000 100000) 255): a product past the i31 fixnum
;; range on the bitwise path.  The bitwise operators take exact integers
;; of any size now, and that expression answers 0.
(import (rnrs) (web dom))

(define x (string->number "5"))

(set-text! (get-element-by-id "app")
           (number->string (car x)))
