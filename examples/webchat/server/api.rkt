#lang syndicate

(require/activate syndicate/reload)
(require/activate syndicate/supervise)
(require/activate syndicate/broker/server)
(require/activate syndicate/drivers/web)
(require/activate "trust.rkt")

(require "protocol.rkt")
(require "session-cookie.rkt")

(spawn #:name 'broker-listener
       (stop-when-reloaded)
       (on (web-request-get (id req) _ ("broker" ()))
           (when (web-request-header-websocket-upgrade? req)
             (with-session id
               [(email sid)
                (define (scope v) (api (session email sid) v))
                (spawn-broker-server-connection
                 id
                 req
                 #:scope scope
                 #:hook (lambda ()
                          (stop-when (message (end-session sid)))
                          (stop-when (message (delete-resource (account email))))))]
               [else
                (web-respond/xexpr! id
                                    #:header (web-response-header #:code 401
                                                                  #:message #"Unauthorized")
                                    `(html (body (h1 "Unauthorized")
                                                 (a ((href "/")) "Login"))))]))))

(supervise
 (spawn #:name 'reflect-trust
        (stop-when-reloaded)
        (during (session $who _)
          (during ($ p (permitted _ who _ _))
            (assert (api (session who _) p)))
          (during ($ r (permission-request _ who _))
            (assert (api (session who _) r)))
          (during ($ g (grant _ who _ _ _))
            (assert (api (session who _) g)))
          (during ($ c (contact-list-entry who _))
            (assert (api (session who _) c))))))

(supervise
 (spawn #:name 'reflect-grant-requests
        (stop-when-reloaded)
        (during (permission-request $issuer $grantee $permission)
          (define r (permission-request issuer grantee permission))
          (during (permitted issuer $grantor permission #t)
            (assert (api (session grantor _) r))
            (on (message (api (session grantor _) (delete-resource r)))
                (send! (delete-resource r)))))))

(supervise
 (spawn #:name 'take-trust-instructions
        (stop-when-reloaded)

        (on (message (api (session $grantor _) (create-resource (? grant? $g))))
            (when (equal? grantor (grant-grantor g))
              (send! (create-resource g))))
        (on (message (api (session $grantor _) (delete-resource (? grant? $g))))
            (when (or (equal? grantor (grant-grantor g))
                      (equal? grantor (grant-issuer g)))
              (send! (delete-resource g))))

        (on (message (api (session $principal _) (delete-resource (? permitted? $p))))
            (when (or (equal? principal (permitted-email p)) ;; relinquish
                      (equal? principal (permitted-issuer p))) ;; revoke; TODO: deal with delegation
              (send! (delete-resource p))))

        (on (message (api (session $grantee _) (create-resource (? permission-request? $r))))
            (when (equal? grantee (permission-request-grantee r))
              (send! (create-resource r))))
        (on (message (api (session $grantee _) (delete-resource (? permission-request? $r))))
            (when (equal? grantee (permission-request-grantee r))
              (send! (delete-resource r))))))
