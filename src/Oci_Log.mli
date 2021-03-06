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

type kind =
  | Standard | Error | Chapter | Command
    [@@deriving sexp, bin_io]

val color_of_kind: kind -> [> `Black | `Underscore | `Red | `Blue]

type 'a data =
  | Std of kind * string
  | Extra of 'a
  | End of unit Or_error.t
[@@deriving sexp, bin_io]

type 'a line = {
  data : 'a data;
  time : Time.t;
} [@@deriving sexp, bin_io]

val line: kind -> string -> 'a line
val data: 'a -> 'a line
val _end: unit Or_error.t -> 'a line

val map_line: ('a -> 'b) -> 'a line -> 'b line

type 'result writer = 'result line Pipe.Writer.t
val close_writer: 'result writer -> unit Or_error.t -> unit Deferred.t
val write_and_close: 'result writer -> 'result Or_error.t -> unit Deferred.t

(** alive log *)

type 'result reader
val read: 'result reader -> 'result line Pipe.Reader.t
val init_writer: ('result writer -> unit Deferred.t) -> 'result reader

val reader_stop_after:
  f:('result -> bool) -> 'result reader -> 'result reader
val reader_get_first:
  f:('result -> bool) -> 'result reader ->
  [`Found of 'result | `Incomplete | `NotFound | `Error of Error.t] Deferred.t

exception Closed_Log

module Make(S: sig
    val dir: Oci_Filename.t Deferred.t
    val register_saver:
      loader:(unit -> unit Deferred.t) ->
      saver:(unit -> unit Deferred.t) ->
      unit
    type t [@@deriving bin_io]
  end): sig

  type t
  (** saved log *)

  include Binable.S with type t := t

  val create: unit -> t
  val null: t
  (** a log without any line *)

  val transfer: t -> S.t line Pipe.Reader.t -> unit Deferred.t
  val add_without_pushback: t -> S.t line -> unit
  val close: t -> unit Deferred.t

  val read: t -> S.t line Pipe.Reader.t
  val reader: t -> S.t reader
  val writer: t -> S.t writer
  val is_closed: t -> bool
end
