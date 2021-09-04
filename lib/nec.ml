open Rresult
open Ptt_tuyau.Lwt_backend
open Lwt.Infix

module Make
    (Random : Mirage_random.S)
    (Time : Mirage_time.S)
    (Mclock : Mirage_clock.MCLOCK)
    (Pclock : Mirage_clock.PCLOCK)
    (Resolver : Ptt.Sigs.RESOLVER with type +'a io = 'a Lwt.t)
    (Stack : Mirage_stack.V4V6) =
struct
  include Ptt_tuyau.Make (Stack)

  let src = Logs.Src.create "nec"

  module Log : Logs.LOG = (val Logs.src_log src)

  module Random = struct
    type g = Random.g
    type +'a io = 'a Lwt.t

    let generate ?g buf =
      let len = Bytes.length buf in
      let raw = Random.generate ?g len in
      Cstruct.blit_to_bytes raw 0 buf 0 len
      ; Lwt.return ()
  end

  module Signer =
    Ptt.Relay.Make (Lwt_scheduler) (Lwt_io) (Flow) (Resolver) (Random)
  (* XXX(dinosaure): the [signer] is a simple relay. *)

  module Server = Ptt_tuyau.Server (Time) (Stack)
  include Ptt_transmit.Make (Pclock) (Stack) (Signer.Md)

  let smtp_signer_service ?stop ~port stack resolver conf_server =
    Server.init ~port stack >>= fun service ->
    let handler flow =
      let ip, port = Stack.TCP.dst flow in
      let v = Flow.make flow in
      Lwt.catch
        (fun () ->
          Signer.accept v resolver conf_server
          >|= R.reword_error (R.msgf "%a" Signer.pp_error)
          >>= fun res ->
          Stack.TCP.close flow >>= fun () -> Lwt.return res)
        (function
          | Failure err -> Lwt.return (R.error_msg err)
          | exn -> Lwt.return (Error (`Exn exn)))
      >>= function
      | Ok () ->
        Log.info (fun m -> m "<%a:%d> submitted a message" Ipaddr.pp ip port)
        ; Lwt.return ()
      | Error (`Msg err) ->
        Log.err (fun m -> m "<%a:%d> %s" Ipaddr.pp ip port err)
        ; Lwt.return ()
      | Error (`Exn exn) ->
        Log.err (fun m ->
            m "<%a:%d> raised an unknown exception: %s" Ipaddr.pp ip port
              (Printexc.to_string exn))
        ; Lwt.return () in
    let (`Initialized fiber) = Server.serve_when_ready ?stop ~handler service in
    fiber

  let ( <+> ) s0 s1 =
    let current = ref s0 in
    let rec next () =
      !current () >>= function
      | Some _ as v -> Lwt.return v
      | None ->
        if !current == s0 then (
          current := s1
          ; next ())
        else Lwt.return_none in
    next

  let to_lwt_stream stream () =
    match stream () with
    | Some str -> Lwt.return_some (str, 0, String.length str)
    | None -> Lwt.return_none

  let smtp_logic ~info stack resolver messaged (private_key, dkim) map =
    let rec go () =
      Signer.Md.await messaged >>= fun () ->
      Signer.Md.pop messaged >>= function
      | None -> Lwt.pause () >>= go
      | Some (key, queue, consumer) ->
        let sign_and_transmit () =
          Dkim_mirage.sign ~key:private_key ~newline:Dkim.CRLF consumer dkim
          >>= fun (dkim', consumer') ->
          Signer.resolve_recipients ~domain:info.Ptt.SSMTP.domain resolver map
            (List.map fst (Ptt.Messaged.recipients key))
          >>= fun recipients ->
          let dkim' =
            to_lwt_stream
            @@ Prettym.to_stream ~new_line:"\r\n" Dkim.Encoder.as_field dkim'
          in
          transmit ~info stack (key, queue, dkim' <+> consumer') recipients
        in
        Lwt.async sign_and_transmit
        ; Lwt.pause () >>= go in
    go ()

  let fiber ?stop ~port stack resolver (private_key, dkim) map info =
    let conf_server = Signer.create ~info in
    let messaged = Signer.messaged conf_server in
    Lwt.join
      [
        smtp_signer_service ?stop ~port stack resolver conf_server
      ; smtp_logic ~info stack resolver messaged (private_key, dkim) map
      ]
end