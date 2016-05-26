(**************************************************************************)
(*                                                                        *)
(*  This file is part of OCI.                                             *)
(*                                                                        *)
(*  Copyright (C) 2015-2016                                               *)
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


module Pp = Oci_pp
include Log.Global

let unlink_no_fail filename =
  (* Sys.file_exists follows symlink *)
  Monitor.try_with ~here:[%here]
    (fun () -> Unix.lstat filename)
  >>= function
  | Ok _ -> Unix.unlink filename
  | Error _ -> return ()
  (* | Error (Unix.Unix_error _) -> return () *)
  (* | Error exn -> raise exn *)

let unlink_no_fail_blocking filename =
  let open Core.Std in
  (* Sys.file_exists follows symlink *)
  try
    ignore (Unix.lstat filename);
    Unix.unlink filename
  with _ -> ()

let backup_and_open_file file =
  let file_bak = Oci_Filename.add_extension file "bak" in
  Sys.file_exists_exn file
  >>= fun exi ->
  begin if exi then begin
      unlink_no_fail file_bak
      >>= fun () ->
      Unix.rename ~src:file ~dst:file_bak
    end
    else return ()
  end
  >>= fun () ->
  Writer.open_file file

let open_if_exists file f =
  Sys.file_exists_exn file
  >>= fun exi ->
  if exi then begin
    Reader.open_file file
    >>= fun reader ->
    f reader
    >>= fun () ->
    Reader.close reader
  end
  else return ()

let read_if_exists file bin_reader_t f =
  open_if_exists file
    (fun reader ->
       Reader.read_bin_prot reader bin_reader_t
       >>= function
       | `Eof -> return ()
       | `Ok r -> f r
    )

external wait4: Caml.Unix.wait_flag list -> int ->
  int * Caml.Unix.process_status * Core.Core_unix.Resource_usage.t = "oci_wait4"
let wait4 pid =
  let pid = (Pid.to_int pid) in
  In_thread.syscall_exn ~name:"wait4"
    (fun () -> wait4 [] pid)
  >>= fun (pid',status,ru) ->
  assert (pid' = pid);
  return (Core.Core_unix.Exit_or_signal.of_unix status, ru)

module Oci_Unix : sig
  type t [@@deriving sexp_of]
  type env = [ `Extend of (string * string) list
             | `Replace of (string * string) list ]
    [@@deriving sexp, bin_io, compare]
  (* accessors *)
  val pid    : t -> Pid.t
  val stdin  : t -> Writer.t
  val stdout : t -> Reader.t
  val stderr : t -> Reader.t

  type 'a create
    =  ?env         : env  (* default is [`Extend []] *)
    -> ?working_dir : string
    -> prog         : string
    -> args         : string list
    -> unit
    -> 'a Deferred.t
  val create     : t Or_error.t create
  val create_exn : t            create

  val start : t -> unit Deferred.t
  val wait : t -> Unix.Exit_or_signal.t Deferred.t
end
= struct
  (** from core extended_unix *)


external raw_fork_exec :
  stdin : Core.Std.Unix.File_descr.t
  -> stdout : Core.Std.Unix.File_descr.t
  -> stderr : Core.Std.Unix.File_descr.t
  -> ?start : Core.Std.Unix.File_descr.t
  -> ?working_dir : string
  -> ?setuid : int
  -> ?setgid : int
  -> ?env : (string) array
  -> string
  -> string array
  -> Pid.t
  =  "oci_extended_ml_spawn_bc" "oci_extended_ml_spawn"

type env = [ `Extend of (string * string) list
           | `Replace of (string * string) list ]
  [@@deriving sexp, bin_io, compare]

module Env = struct
  open String.Map
  type t = string String.Map.t

  let empty : t = empty

  let get ()  =
    Array.fold  (Unix.environment ())
      ~init:empty
      ~f:(fun env str ->
        match String.lsplit2 ~on:'=' str with
        | Some (key,data) -> add ~key ~data env
        | None ->
          failwithf
            "extended_unix.Env.get %S is not in the form of key=value"
            str
            ())

  let add ~key ~data env =
    if String.mem key '=' then
      failwithf "extended_unix.Env.add:\
  variable to export in the environment %S contains an equal sign"
        key
        ()
    else if String.mem key '\000' then
      failwithf "extended_unix.Env.add:\
  variable to export in the environment %S contains an null character"
        key
        ()
    else if String.mem data '\000' then
      failwithf "extended_unix.Env.add:\
  value (%S) to export in the environment for %S contains an null character"
        data
        key
        ()
    else
      String.Map.add ~key ~data env

  let to_string_array env =
    String.Map.to_alist env
    |! List.map ~f:(fun (k,v) -> k^"="^v)
    |! List.to_array
end

let fork_exec
    ?(stdin=Core.Std.Unix.stdin)
    ?(stdout=Core.Std.Unix.stdout)
    ?(stderr=Core.Std.Unix.stderr)
    ?start
    ?(path_lookup=true)
    ?env
    ?working_dir
    ?setuid
    ?setgid
    prog
    args
    =
  let env = Option.map env
    ~f:(fun e ->
      let init,l = match e with
        | `Extend  l ->
          Env.get (),l
        | `Replace l ->
          Env.empty,l
      in
      List.fold_left l
        ~init
        ~f:(fun env (key,data) -> Env.add ~key ~data env)
      |! Env.to_string_array)

  and full_prog =
    if path_lookup then
      match Core_extended.Shell__core.which prog with
      | Some s -> s
      | None -> failwithf "fork_exec: Process not found %s"
        prog
        ()
    else
      prog
  in
  raw_fork_exec
    ~stdin
    ~stdout
    ~stderr
    ?start
    ?working_dir
    ?setuid
    ?setgid
    ?env
    full_prog
    (Array.of_list (prog::args))


type t =
  { pid         : Pid.t
  ; stdin       : Writer.t
  ; stdout      : Reader.t
  ; stderr      : Reader.t
  ; start       : Writer.t
  ; prog        : string
  ; args        : string list
  ; working_dir : string option
  ; env         : env
  }
[@@deriving fields, sexp_of]

let wait t = Unix.waitpid t.pid
let start t = Writer.close t.start

type 'a create
  =  ?env         : env
  -> ?working_dir : string
  -> prog         : string
  -> args         : string list
  -> unit
  -> 'a Deferred.t


let rec temp_failure_retry f =
  try
    f ()
  with Unix.Unix_error (EINTR, _, _) -> temp_failure_retry f


let close_non_intr fd =
  temp_failure_retry (fun () -> Core.Std.Unix.close fd)

(* Creates a unix pipe with both sides set close on exec *)
let cloexec_pipe () =
  let (fd1,fd2) as res = Core.Std.Unix.pipe () in
  Core.Std.Unix.set_close_on_exec fd1;
  Core.Std.Unix.set_close_on_exec fd2;
  res

module Process_info = struct
  type t = {
    pid:int;
    stdin : Core.Std.Unix.File_descr.t;
    stdout : Core.Std.Unix.File_descr.t;
    stderr : Core.Std.Unix.File_descr.t;
    start  : Core.Std.Unix.File_descr.t;
  }
end
(* We use a slightly more powerful version of create process than the one in
   core. This version is not quite as carefuly code reviewed but allows us to
   have more control over the forked side of the process (e.g.: chdir).
*)
let internal_create_process ?working_dir ?setuid ?setgid ~env ~prog ~args () =
  let close_on_err = ref [] in
  try
    let (in_read, in_write) = cloexec_pipe () in
    close_on_err := in_read :: in_write :: !close_on_err;
    let (out_read, out_write) = cloexec_pipe () in
    close_on_err := out_read :: out_write :: !close_on_err;
    let (err_read, err_write) = cloexec_pipe () in
    close_on_err := err_read :: err_write :: !close_on_err;
    let (start_read, start_write) = cloexec_pipe () in
    close_on_err := err_read :: err_write :: !close_on_err;
    let pid = fork_exec
      prog
      args
      ?working_dir
      ?setuid
      ?setgid
      ~env
      ~stdin:in_read
      ~stdout:out_write
      ~stderr:err_write
      ~start:start_read
    in
    close_non_intr in_read;
    close_non_intr out_write;
    close_non_intr err_write;
    {
      Process_info.pid = Pid.to_int pid;
      stdin = in_write;
      stdout = out_read;
      stderr = err_read;
      start  = start_write;
    }
  with e ->
    List.iter
      ~f:(fun fd -> try close_non_intr fd with _ -> ())
      !close_on_err;
    raise e

let path_expand ?working_dir ?use_extra_path prog =
  match working_dir with
  | Some d when (String.contains prog '/') && Filename.is_relative prog ->
    d ^/ prog
  | _ -> Core_extended.Shell__core.path_expand ?use_extra_path prog

let create ?(env = `Extend []) ?working_dir ~prog ~args () =
  In_thread.syscall ~name:"oci_create_process_env" (fun () ->
      let full_prog = path_expand ?working_dir prog in
      internal_create_process ~prog:full_prog ~args ~env ?working_dir ())
  >>| function
  | Error exn -> Or_error.of_exn exn
  | Ok { Process_info.pid; stdin; stdout; stderr; start } ->
    let create_fd name file_descr =
      Fd.create Fifo file_descr
        (Info.create "child process" ~here:[%here] (name, `pid pid, `prog prog,
                                                    `args args)
           [%sexp_of:
                      string * [ `pid of int ] * [ `prog of string ] *
                      [ `args of string list ]
            ])
    in
    Ok { pid = Pid.of_int pid
       ; stdin  = Writer.create (create_fd "stdin"  stdin )
       ; stdout = Reader.create (create_fd "stdout" stdout)
       ; stderr = Reader.create (create_fd "stderr" stderr)
       ; start  = Writer.create (create_fd "start"  start )
       ; prog
       ; args
       ; working_dir
       ; env
       }

let create_exn ?env ?working_dir ~prog ~args () =
  create ?env ?working_dir ~prog ~args () >>| ok_exn

end
