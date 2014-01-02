(* Lightweight thread library for Objective Caml
 * http://www.ocsigen.org/lwt
 * Module Lwt
 * Copyright (C) 2005-2008 Jérôme Vouillon
 * Laboratoire PPS - CNRS Université Paris Diderot
 *               2009-2012 Jérémie Dimino
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation, with linking exceptions;
 * either version 2.1 of the License, or (at your option) any later
 * version. See COPYING file for details.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA
 * 02111-1307, USA.
 *)

(* +-----------------------------------------------------------------+
   | Types                                                           |
   +-----------------------------------------------------------------+ *)
open Core.Std
open Async.Std

module Ivar = Async_core.Raw_ivar
module Handler = Async_core.Raw_handler
module Scheduler = Async_core.Raw_scheduler

type +'a t = ('a, exn) Result.t Deferred.t
type -'a u

type 'a t_repr = ('a, exn) Result.t Ivar.t

exception Canceled

external thread : 'a t_repr -> 'a t = "%identity"
external thread_repr : 'a t -> 'a t_repr = "%identity"
external wakener : 'a t_repr -> 'a u = "%identity"
external wakener_repr : 'a u -> 'a t_repr = "%identity"

let is_cancelable t = Obj.(tag (repr t)) = 1
let set_cancelable t = Obj.(set_tag (repr t) 1)

let unify_cancelable t reference =
  let open Obj in
  set_tag (repr t) (tag (repr reference))

let cancel t =
  let t = thread_repr t in
  if is_cancelable t && Ivar.is_empty t then
    Ivar.fill t (Error Canceled)

let propagate_cancel t = function
  | Error Canceled -> cancel t
  | _ -> ()

let return x =
  let ivar = Ivar.create_full (Ok x) in
  thread ivar

let fail exn =
  let ivar = Ivar.create_full (Error exn) in
  thread ivar

let bind t' f =
  let t = thread_repr t' in
  match Ivar.peek t with
  | Some (Ok e)      -> f e
  | Some (Error exn) -> fail exn
  | None -> (* Sleep *)
    let bind_result = Ivar.create () in
    if is_cancelable t then (
      set_cancelable bind_result ;
      (* We don't make that a "removable_handler" because unregistering such a
         handler doesn't mean it won't be run, it just adds a check before
         actually calling it to see whether it's still active or not.
         Since what we do is cheap and cancel has no effect on already filled
         ivars, there is no point in unregistering that handler. *)
      Ivar.upon bind_result (propagate_cancel t')
    ) ;
    Ivar.upon t (
      function
      | Ok e ->
        let res = thread_repr (f e) in
        unify_cancelable bind_result res ;
        (try Ivar.connect ~bind_result ~bind_rhs:res (* TODO: monitor *)
        with e -> Exn.reraise e "Lwt.bind")
      | Error e ->
        (* [e] could be [Canceled] and [t] could have been canceled through [ret] *)
        if Ivar.is_empty bind_result then
          Ivar.fill bind_result (Error e)
    ) ;
    thread bind_result

let (>>=) = bind
let (=<<) f x = x >>= f

let map f t' =
  let t = thread_repr t' in
  match Ivar.peek t with
  | Some (Ok e)      -> return (f e)
  | Some (Error exn) -> fail exn
  | None -> (* Sleep *)
    let bind_result = Ivar.create () in
    if is_cancelable t then (
      set_cancelable bind_result ;
      Ivar.upon bind_result (propagate_cancel t')
    ) ;
    Ivar.upon t (
      function
      | Ok e    ->
        let res = try Ok (f e) with exn -> Error exn in
        Ivar.fill bind_result res
      | Error e -> Ivar.fill bind_result (Error e)
    ) ;
    thread bind_result

let (>|=) t f = map f t
let (=|<) f t = map f t

(* -------------------------------------------------------------------------- *)

let return_unit = return ()

let return_none = return None

let return_nil = return []

let return_true = return true
let return_false = return false

(* -------------------------------------------------------------------------- *)
let async_exception_hook =
  ref (fun exn ->
    Printf.eprintf "Fatal error: exception %s\n" (Exn.to_string exn) ;
    Printexc.print_backtrace stderr;
    Pervasives.flush stderr;
    Pervasives.exit 2
  )


type 'a state =
  | Return of 'a
  | Fail of exn
  | Sleep

let is_sleeping t = Ivar.is_empty (thread_repr t)

let state t =
  match Ivar.peek (thread_repr t) with
  | None -> Sleep
  | Some x ->
    match x with
    | Ok value -> Return value
    | Error exn -> Fail exn

type +'a result = ('a, exn) Result.t

let make_value x = Ok x

let make_error exn = Error exn

let of_result r =
  let ivar = Ivar.create_full r in
  thread ivar

(* -------------------------------------------------------------------------- *)

let wait () : 'a t * 'a u =
  let t = Ivar.create () in
  thread t, wakener t

let wakeup_result u v =
  let r = wakener_repr u in
  match Ivar.peek r with
  | Some (Error Canceled) -> ()
  | Some _ -> invalid_arg "Lwt.wakeup_result"
  | None -> Ivar.fill r v

let wakeup u v = wakeup_result u (Ok v)
let wakeup_later = wakeup

let wakeup_exn u exn = wakeup_result u (Error exn)
let wakeup_later_exn = wakeup_exn

let waiter_of_wakener u = thread (wakener_repr u)

let wakeup_result u r = Ivar.fill (wakener_repr u) r
let wakeup_later_result = wakeup_result

(* -------------------------------------------------------------------------- *)

let task () : 'a t * 'a u =
  let t = Ivar.create () in
  set_cancelable t ;
  thread t, wakener t

  (* Simplistic *)
let on_cancel t f =
  Ivar.upon (thread_repr t) (
    function
    | Error Canceled -> begin try f () with exn -> !async_exception_hook exn end
    | _ -> ()
  )

let add_task_r seq =
  let t = Ivar.create () in
  set_cancelable t ;
  let node = Lwt_sequence.add_r (wakener t) seq in
  Ivar.upon t (
    function
    | Error Canceled -> Lwt_sequence.remove node
    | _ -> ()
  ) ;
  thread t

let add_task_l seq =
  let t = Ivar.create () in
  set_cancelable t ;
  let node = Lwt_sequence.add_l (wakener t) seq in
  Ivar.upon t (
    function
    | Error Canceled -> Lwt_sequence.remove node
    | _ -> ()
  ) ;
  thread t

let protected t_ =
  let t = thread_repr t_ in
  match Ivar.peek t with
  | Some _ -> t_
  | None ->
    let ivar = Ivar.create () in
    Ivar.upon t
      (fun res -> if Ivar.is_empty ivar then Ivar.fill ivar res) ;
    set_cancelable ivar ;
    thread ivar

let no_cancel t_ =
  let t = thread_repr t_ in
  match Ivar.peek t with
  | Some _ -> t_
  | None ->
    let ivar = Ivar.create () in
    (try Ivar.connect ~bind_result:ivar ~bind_rhs:t
    with e -> Exn.reraise e "Lwt.no_cancel") ;
    thread ivar

(* -------------------------------------------------------------------------- *)

type 'a key = 'a Univ_map.Key.t

let new_key () = Univ_map.Key.create "Lwt.new_key" (fun _ -> Sexplib.Pre_sexp.unit)

let get = Async_unix.Scheduler.find_local
let with_value key value f = Async_unix.Scheduler.with_local key value ~f

(* -------------------------------------------------------------------------- *)

let catch t_susp handler =
  let t = thread_repr (try t_susp () with e -> fail e) in
  match Ivar.peek t with
  | Some (Ok _)    -> thread t
  | Some (Error e) -> handler e
  | None ->
    let ivar = Ivar.create () in
    if is_cancelable t then (
      set_cancelable ivar ;
      Ivar.upon ivar (propagate_cancel (thread t))
    ) ;
    Ivar.upon t (fun result ->
      match Ivar.peek ivar with
      | None ->
        begin match result with
        | Ok _ as res -> Ivar.fill ivar res
        | Error exn ->
          let res =
            thread_repr (
              try handler exn
              with exn -> fail exn
            )
          in
          unify_cancelable ivar res ;
          try Ivar.connect ~bind_result:ivar ~bind_rhs:res
          with e -> Exn.reraise e "Lwt.catch"
        end
      | _ ->
        (* At this point [ivar] is already filled, and it can only be filled by
           [Error Canceled].
           To match Lwt's semantic we would like to give [Canceled] to [handler]
           and then replace the content of the ivar.
           But we cannot replace the content of a filled ivar, also the other
           handlers might already have been run so there is no point. *)
        ()
    ) ;
    thread ivar

let try_bind t_susp f handler =
  let t = thread_repr (try t_susp () with e -> fail e) in
  match Ivar.peek t with
  | Some (Ok v)    -> f v
  | Some (Error e) -> handler e
  | None ->
    let ivar = Ivar.create () in
    if is_cancelable t then (
      set_cancelable ivar ;
      Ivar.upon ivar (propagate_cancel (thread t))
    ) ;
    Ivar.upon t (fun result ->
      match Ivar.peek ivar with
      | None ->
        begin match result with
        | Ok e ->
          let res = thread_repr (f e) in
          unify_cancelable ivar res ;
          (try Ivar.connect ~bind_result:ivar ~bind_rhs:res (* TODO: monitor *)
          with e -> Exn.reraise e "Lwt.try_bind")
        | Error exn ->
          let res = thread_repr (handler exn) in
          unify_cancelable ivar res ;
          try Ivar.connect ~bind_result:ivar ~bind_rhs:res
          with e -> Exn.reraise e "Lwt.try_bind"
        end
      | _ ->
        (* See comment on line 281 *)
        ()
    ) ;
    thread ivar

let finalize t_susp finalizer =
  try_bind t_susp
    (fun x -> finalizer () >>= fun () -> return x)
    (fun e -> finalizer () >>= fun () -> fail e)

let wrap f =
  try return (f ())
  with exn -> fail exn

let wrap1 f x =
  try return (f x)
  with exn -> fail exn

let wrap2 f x y =
  try return (f x y)
  with exn -> fail exn

let wrap3 f x y z =
  try return (f x y z)
  with exn -> fail exn

let wrap4 f x y z a =
  try return (f x y z a)
  with exn -> fail exn

let wrap5 f x y z a b =
  try return (f x y z a b)
  with exn -> fail exn

let wrap6 f x y z a b c =
  try return (f x y z a b c)
  with exn -> fail exn

let wrap7 f x y z a b c d =
  try return (f x y z a b c d)
  with exn -> fail exn

(* -------------------------------------------------------------------------- *)

(* Inspired from async/core/lib/deferred.ml:enabled' *)
let gather' choices ~compute =
  let ivar = Ivar.create () in
  let unregisters = ref [] in
  let run value =
    if Ivar.is_empty ivar then (
      List.iter !unregisters ~f:(fun (ivar, h) -> Ivar.remove_handler ivar h);
      Ivar.fill ivar (compute value choices)
    )
  in
  List.iter choices ~f:(fun choice ->
    let h =
      Ivar.add_handler choice run Scheduler.(current_execution_context (t ()))
    in
    unregisters := (choice, h) :: !unregisters
  ) ;
  Ivar.upon ivar (
    function
    | Error Canceled -> List.iter choices ~f:(fun c -> cancel (thread c))
    | _ -> ()
  ) ;
  set_cancelable ivar ;
  thread ivar

let gather choices ~compute =
  (* we want choose (and his friends) to return immediatly if one the ivar is
   * already filled. *)
  let choices = List.map choices ~f:thread_repr in
  let ready t = Ivar.peek t in
  match List.find_map choices ~f:ready with
  | Some v ->
    let ivar = Ivar.create_full (compute v choices) in
    thread ivar
  | None -> gather' choices ~compute

let choose choices =
  let compute value _ = value in
  gather choices ~compute

let (<?>) t t' = choose [t ; t']

let nchoose choices =
  let compute _ choices =
    try
      let results = List.filter_map choices ~f:(fun t ->
        match Ivar.peek t with
        | None -> None
        | Some (Error exn) -> raise exn
        | Some (Ok a) -> Some a)
      in
      Ok results
    with exn -> Error exn
  in
  gather choices ~compute

let nchoose_split choices =
  let compute _ choices =
    try
      let results = List.partition_map choices ~f:(fun t ->
        match Ivar.peek t with
        | None -> `Snd (thread t)
        | Some (Error exn) -> raise exn
        | Some (Ok a) -> `Fst a)
      in
      Ok results
    with exn -> Error exn
  in
  gather choices ~compute

let pick choices =
  let compute value reprs =
    List.iter reprs ~f:(fun r -> cancel (thread r)) ;
    value
  in
  gather choices ~compute

let npick choices =
  let compute _ choices =
    try
      let results = List.filter_map choices ~f:(fun t ->
        match Ivar.peek t with
        | None -> cancel (thread t) ; None
        | Some (Error exn) -> raise exn
        | Some (Ok a) -> Some a)
      in
      Ok results
    with exn -> Error exn
  in
  gather choices ~compute

(* -------------------------------------------------------------------------- *)

let join threads' =
  let result = Ivar.create () in
  let error_opt = ref None in
  let threads = List.map threads' ~f:thread_repr in
  let rec aux = function
    | [] ->
      if Ivar.is_empty result (* it might have been canceled *) then
        Ivar.fill result (Option.value !error_opt ~default:(Ok ()))
    | t :: threads ->
      (* we want to avoid as much Scheduler involvement as possible *)
      begin match Ivar.peek t with
      | Some (Ok ()) -> aux threads
      | Some (error) ->
        error_opt := Option.first_some !error_opt (Some error) ;
        aux threads
      | None ->
        Ivar.upon t (function
          | Ok () -> aux threads
          | error ->
            error_opt := Option.first_some !error_opt (Some error) ;
            aux threads
        )
      end
  in
  aux threads ;
  Ivar.upon result (
    function
    | Error Canceled -> List.iter threads' ~f:cancel
    | _ -> ()
  ) ;
  set_cancelable result ;
  thread result

let (<&>) t t' = join [t;t']

(* -------------------------------------------------------------------------- *)

let async t_susp =
  let t = thread_repr (t_susp ()) in
  match Ivar.peek t with
  | Some (Ok _) -> ()
  | Some (Error exn) -> !async_exception_hook exn
  | None ->
    Ivar.upon t (
      function
      | Ok _ -> ()
      | Error exn -> !async_exception_hook exn
    )

let ignore_result t =
  let t = thread_repr t in
  match Ivar.peek t with
  | Some (Ok _) -> ()
  | Some (Error exn) -> raise exn
  | None ->
    Ivar.upon t (
      function
      | Ok _ -> ()
      | Error exn -> !async_exception_hook exn
    )

(* -------------------------------------------------------------------------- *)

(* Pasted from lwt.ml *)

let pause_hook = ref ignore

let paused_count = ref 0

let pause () =
  incr paused_count ;
  let def = Deferred.return (Ok ()) in
  set_cancelable def ;
  !pause_hook !paused_count ;
  def

let wakeup_paused () = paused_count := 0

let register_pause_notifier f = pause_hook := f

let paused_count () = !paused_count

(* -------------------------------------------------------------------------- *)

let on_success t f =
  let t = thread_repr t in
  Ivar.upon t (
    function
    | Ok a -> (try f a with e -> !async_exception_hook e)
    | _ -> ()
  )

let on_failure t f =
  let t = thread_repr t in
  Ivar.upon t (
    function
    | Error exn -> (try f exn with e -> !async_exception_hook e)
    | _ -> ()
  )

let on_termination t f =
  let t = thread_repr t in
  Ivar.upon t (fun _ -> try f () with e -> !async_exception_hook e)

let on_any t f g =
  let t = thread_repr t in
  Ivar.upon t (
    function
    | Ok a -> (try f a with e -> !async_exception_hook e)
    | Error exn -> (try g exn with e -> !async_exception_hook e)
  )

(* -------------------------------------------------------------------------- *)

let poll t =
  let t = thread_repr t in
  match Ivar.peek t with
  | None -> None
  | Some (Ok a) -> Some a
  | Some (Error exn) -> raise exn

let apply f seed = try f seed with e -> fail e
