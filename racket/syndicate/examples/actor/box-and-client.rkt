#lang syndicate
;; Simple mutable box and count-to-infinity box client.

(message-struct set-box (new-value))
(assertion-struct box-state (value))

(spawn (field [current-value 0])
       (assert (box-state (current-value)))
       (stop-when-true (= (current-value) 10)
                       (log-info "box: terminating"))
       (on (message (set-box $new-value))
           (log-info "box: taking on new-value ~v" new-value)
           (current-value new-value)))

(spawn (stop-when (retracted (observe (set-box _)))
                  (log-info "client: box has gone"))
       (on (asserted (box-state $v))
           (log-info "client: learned that box's value is now ~v" v)
           (send! (set-box (+ v 1)))))
