(*
 * Copyright (C) 2006-2009 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
module R = Debug.Make (struct let name = "taskhelper" end)

module D = Debug.Make (struct let name = "dummytaskhelper" end)

(** Every operation has an origin: either the HTTP connection it came from or
    an internal subsystem (eg synchroniser thread / event handler
    thread) *)
type origin = Http of Http.Request.t * Unix.file_descr | Internal

let string_of_origin = function
  | Http (req, fd) ->
      let peer =
        match Unix.getpeername fd with
        | Unix.ADDR_UNIX _ ->
            "Unix domain socket"
        | Unix.ADDR_INET _ ->
            "Internet"
      in
      (* unfortunately all connections come from stunnel on localhost *)
      Printf.sprintf "HTTP request from %s with User-Agent: %s" peer
        (Option.value ~default:"unknown" req.Http.Request.user_agent)
  | Internal ->
      "Internal"

(** A Context is used to represent every API invocation. It may be extended
    to include extra data without changing all the autogenerated signatures *)
type t = {
    session_id: API.ref_session option
  ; task_id: API.ref_task
  ; forwarded_task: bool
  ; origin: origin
  ; database: Db_ref.t
  ; dbg: string
  ; mutable tracing: Tracing.Span.t option
  ; client: Http_svr.client option
  ; mutable test_rpc: (Rpc.call -> Rpc.response) option
  ; mutable test_clusterd_rpc: (Rpc.call -> Rpc.response) option
}

let complete_tracing __context =
  ( match Tracing.Tracer.finish __context.tracing with
  | Ok _ ->
      ()
  | Error e ->
      R.warn "Failed to complete tracing: %s" (Printexc.to_string e)
  ) ;
  __context.tracing <- None

let complete_tracing_with_exn __context error =
  ( match Tracing.Tracer.finish ~error __context.tracing with
  | Ok _ ->
      ()
  | Error e ->
      R.warn "Failed to complete tracing: %s" (Printexc.to_string e)
  ) ;
  __context.tracing <- None

let tracing_of __context = __context.tracing

let set_client_span __context =
  let span =
    Option.map
      (fun span -> Tracing.Span.set_span_kind span Tracing.SpanKind.Client)
      __context.tracing
  in
  __context.tracing <- span ;
  span

let get_session_id x =
  match x.session_id with
  | None ->
      failwith "Could not find a session_id"
  | Some x ->
      x

let forwarded_task ctx = ctx.forwarded_task

let get_task_id ctx = ctx.task_id

let task_in_database ctx = Ref.is_real ctx.task_id

let get_origin ctx = string_of_origin ctx.origin

let database_of x = x.database

(** Calls coming in from the main unix socket are pre-authenticated.
    This excludes calls coming in on the unix socket that is used for
    client-certificate auth. *)
let is_unix_socket s =
  match Unix.getsockname s with
  | Unix.ADDR_UNIX path when path = Xapi_globs.unix_domain_socket ->
      true
  | Unix.ADDR_INET _ | Unix.ADDR_UNIX _ ->
      false

let default_database () =
  if Pool_role.is_master () then
    Db_backend.make ()
  else
    Db_ref.Remote

let preauth ~__context =
  match __context.origin with
  | Internal ->
      None
  | Http (_, s) -> (
    match Unix.getsockname s with
    | Unix.ADDR_UNIX path when path = Xapi_globs.unix_domain_socket ->
        Some `root
    | Unix.ADDR_UNIX path when path = Xapi_globs.unix_domain_socket_clientcert
      ->
        Some `client_cert
    | Unix.ADDR_UNIX _ | Unix.ADDR_INET _ ->
        None
  )

let get_initial () =
  {
    session_id= None
  ; task_id= Ref.make_dummy "initial_task"
  ; forwarded_task= false
  ; origin= Internal
  ; database= default_database ()
  ; dbg= "initial_task"
  ; tracing= None
  ; client= None
  ; test_rpc= None
  ; test_clusterd_rpc= None
  }

(* ref fn used to break the cyclic dependency between context, db_actions and taskhelper *)
let __get_task_name : (__context:t -> API.ref_task -> string) ref =
  ref (fun ~__context _ -> "__get_task_name not set")

let __make_task =
  ref
    (fun
      ~__context
      ~http_other_config:_
      ?description:_
      ?session_id:_
      ?subtask_of:_
      _
    -> (Ref.null, Uuidx.null)
  )

let __destroy_task : (__context:t -> API.ref_task -> unit) ref =
  ref (fun ~__context:_ _ -> ())

let string_of_task __context = __context.dbg

let string_of_task_and_tracing __context =
  Debuginfo.make ~log:__context.dbg ~tracing:__context.tracing
  |> Debuginfo.to_string

let tracing_of_dbg s =
  let dbg = Debuginfo.of_string s in
  (dbg.log, dbg.tracing)

let check_for_foreign_database ~__context =
  match __context.session_id with
  | Some sid -> (
    match Db_backend.get_registered_database (Ref.string_of sid) with
    | Some database ->
        {__context with database}
    | None ->
        __context
  )
  | None ->
      __context

(** destructors *)
let destroy __context =
  if not __context.forwarded_task then
    !__destroy_task ~__context __context.task_id

(* CP-982: create tracking id in log files to link username to actions *)
let trackid_of_session ?(with_brackets = false) ?(prefix = "") session_id =
  match session_id with
  | None ->
      ""
  | Some session_id ->
      (* a hash is used instead of printing the sensitive session_id value *)
      let trackid =
        Printf.sprintf "trackid=%s"
          (Digest.to_hex (Digest.string (Ref.string_of session_id)))
      in
      if with_brackets then Printf.sprintf "%s(%s)" prefix trackid else trackid

let trackid ?(with_brackets = false) ?(prefix = "") __context =
  (* CP-982: create tracking id in log files to link username to actions *)
  trackid_of_session ~with_brackets ~prefix __context.session_id

let _client_of_origin = function
  | Internal ->
      None
  | Http (req, fd) ->
      Http_svr.client_of_req_and_fd req fd

let make_dbg http_other_config task_name task_id =
  if List.mem_assoc "dbg" http_other_config then
    List.assoc "dbg" http_other_config
  else
    Printf.sprintf "%s%s%s" task_name
      (if task_name = "" then "" else " ")
      (Ref.really_pretty_and_small task_id)

let tracing_of_origin (origin : origin) task_name =
  let open Tracing in
  let ( let* ) = Option.bind in
  let parent =
    match origin with
    | Http (req, _) ->
        let* traceparent = req.Http.Request.traceparent in
        let* span_context = SpanContext.of_traceparent traceparent in
        let span = Tracer.span_of_span_context span_context task_name in
        Some span
    | _ ->
        None
  in
  let span_kind =
    Option.fold ~none:SpanKind.Internal ~some:(fun _ -> SpanKind.Server) parent
  in
  (parent, span_kind)

(** constructors *)

let from_forwarded_task ?(http_other_config = []) ?session_id
    ?(origin = Internal) task_id =
  let client = _client_of_origin origin in
  let task_name =
    if Ref.is_dummy task_id then
      Ref.name_of_dummy task_id
    else
      !__get_task_name ~__context:(get_initial ()) task_id
  in
  let info = if not (Ref.is_dummy task_id) then R.info else D.debug in
  (* CP-982: promote tracking debug line to info status *)
  let dbg = make_dbg http_other_config task_name task_id in
  info "task %s forwarded%s" dbg
    (trackid_of_session ~with_brackets:true ~prefix:" " session_id) ;
  let tracing =
    let open Tracing in
    let tracer = get_tracer ~name:task_name in
    let parent, span_kind = tracing_of_origin origin task_name in
    match Tracer.start ~span_kind ~tracer ~name:task_name ~parent () with
    | Ok x ->
        x
    | Error e ->
        R.warn "Failed to start tracing: %s" (Printexc.to_string e) ;
        None
  in
  {
    session_id
  ; task_id
  ; forwarded_task= true
  ; origin
  ; database= default_database ()
  ; dbg
  ; tracing
  ; client
  ; test_rpc= None
  ; test_clusterd_rpc= None
  }

let make ?(http_other_config = []) ?(quiet = false) ?subtask_of ?session_id
    ?(database = default_database ()) ?(task_in_database = false)
    ?task_description ?(origin = Internal) task_name =
  (* create a real or a dummy task *)
  let client = _client_of_origin origin in
  let task_id, task_uuid =
    if task_in_database then
      !__make_task ~__context:(get_initial ()) ~http_other_config
        ?description:task_description ?session_id ?subtask_of task_name
    else
      (Ref.make_dummy task_name, Uuidx.null)
  in
  let dbg = make_dbg http_other_config task_name task_id in
  (* log the creation of a subtask (unless quite=true) *)
  ( if (not quiet) && subtask_of <> None then
      let task_uuid =
        if task_uuid = Uuidx.null then
          ""
        else
          Printf.sprintf " (uuid:%s)" (Uuidx.to_string task_uuid)
      in
      let info = if task_in_database then R.info else D.debug in
      info "task %s%s created%s%s"
        (* CP-982: promote tracking debug line to info status *) dbg task_uuid
        (trackid_of_session ~with_brackets:true ~prefix:" " session_id)
        (* CP-982: link each task to original session created during login *)
        ( match subtask_of with
        | None ->
            ""
        | Some subtask_of ->
            " by task " ^ make_dbg [] "" subtask_of
        )
  ) ;
  let tracing =
    let open Tracing in
    let tracer = get_tracer ~name:task_name in
    let parent, span_kind = tracing_of_origin origin task_name in
    match Tracer.start ~span_kind ~tracer ~name:task_name ~parent () with
    | Ok x ->
        x
    | Error e ->
        R.warn "Failed to start tracing: %s" (Printexc.to_string e) ;
        None
  in
  {
    session_id
  ; database
  ; task_id
  ; origin
  ; forwarded_task= false
  ; dbg
  ; tracing
  ; client
  ; test_rpc= None
  ; test_clusterd_rpc= None
  }

let make_subcontext ~__context ?task_in_database task_name =
  let session_id = __context.session_id in
  let subtask_of = __context.task_id in
  let subcontext = make ~subtask_of ?session_id ?task_in_database task_name in
  let tracing =
    let open Tracing in
    Option.bind __context.tracing (fun parent ->
        let parent = Some parent in
        let tracer = get_tracer ~name:task_name in
        match Tracer.start ~tracer ~name:task_name ~parent () with
        | Ok x ->
            x
        | Error e ->
            R.warn "Failed to start tracing: %s" (Printexc.to_string e) ;
            None
    )
  in
  {subcontext with client= __context.client; tracing}

let get_http_other_config http_req =
  let http_other_config_hdr = "x-http-other-config-" in
  http_req.Http.Request.additional_headers
  |> List.filter (fun (k, _) ->
         Astring.String.is_prefix ~affix:http_other_config_hdr k
     )
  |> List.map (fun (k, v) ->
         ( String.sub k
             (String.length http_other_config_hdr)
             (String.length k - String.length http_other_config_hdr)
         , v
         )
     )

(** Called by autogenerated dispatch code *)
let of_http_req ?session_id ?(internal_async_subtask = false) ~generate_task_for
    ~supports_async ~label ~http_req ~fd () =
  let http_other_config = get_http_other_config http_req in
  let new_task_context () =
    let subtask_of =
      Option.map Ref.of_string http_req.Http.Request.subtask_of
    in
    make ?session_id ?subtask_of ~http_other_config ~task_in_database:true
      ~origin:(Http (http_req, fd))
      label
  in
  if internal_async_subtask then
    new_task_context ()
  else
    match http_req.Http.Request.task with
    | Some task_id ->
        from_forwarded_task ?session_id ~http_other_config
          ~origin:(Http (http_req, fd))
          (Ref.of_string task_id)
    | None ->
        if generate_task_for && supports_async then
          new_task_context ()
        else
          make ?session_id ~http_other_config
            ~origin:(Http (http_req, fd))
            label

let set_test_rpc context rpc = context.test_rpc <- Some rpc

let get_test_rpc context = context.test_rpc

let set_test_clusterd_rpc context rpc = context.test_clusterd_rpc <- Some rpc

let get_test_clusterd_rpc context = context.test_clusterd_rpc

let get_client context = context.client |> Option.map Http_svr.string_of_client

let get_client_ip context =
  context.client |> Option.map (fun (_, ip) -> Ipaddr.to_string ip)

let get_user_agent context =
  match context.origin with Internal -> None | Http (rq, _) -> rq.user_agent

let with_tracing context name f =
  let open Tracing in
  let parent = context.tracing in
  let tracer = get_tracer ~name in
  match Tracer.start ~tracer ~name ~parent () with
  | Ok span ->
      let new_context = {context with tracing= span} in
      let result = f new_context in
      let _ = Tracer.finish span in
      result
  | Error e ->
      R.warn "Failed to start tracing: %s" (Printexc.to_string e) ;
      f context
