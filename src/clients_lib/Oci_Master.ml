(**************************************************************************)
(*                                                                        *)
(*  This file is part of Frama-C.                                         *)
(*                                                                        *)
(*  Copyright (C) 2013                                                    *)
(*    CEA (Commissariat à l'énergie atomique et aux énergies              *)
(*         alternatives)                                                  *)
(*                                                                        *)
(*  you can redistribute it and/or modify it under the terms of the GNU   *)
(*  Lesser General Public License as published by the Free Software       *)
(*  Foundation, version 2.1.                                              *)
(*                                                                        *)
(*  It is distributed in the hope that it will be useful,                 *)
(*  but WITHOUT ANY WARRANTY; without even the implied warranty of        *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the         *)
(*  GNU Lesser General Public License for more details.                   *)
(*                                                                        *)
(*  See the GNU Lesser General Public License version 2.1                 *)
(*  for more details (enclosed in the file licenses/LGPLv2.1).            *)
(*                                                                        *)
(**************************************************************************)

open Core.Std
open Async.Std

let oci_at_shutdown = Oci_Artefact_Api.oci_at_shutdown

type runner_result = Oci_Artefact_Api.exec_in_namespace_response =
  | Exec_Ok
  | Exec_Error of string with bin_io

let register data f = Oci_Artefact.register_master data f
let register_saver = Oci_Artefact.register_saver

let run () = Oci_Artefact.run ()
let start_runner ~binary_name = Oci_Artefact.start_runner ~binary_name
let stop_runner conn =
  Rpc.Rpc.dispatch_exn Oci_Artefact_Api.rpc_stop_runner conn ()
let permanent_directory = Oci_Artefact.permanent_directory

let get_log () =
  Option.value_exn ~message:"No log currently attached"
    (Scheduler.find_local Oci_Log.t_type_id)

let attach_log l f =
  Scheduler.with_local Oci_Log.t_type_id (Some l) ~f

let simple_register_saver ?(init=(fun () -> return ())) ~basename
    ~loader ~saver data bin_t =
  Oci_Artefact.register_saver
    ~loader:(fun () ->
      permanent_directory data
      >>= fun dir ->
      init ()
      >>= fun () ->
      let file = Oci_Filename.make_absolute dir basename in
      Oci_Std.read_if_exists file bin_t.Bin_prot.Type_class.reader loader
    )
    ~saver:(fun () ->
      saver ()
      >>= fun r ->
      permanent_directory data
      >>= fun dir ->
      let file = Oci_Filename.make_absolute dir basename in
      Oci_Std.backup_and_open_file file
      >>= fun writer ->
      Writer.write_bin_prot writer bin_t.Bin_prot.Type_class.writer r;
      Writer.close writer
    )


module Make(Query : Hashtbl.Key_binable) (Result : Binable.S) = struct
  module H = Hashtbl.Make(Query)

  type save_data = (Query.t * (Result.t Or_error.t * Oci_Log.t)) list
  with bin_io

  let create_master (data:(Query.t,Result.t) Oci_Data.t) f =
    let db : ((Result.t Or_error.t Deferred.t * Oci_Log.t)) H.t = H.create () in
    let f q =
      match H.find db q with
      | Some r -> r
      | None ->
        let ivar = Ivar.create () in
        let log = Oci_Log.create () in
        let ivar_d = Ivar.read ivar in
        H.add_exn db ~key:q ~data:(ivar_d,log);
        begin
          Monitor.try_with_or_error
            ~name:"create_master"
            (fun () -> attach_log log (fun () -> f q))
          >>> fun r ->
          Oci_Log.close log;
          Ivar.fill ivar r
        end;
        (ivar_d,log)
    in
    register_saver
      ~loader:(fun () ->
          permanent_directory data
          >>= fun dir ->
          let file = Oci_Filename.make_absolute dir "data" in
          Oci_Std.read_if_exists file bin_reader_save_data
            (fun r ->
               List.iter
                 ~f:(fun (q,(r,l)) -> H.add_exn db ~key:q ~data:(return r,l))
                 r;
               return ())
        )
      ~saver:(fun () ->
          let l = H.fold ~init:[]
              ~f:(fun ~key ~data:(data,log) acc ->
                  if Deferred.is_determined data
                  then (data >>= fun data -> return (key,(data,log)))::acc
                  else acc
                ) db in
          Deferred.all l
          >>= fun l ->
          permanent_directory data
          >>= fun dir ->
          let file = Oci_Filename.make_absolute dir "data" in
          Oci_Std.backup_and_open_file file
          >>= fun writer ->
          Writer.write_bin_prot writer bin_writer_save_data l;
          Writer.close writer
        );
    register data f

  let create_master_and_runner data ?(binary_name=Oci_Data.name data) ~error f =
    create_master data
      begin fun q ->
        start_runner ~binary_name
        >>= fun (err,conn) ->
        choose [
          choice (err >>= function
            | Exec_Ok -> never ()
            | Exec_Error s -> return s) error;
          choice begin
            conn >>= fun conn ->
            Monitor.protect
              ~finally:(fun () -> stop_runner conn)
              ~name:"create_master_and_runner"
              (fun () -> f conn q)
          end (fun x -> x);
        ]
      end


end

let write_log kind ?(log=get_log ()) fmt =
  Printf.ksprintf (fun s ->
      s
      |> String.split_lines
      |> List.iter ~f:(fun line -> Oci_Log.write log {kind;line})
    ) fmt

let std_log ?log fmt = write_log Oci_Log.Standard ?log fmt
let err_log ?log fmt = write_log Oci_Log.Error ?log fmt
let cmd_log ?log fmt = write_log Oci_Log.Command ?log fmt
let cha_log ?log fmt = write_log Oci_Log.Chapter ?log fmt

exception Internal_error with sexp

let dispatch_runner ?msg ?(log=get_log()) d t q =
  Option.iter msg ~f:(fun msg ->
      cmd_log "dispatch %s: %s" (Oci_Data.name d) msg);
  let r : 'a Or_error.t Ivar.t = Ivar.create () in
  don't_wait_for begin
    (Rpc.Pipe_rpc.dispatch (Oci_Data.both d) t q)
    >>= fun res -> match Or_error.join res with
      | Error _ as err -> Ivar.fill r err; Deferred.unit
      | Ok (p, _) ->
        let p = Pipe.map ~f:(function
            | Oci_Data.Line l -> l
            | Oci_Data.Result err ->
              Ivar.fill r err;
              match err with
              | Core_kernel.Result.Ok _ ->
                {Oci_Log.kind=Oci_Log.Standard;line="result received"}
              | Core_kernel.Result.Error _ ->
                {Oci_Log.kind=Oci_Log.Error;line="error received"};
          )
            p in
        upon (Pipe.closed p)
          (fun () -> Ivar.fill_if_empty r (Or_error.of_exn Internal_error));
        Oci_Log.transfer log p
  end;
  Ivar.read r


let dispatch_runner_exn ?msg ?(log=get_log()) d t q =
  Option.iter msg ~f:(fun msg ->
      cmd_log "dispatch %s: %s" (Oci_Data.name d) msg);
  let r = Ivar.create () in
  don't_wait_for begin
    Rpc.Pipe_rpc.dispatch_exn (Oci_Data.both d) t q
    >>= fun (p,_) ->
    let p = Pipe.map ~f:(function
        | Oci_Data.Line l -> l
        | Oci_Data.Result (Core_kernel.Result.Ok res) ->
          Ivar.fill r res;
          {kind=Oci_Log.Standard;line="result received"}
        | Oci_Data.Result (Core_kernel.Result.Error err) ->
          Oci_Log.write log
            {kind=Oci_Log.Error;line="error received"};
          Error.raise err
      )
        p in
    upon (Pipe.closed p)
      (fun () -> if Ivar.is_empty r then raise Internal_error);
    Oci_Log.transfer log p
  end;
  Ivar.read r
