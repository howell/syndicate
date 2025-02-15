#lang syndicate
;; Illustrates a (now fixed) bug where creating a facet interested in something
;; already known didn't properly trigger the assertion-handler.
;;
;; Symptomatic output:
;;
;; +outer "first"
;; +show
;; -show
;; -outer "first"
;; +outer "second"
;;
;; Correct output:
;;
;; +outer "first"
;; +show
;; +outer "second"
;; -show
;; -outer "first"
;; +show
;;
;; Should eventually be turned into some kind of test case.

(struct outer (v) #:prefab)
(struct show () #:prefab)

(spawn (field [v "first"])
       (assert (outer (v)))
       (assert (show))
       (on (message 2)
           (v "second")))

(spawn (on-start (send! 1))
       (during (outer $v)
               (on-start (log-info "+outer ~v" v))
               (on-stop (log-info "-outer ~v" v))
               (during (show)
                       (on-start (log-info "+show"))
                       (on-stop (log-info "-show"))))
       (on (message 1)
           (send! 2)))
