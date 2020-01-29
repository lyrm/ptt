open Colombe.Sigs
open Rresult
open Sigs

module Make
    (Scheduler : SCHEDULER)
    (IO : IO with type 'a t = 'a Scheduler.s)
  : sig
    module Md : module type of Messaged.Make(Scheduler)(IO)

    type 'r resolver =
      { gethostbyname : 'a. 'r -> [ `host ] Domain_name.t -> (Ipaddr.V4.t, [> R.msg ] as 'a) result IO.t
      ; getmxbyname : 'a. 'r -> [ `host ] Domain_name.t -> (Dns.Rr_map.Mx_set.t, [> R.msg ] as 'a) result IO.t
      ; extension : 'a. string -> string -> (Ipaddr.V4.t, [> R.msg ] as 'a) result IO.t }

    type 'r server

    type info = SMTP.info =
      { domain : [ `host ] Domain_name.t
      ; ipv4 : Ipaddr.V4.t
      ; tls : Tls.Config.server
      ; size : int64 }

    val info : 'r server -> info
    val resolver : 'r server -> 'r resolver

    type error

    val pp_error : error Fmt.t

    val create : info:info -> 'r resolver -> 'r server
    val messaged : 'r server -> Md.t
    val accept : ('flow, Scheduler.t) rdwr -> 'flow -> 'r -> 'r server -> (unit, error) result IO.t
  end