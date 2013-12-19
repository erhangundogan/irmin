(*
 * Copyright (c) 2013 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

module type X = sig
  type t
  type key
  type value
  val create: unit -> t Lwt.t
  val read: t -> key -> value option Lwt.t
  val read_exn: t -> key -> value Lwt.t
  val mem: t -> key -> bool Lwt.t
  val list: t -> key -> key list Lwt.t
  val contents: t -> (key * value) list Lwt.t
end

module type X_BINARY = X with type key := string
                          and type value := Cstruct.buffer

module type A = sig
  include X
  val add: t -> value -> key Lwt.t
end

module type A_BINARY = A with type key := string
                          and type value := Cstruct.buffer

module type A_MAKER = functor (K: IrminKey.BINARY) -> functor (V: IrminBase.S) ->
  A with type key = K.t
     and type value = V.t

module type M = sig
  include X
  val update: t -> key -> value -> unit Lwt.t
  val remove: t -> key -> unit Lwt.t
end

module type M_BINARY = M with type key := string
                          and type value := Cstruct.buffer

module type M_MAKER = functor (K: IrminKey.S) -> functor (V: IrminBase.S) ->
  M with type key = K.t
     and type value = V.t

module X  (S: X_BINARY) (K: IrminKey.S) (V: IrminBase.S) = struct

  open Lwt

  module L = Log.Make(struct let section = "A" end)

  type t = S.t

  type key = K.t

  type value = V.t

  let create () =
    S.create ()

  let read t key =
    S.read t (K.to_string key) >>= function
    | None    -> return_none
    | Some ba ->
      let buf = Mstruct.of_bigarray ba in
      return (V.get buf)

  let read_exn t key =
    S.read_exn t (K.to_string key) >>= fun ba ->
    let buf = Mstruct.of_bigarray ba in
    match V.get buf with
    | None   -> fail (K.Unknown (K.pretty key))
    | Some v -> return v

  let mem t key =
    S.mem t (K.to_string key)

  let list t key =
    S.list t (K.to_string key) >>= fun ks ->
    let ks = List.map K.of_string ks in
    return ks

  let contents t =
    S.contents t >>= fun l ->
    Lwt_list.fold_left_s (fun acc (s, ba) ->
        let buf = Mstruct.of_bigarray ba in
        match V.get buf with
        | None   -> return acc
        | Some v -> return ((K.of_string s, v) :: acc)
      ) [] l

end

module A (S: A_BINARY) (K: IrminKey.BINARY) (V: IrminBase.S) = struct

  open Lwt

  include X(S)(K)(V)

  module LA = Log.Make(struct let section = "A" end)

  let add t value =
    LA.debugf "add %s" (V.pretty value);
    let buf = Mstruct.create (V.sizeof value) in
    V.set buf value;
    S.add t (Mstruct.to_bigarray buf) >>= fun key ->
    let key = K.of_string key in
    LA.debugf "<-- add: %s -> key=%s" (V.pretty value) (K.pretty key);
    return key

end

module M (S: M_BINARY) (K: IrminKey.S) (V: IrminBase.S) = struct

  include X(S)(K)(V)

  module LM = Log.Make(struct let section = "M" end)

  let update t key value =
    LM.debug (lazy "update");
    let buf = Mstruct.create (V.sizeof value) in
    V.set buf value;
    let ba = Mstruct.to_bigarray buf in
    S.update t (K.to_string key) ba

  let remove t key =
    S.remove t (K.to_string key)

end

module type S = sig
  include M
  type revision
  val snapshot: t -> revision Lwt.t
  val revert: t -> revision -> unit Lwt.t
  val watch: t -> key -> (key * revision) Lwt_stream.t
  type dump
  val export: t -> revision list -> dump Lwt.t
  val import: t -> dump -> unit Lwt.t
end


module type S_BINARY = S with type key := string
                          and type value := Cstruct.buffer
                          and type revision := string
                          and type dump := Cstruct.buffer

module type S_MAKER =
  functor (K: IrminKey.S) ->
  functor (V: IrminBase.S) ->
  functor (R: IrminKey.BINARY) ->
  functor (D: IrminBase.S) ->
    S with type key = K.t
       and type value = V.t
       and type revision = R.t
       and type dump = D.t

module S (S: S_BINARY) (K: IrminKey.S) (V: IrminBase.S) (R: IrminKey.BINARY) (D: IrminBase.S) =
struct

  open Lwt

  include M(S)(K)(V)

  type revision = R.t

  let snapshot t =
    S.snapshot t >>= fun r ->
    return (R.of_string r)

  let revert t rev =
    S.revert t (R.to_string rev)

  let watch t path =
    let stream = S.watch t (K.to_string path) in
    Lwt_stream.map (fun (k, r) ->
        (K.of_string k, R.of_string r)
      ) stream

  type dump = D.t

  let export t revs =
    S.export t (List.map R.to_string revs) >>= fun ba ->
    let buf = Mstruct.of_bigarray ba in
    match D.get buf with
    | None   -> fail (R.Invalid (IrminMisc.pretty_list R.pretty revs))
    | Some d -> return d

  let import t dump =
    let buf = Mstruct.create (D.sizeof dump) in
    D.set buf dump;
    S.import t (Mstruct.to_bigarray buf)

end