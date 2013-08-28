(* Lightweight thread library for Objective Caml
 * http://www.ocsigen.org/lwt
 * Module Lwt_unix
 * Copyright (C) 2005-2008 Jérôme Vouillon
 * Laboratoire PPS - CNRS Université Paris Diderot
 *                    2009 Jérémie Dimino
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

#include "src/unix/lwt_config.ml"

open Core.Std
open Async.Std

let ok res = Ok res

open Caml

open Lwt

let not_supported s : [ `Not_supported_by_Lwt_Async ] =
  failwith (s ^ ": not supported by Lwt-Async")

(* +-----------------------------------------------------------------+
   | Configuration                                                   |
   +-----------------------------------------------------------------+ *)

type async_method =
  | Async_none
  | Async_detach
  | Async_switch

let default_async_method_var = ref Async_detach

let () =
  try
    match Sys.getenv "LWT_ASYNC_METHOD" with
      | "none" ->
          default_async_method_var := Async_none
      | "detach" ->
          default_async_method_var := Async_detach
      | "switch" ->
          default_async_method_var := Async_switch
      | str ->
          Printf.eprintf
            "%s: invalid lwt async method: '%s', must be 'none', 'detach' or 'switch'\n%!"
            (Filename.basename Sys.executable_name) str
  with Not_found ->
    ()

let default_async_method () = !default_async_method_var
let set_default_async_method am = default_async_method_var := am

let async_method_key = Lwt.new_key ()

let async_method () =
  match Lwt.get async_method_key with
    | Some am -> am
    | None -> !default_async_method_var

let with_async_none f =
  with_value async_method_key (Some Async_none) f

let with_async_detach f =
  with_value async_method_key (Some Async_detach) f

let with_async_switch f =
  with_value async_method_key (Some Async_switch) f

(* +-----------------------------------------------------------------+
   | Notifications management                                        |
   +-----------------------------------------------------------------+ *)

type notifications = ((unit -> unit) * bool) Int.Table.t

let notif_counter = ref 0

let notifications : notifications = Int.Table.create ()

let make_notification ?(once=false) f =
  let notif = !notif_counter in
  incr notif_counter ;
  Core.Std.Hashtbl.add_exn notifications ~key:notif ~data:(f, once) ;
  notif

let stop_notification = Core.Std.Hashtbl.remove notifications

let send_notification notif =
  Thread_safe.run_in_async_exn (fun () ->
    match Core.Std.Hashtbl.find notifications notif with
    | None -> ()
    | Some (f, once) ->
      if once then stop_notification notif;
      f ())

let call_notification = send_notification

let set_notification n f =
  let (_, once) = Core.Std.Hashtbl.find_exn notifications n in
  Core.Std.Hashtbl.replace notifications ~key:n ~data:(f, once)

(* +-----------------------------------------------------------------+
   | Sleepers                                                        |
   +-----------------------------------------------------------------+ *)

let sleep sec = Clock.after (Time.Span.of_sec sec) >>| ok

let yield () =
  (* HACK: if we just do [return ()], whoever binds on it from the Lwt side is
     going to see that it is filled and is going to run the function directly.
     So we bind on Async's side to force the suspension. *)
  Deferred.return () >>| ok

let auto_yield timeout =
  let limit = ref (Unix.gettimeofday () +. timeout) in
  fun () ->
    let current = Unix.gettimeofday () in
    if current >= !limit then begin
      limit := current +. timeout;
      yield ();
    end else
      return ()

exception Timeout

let timeout d = sleep d >> Lwt.fail Timeout

let with_timeout t f =
  Clock.with_timeout (Time.Span.of_sec t) (f ()) >>| function
  | `Result v -> v
  | `Timeout -> Error Timeout

(* +-----------------------------------------------------------------+
   | Jobs                                                            |
   +-----------------------------------------------------------------+ *)

type 'a job

external run_job_sync_no_result : 'a job -> unit = "lwt_unix_run_job_sync_no_result"
external run_job_sync : 'a job -> 'a = "lwt_unix_run_job_sync"

type some_deferred = Pack : ('a, exn) Result.t Ivar.t -> some_deferred
let jobs = ref []

let push_job ivar = jobs := (Pack ivar) :: !jobs

let execute_job ?async_method ~job ~result ~free =
  let _ = async_method in
  let ivar = Ivar.create () in
  push_job ivar ;
  let def =
    In_thread.run (fun () ->
      try
        run_job_sync_no_result job ;
        let x = result job in
        free job ;
        Ok x
      with exn ->
        Error exn
    )
  in
  upon def (fun res -> Ivar.fill_if_empty ivar res) ;
  Ivar.read ivar

let run_job ?async_method job =
  let _ = async_method in
  let ivar = Ivar.create () in
  push_job ivar ;
  upon
    (In_thread.run (fun () -> try Ok (run_job_sync job) with exn -> Error exn))
    (fun res -> Ivar.fill_if_empty ivar res)
  ;
  Ivar.read ivar

let abort_jobs exn =
  List.iter (fun (Pack ivar) ->
    if Ivar.is_full ivar then () else
    Ivar.fill ivar (Error exn)
  ) !jobs ;
  jobs := []

let cancel_jobs () = abort_jobs Lwt.Canceled

let wait_for_jobs () =
  let rec aux = function
    | [] -> return ()
    | (Pack ivar) :: ivars ->
      Deferred.bind (Ivar.read ivar) (fun _ -> aux ivars)
  in
  aux !jobs

(* +-----------------------------------------------------------------+
   | File descriptor wrappers                                        |
   +-----------------------------------------------------------------+ *)

module Raw_fd = Async_unix.Raw_fd

external raw_fd_of_fd : Fd.t -> Raw_fd.t = "%identity"
external raw_fd_to_fd : Raw_fd.t -> Fd.t = "%identity"

type state = Opened | Closed | Aborted of exn

type file_descr = {
  mutable aborted : exn Ivar.t ;
  fd : Fd.t ;
}

let make_file_descr fd = {
  aborted = Ivar.create () ;
  fd ;
}

let closed_exn = Unix.Unix_error (Unix.EBADF, "check_descriptor", "")

let state fd =
  match Deferred.peek (Ivar.read fd.aborted) with
  | None ->
    begin match Raw_fd.state (raw_fd_of_fd fd.fd) with
    | Raw_fd.State.Open -> Opened
    | _ -> Closed
    end
  | Some exn -> Aborted exn

let unix_file_descr t =
  (* Offers the same guaranties as the original function from [Lwt_unix]
     (i.e. none) *)
  (raw_fd_of_fd t.fd).Raw_fd.file_descr

let of_unix_file_descr ?blocking ?set_flags fd =
  let _, _ = blocking, set_flags in
  let kind = (* pasted from Fd.Kind *)
    let module U = Core.Std.Unix in
    let open Fd.Kind in
    let st = Unix.fstat fd in
    match st.Unix.st_kind with
    | Unix.S_REG | Unix.S_DIR | Unix.S_BLK | Unix.S_LNK -> File
    | Unix.S_CHR -> Char
    | Unix.S_FIFO -> Fifo
    | Unix.S_SOCK ->
      Socket (if Unix.getsockopt fd Unix.SO_ACCEPTCONN then `Passive else `Active)
  in
  let fd = Fd.create kind fd (Info.of_string "Lwt_unix.of_unix_file_descr") in
  make_file_descr fd

let mk_ch = of_unix_file_descr

let blocking fd =
  return (not (Fd.supports_nonblock fd.fd))

let set_blocking ?set_flags fd b =
  let _ = set_flags in
  let raw_fd = raw_fd_of_fd fd.fd in
  raw_fd.Raw_fd.supports_nonblock <- b

let abort fd exn =
  if not (Fd.is_closed fd.fd) then (
    if not (Ivar.is_empty fd.aborted) then fd.aborted <- Ivar.create () ;
    Ivar.fill fd.aborted exn
  )

let check_descriptor fd =
  match state fd with
  | Opened -> ()
  | _ -> raise closed_exn

#if windows

let unix_stub_readable fd = Unix.select [fd] [] [] 0.0 <> ([], [], [])
let unix_stub_writable fd = Unix.select [] [fd] [] 0.0 <> ([], [], [])

#else

external unix_stub_readable : Unix.file_descr -> bool = "lwt_unix_readable"
external unix_stub_writable : Unix.file_descr -> bool = "lwt_unix_writable"

#endif

let rec unix_readable fd =
  try
    unix_stub_readable fd
  with Unix.Unix_error (Unix.EINTR, _, _) ->
    unix_readable fd

let rec unix_writable fd =
  try
    unix_stub_writable fd
  with Unix.Unix_error (Unix.EINTR, _, _) ->
    unix_writable fd

let readable t =
  let nonblocking = Fd.supports_nonblock t.fd in
  Fd.with_file_descr_exn ~nonblocking t.fd unix_readable
let writable t =
  let nonblocking = Fd.supports_nonblock t.fd in
  Fd.with_file_descr_exn ~nonblocking t.fd unix_writable

let stdin = of_unix_file_descr ~set_flags:false ~blocking:true Unix.stdin
let stdout = of_unix_file_descr ~set_flags:false ~blocking:true Unix.stdout
let stderr = of_unix_file_descr ~set_flags:false ~blocking:true Unix.stderr

(* +-----------------------------------------------------------------+
   | Actions on file descriptors                                     |
   +-----------------------------------------------------------------+ *)

type io_event = Read | Write

exception Retry
exception Retry_write
exception Retry_read

let rec register_action ev t f =
  let open Async.Std (* we don't want to use Lwt combinators... *) in
  let kind = match ev with Read -> `Read | Write -> `Write in
  let interrupt = Deferred.ignore (Ivar.read t.aborted) in
  Deferred.bind (Fd.ready_to_interruptible ~interrupt t.fd kind) begin function
  | `Ready  ->
    begin try
      return (Ok (f ()))
    with
    | Retry
    | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _)
    | Sys_blocked_io ->
      register_action ev t f
    | Retry_read ->
      register_action Read t f
    | Retry_write ->
      register_action Write t f
    | exn ->
      fail exn
    end
  | `Bad_fd -> return (Error (Failure "wrap_syscall: bad fd"))
  | `Closed -> return (Error (Failure "wrap_syscall: closed"))
  | `Interrupted ->
    Ivar.read t.aborted (* already determined, won't block *) >>| fun exn -> Error exn
  end

let wrap_syscall ev t f =
  check_descriptor t ;
  let available =
    match ev with
    | Read  -> readable
    | Write -> writable
  in
  let non_block = Fd.supports_nonblock t.fd in
  try
    if non_block || available t then
      return (f ())
    else
      register_action ev t f
  with
  | Retry
  | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _)
  | Sys_blocked_io ->
    register_action ev t f
  | Retry_read ->
    register_action Read t f
  | Retry_write ->
    register_action Write t f
  | exn ->
    fail exn

(* +-----------------------------------------------------------------+
   | Generated jobs                                                  |
   +-----------------------------------------------------------------+ *)

module Jobs = Lwt_unix_jobs_generated.Make(struct type 'a t = 'a job end)

(* +-----------------------------------------------------------------+
   | Basic file input/output                                         |
   +-----------------------------------------------------------------+ *)

type open_flag =
    Unix.open_flag =
  | O_RDONLY
  | O_WRONLY
  | O_RDWR
  | O_NONBLOCK
  | O_APPEND
  | O_CREAT
  | O_TRUNC
  | O_EXCL
  | O_NOCTTY
  | O_DSYNC
  | O_SYNC
  | O_RSYNC
#if ocaml_version >= (3, 13)
  | O_SHARE_DELETE
#endif
#if ocaml_version >= (4, 01)
  | O_CLOEXEC
#endif

#if windows

let openfile name flags perms =
  return (of_unix_file_descr (Unix.openfile name flags perms))

#else

external open_job : string -> Unix.open_flag list -> int -> (Unix.file_descr * bool) job = "lwt_unix_open_job"

let openfile name flags perms =
  lwt fd, blocking = run_job (open_job name flags perms) in
  return (of_unix_file_descr ~blocking fd)

#endif

let close fd =
  abort fd closed_exn ;
  Fd.close fd.fd >>| ok

let wait_read ch =
  try_lwt
    if readable ch then
      return ()
    else
      register_action Read ch ignore

external stub_read : Unix.file_descr -> string -> int -> int -> int = "lwt_unix_read"
external read_job : Unix.file_descr -> string -> int -> int -> int job = "lwt_unix_read_job"

let read t buf pos len =
  if pos < 0 || len < 0 || pos > String.length buf - len then
    invalid_arg "Lwt_unix.read"
  else
    match Fd.supports_nonblock t.fd with
    | true ->
      wrap_syscall Read t (fun () ->
        Fd.with_file_descr_exn ~nonblocking:true t.fd (fun fd ->
          stub_read fd buf pos len))
    | false ->
      lwt () = wait_read t in
      run_job (read_job (unix_file_descr t) buf pos len)

let wait_write ch =
  try_lwt
    if writable ch then
      return ()
    else
      register_action Write ch ignore

external stub_write : Unix.file_descr -> string -> int -> int -> int = "lwt_unix_write"
external write_job : Unix.file_descr -> string -> int -> int -> int job = "lwt_unix_write_job"

let write t buf pos len =
  if pos < 0 || len < 0 || pos > String.length buf - len then
    invalid_arg "Lwt_unix.write"
  else
    match Fd.supports_nonblock t.fd with
    | true ->
      wrap_syscall Write t (fun () ->
        Fd.with_file_descr_exn ~nonblocking:true t.fd (fun fd ->
          stub_write fd buf pos len))
    | false ->
      lwt () = wait_write t in
      run_job (write_job (unix_file_descr t) buf pos len)

(* +-----------------------------------------------------------------+
   | Seeking and truncating                                          |
   +-----------------------------------------------------------------+ *)

type seek_command =
    Unix.seek_command =
  | SEEK_SET
  | SEEK_CUR
  | SEEK_END

#if windows

let lseek ch offset whence =
  check_descriptor ch;
  return (Unix.lseek (unix_file_descr ch) offset whence)

#else

let lseek ch offset whence =
  check_descriptor ch;
  run_job (Jobs.lseek_job (unix_file_descr ch) offset whence)

#endif

#if windows

let truncate name offset =
  return (Unix.truncate name offset)

#else

let truncate name offset =
  run_job (Jobs.truncate_job name offset)

#endif

#if windows

let ftruncate ch offset =
  check_descriptor ch;
  return (Unix.ftruncate (unix_file_descr ch) offset)

#else

let ftruncate ch offset =
  check_descriptor ch;
  run_job (Jobs.ftruncate_job (unix_file_descr ch) offset)

#endif

(* +-----------------------------------------------------------------+
   | File system synchronisation                                     |
   +-----------------------------------------------------------------+ *)

let fdatasync ch =
  check_descriptor ch;
  run_job (Jobs.fdatasync_job (unix_file_descr ch))

let fsync ch =
  check_descriptor ch;
  run_job (Jobs.fsync_job (unix_file_descr ch))

(* +-----------------------------------------------------------------+
   | File status                                                     |
   +-----------------------------------------------------------------+ *)

type file_perm = Unix.file_perm

type file_kind =
    Unix.file_kind =
  | S_REG
  | S_DIR
  | S_CHR
  | S_BLK
  | S_LNK
  | S_FIFO
  | S_SOCK

type stats =
    Unix.stats =
    {
      st_dev : int;
      st_ino : int;
      st_kind : file_kind;
      st_perm : file_perm;
      st_nlink : int;
      st_uid : int;
      st_gid : int;
      st_rdev : int;
      st_size : int;
      st_atime : float;
      st_mtime : float;
      st_ctime : float;
    }

#if windows

let stat name =
  return (Unix.stat name)

#else

external stat_job : string -> Unix.stats job = "lwt_unix_stat_job"

let stat name =
  run_job (stat_job name)

#endif

#if windows

let lstat name =
  return (Unix.lstat name)

#else

external lstat_job : string -> Unix.stats job = "lwt_unix_lstat_job"

let lstat name =
  run_job (lstat_job name)

#endif

#if windows

let fstat ch =
  check_descriptor ch;
  return (Unix.fstat (unix_file_descr ch))

#else

external fstat_job : Unix.file_descr -> Unix.stats job = "lwt_unix_fstat_job"

let fstat ch =
  check_descriptor ch;
  run_job (fstat_job (unix_file_descr ch))

#endif

#if windows

let isatty ch =
  check_descriptor ch;
  return (Unix.isatty (unix_file_descr ch))

#else

external isatty_job : Unix.file_descr -> bool job = "lwt_unix_isatty_job"

let isatty ch =
  check_descriptor ch;
  run_job (isatty_job (unix_file_descr ch))

#endif

(* +-----------------------------------------------------------------+
   | File operations on large files                                  |
   +-----------------------------------------------------------------+ *)

module LargeFile =
struct

  type stats =
      Unix.LargeFile.stats =
      {
        st_dev : int;
        st_ino : int;
        st_kind : file_kind;
        st_perm : file_perm;
        st_nlink : int;
        st_uid : int;
        st_gid : int;
        st_rdev : int;
        st_size : int64;
        st_atime : float;
        st_mtime : float;
        st_ctime : float;
      }

#if windows

  let lseek ch offset whence =
    check_descriptor ch;
    return (Unix.LargeFile.lseek (unix_file_descr ch) offset whence)

#else

  let lseek ch offset whence =
    check_descriptor ch;
    run_job (Jobs.lseek_64_job (unix_file_descr ch) offset whence)

#endif

#if windows

  let truncate name offset =
    return (Unix.LargeFile.truncate name offset)

#else

  let truncate name offset =
    run_job (Jobs.truncate_64_job name offset)

#endif

#if windows

  let ftruncate ch offset =
    check_descriptor ch;
    return (Unix.LargeFile.ftruncate (unix_file_descr ch) offset)

#else

  let ftruncate ch offset =
    check_descriptor ch;
    run_job (Jobs.ftruncate_64_job (unix_file_descr ch) offset)

#endif

#if windows

  let stat name =
    return (Unix.LargeFile.stat name)

#else

  external stat_job : string -> Unix.LargeFile.stats job = "lwt_unix_stat_64_job"

  let stat name =
    run_job (stat_job name)

#endif

#if windows

  let lstat name =
    return (Unix.LargeFile.lstat name)

#else

  external lstat_job : string -> Unix.LargeFile.stats job = "lwt_unix_lstat_64_job"

  let lstat name =
    run_job (lstat_job name)

#endif

#if windows

  let fstat ch =
    check_descriptor ch;
    return (Unix.LargeFile.fstat (unix_file_descr ch))

#else

  external fstat_job : Unix.file_descr -> Unix.LargeFile.stats job = "lwt_unix_fstat_64_job"

  let fstat ch =
    check_descriptor ch;
    run_job (fstat_job (unix_file_descr ch))

#endif

end

(* +-----------------------------------------------------------------+
   | Operations on file names                                        |
   +-----------------------------------------------------------------+ *)

#if windows

let unlink name =
  return (Unix.unlink name)

#else

let unlink name =
  run_job (Jobs.unlink_job name)

#endif

#if windows

let rename name1 name2 =
  return (Unix.rename name1 name2)

#else

let rename name1 name2 =
  run_job (Jobs.rename_job name1 name2)

#endif

#if windows

let link name1 name2 =
  return (Unix.link name1 name2)

#else

let link oldpath newpath =
  run_job (Jobs.link_job oldpath newpath)

#endif

(* +-----------------------------------------------------------------+
   | File permissions and ownership                                  |
   +-----------------------------------------------------------------+ *)

#if windows

let chmod name perms =
  return (Unix.chmod name perms)

#else

let chmod path mode =
  run_job (Jobs.chmod_job path mode)

#endif

#if windows

let fchmod ch perms =
  check_descriptor ch;
  return (Unix.fchmod (unix_file_descr ch) perms)

#else

let fchmod ch mode =
  check_descriptor ch;
  run_job (Jobs.fchmod_job (unix_file_descr ch) mode)

#endif

#if windows

let chown name uid gid =
  return (Unix.chown name uid gid)

#else

let chown path ower group =
  run_job (Jobs.chown_job path ower group)

#endif

#if windows

let fchown ch uid gid =
  check_descriptor ch;
  return (Unix.fchown (unix_file_descr ch) uid gid)

#else

let fchown ch ower group =
  check_descriptor ch;
  run_job (Jobs.fchown_job (unix_file_descr ch) ower group)

#endif

type access_permission =
    Unix.access_permission =
  | R_OK
  | W_OK
  | X_OK
  | F_OK

#if windows

let access name perms =
  return (Unix.access name perms)

#else

let access path mode =
  run_job (Jobs.access_job path mode)

#endif

(* +-----------------------------------------------------------------+
   | Operations on file descriptors                                  |
   +-----------------------------------------------------------------+ *)

let dup fd =
  let raw_fd = raw_fd_of_fd fd.fd in
  let raw_fd = Raw_fd.(create raw_fd.kind raw_fd.file_descr raw_fd.info) in
  let dup = make_file_descr (raw_fd_to_fd raw_fd) in
  dup.aborted <- fd.aborted ;
  dup

let dup2 t1 t2 =
  t2.aborted <- t1.aborted ;
  don't_wait_for (Fd.close t2.fd) ;
  let raw1 = raw_fd_of_fd t1.fd in
  let raw2 = raw_fd_of_fd t2.fd in
  let open Raw_fd in
  Unix.dup2 raw1.file_descr raw2.file_descr ;
  raw2.info <- raw1.info ;
  raw2.kind <- raw1.kind ;
  raw2.supports_nonblock <- raw1.supports_nonblock ;
  raw2.have_set_nonblock <- raw1.have_set_nonblock ;
  raw2.state <- raw1.state ;
  Async_unix.Read_write.replace_all raw2.watching ~f:(fun key _ ->
    Async_unix.Read_write.get raw1.watching key) ;
  raw2.watching_has_changed <- raw1.watching_has_changed ;
  raw2.num_active_syscalls <- raw1.num_active_syscalls ;
  upon (Ivar.read raw1.close_finished)
    (fun () -> Ivar.fill_if_empty raw2.close_finished ())

let set_close_on_exec ch =
  check_descriptor ch;
  Unix.set_close_on_exec (unix_file_descr ch)

let clear_close_on_exec ch =
  check_descriptor ch;
  Unix.clear_close_on_exec (unix_file_descr ch)

(* +-----------------------------------------------------------------+
   | Directories                                                     |
   +-----------------------------------------------------------------+ *)

#if windows

let mkdir name perms =
  return (Unix.mkdir name perms)

#else

let mkdir name perms =
  run_job (Jobs.mkdir_job name perms)

#endif

#if windows

let rmdir name =
  return (Unix.rmdir name)

#else

let rmdir name =
  run_job (Jobs.rmdir_job name)

#endif

#if windows

let chdir name =
  return (Unix.chdir name)

#else

let chdir path =
  run_job (Jobs.chdir_job path)

#endif

#if windows

let chroot name =
  return (Unix.chroot name)

#else

let chroot path =
  run_job (Jobs.chroot_job path)

#endif

type dir_handle = Unix.dir_handle

#if windows

let opendir name =
  return (Unix.opendir name)

#else

external opendir_job : string -> Unix.dir_handle job = "lwt_unix_opendir_job"

let opendir name =
  run_job (opendir_job name)

#endif

#if windows

let readdir handle =
  return (Unix.readdir handle)

#else

external readdir_job : Unix.dir_handle -> string job = "lwt_unix_readdir_job"

let readdir handle =
  run_job (readdir_job handle)

#endif

#if windows

let readdir_n handle count =
  if count < 0 then
    fail (Invalid_argument "Lwt_uinx.readdir_n")
  else
    let array = Array.make count "" in
    let rec fill i =
      if i = count then
        return array
      else
        match try array.(i) <- Unix.readdir handle; true with End_of_file -> false with
          | true ->
              fill (i + 1)
          | false ->
              return (Array.sub array 0 i)
    in
    fill 0

#else

external readdir_n_job : Unix.dir_handle -> int -> string array job = "lwt_unix_readdir_n_job"

let readdir_n handle count =
  if count < 0 then
    fail (Invalid_argument "Lwt_uinx.readdir_n")
  else
    run_job (readdir_n_job handle count)

#endif

#if windows

let rewinddir handle =
  return (Unix.rewinddir handle)

#else

external rewinddir_job : Unix.dir_handle -> unit job = "lwt_unix_rewinddir_job"

let rewinddir handle =
  run_job (rewinddir_job handle)

#endif

#if windows

let closedir handle =
  return (Unix.closedir handle)

#else

external closedir_job : Unix.dir_handle -> unit job = "lwt_unix_closedir_job"

let closedir handle =
  run_job (closedir_job handle)

#endif

type list_directory_state  =
  | LDS_not_started
  | LDS_listing of Unix.dir_handle
  | LDS_done

let cleanup_dir_handle state =
  match !state with
    | LDS_listing handle ->
        ignore (closedir handle)
    | LDS_not_started | LDS_done ->
        ()

let files_of_directory path =
  let state = ref LDS_not_started in
  Lwt_stream.concat
    (Lwt_stream.from
       (fun () ->
          match !state with
            | LDS_not_started ->
                lwt handle = opendir path in
                lwt entries =
                  try_lwt
                    readdir_n handle 1024
                  with exn ->
                    lwt () = closedir handle in
                    raise exn
                in
                if Array.length entries < 1024 then begin
                  state := LDS_done;
                  lwt () = closedir handle in
                  return (Some(Lwt_stream.of_array entries))
                end else begin
                  state := LDS_listing handle;
                  Gc.finalise cleanup_dir_handle state;
                  return (Some(Lwt_stream.of_array entries))
                end
            | LDS_listing handle ->
                lwt entries =
                  try_lwt
                    readdir_n handle 1024
                  with exn ->
                    lwt () = closedir handle in
                    raise exn
                in
                if Array.length entries < 1024 then begin
                  state := LDS_done;
                  lwt () = closedir handle in
                  return (Some(Lwt_stream.of_array entries))
                end else
                  return (Some(Lwt_stream.of_array entries))
            | LDS_done ->
                return None))

(* +-----------------------------------------------------------------+
   | Pipes and redirections                                          |
   +-----------------------------------------------------------------+ *)

let pipe () =
  let (out_fd, in_fd) = Unix.pipe() in
  (mk_ch ~blocking:Lwt_sys.windows out_fd, mk_ch ~blocking:Lwt_sys.windows in_fd)

let pipe_in () =
  let (out_fd, in_fd) = Unix.pipe() in
  (mk_ch ~blocking:Lwt_sys.windows out_fd, in_fd)

let pipe_out () =
  let (out_fd, in_fd) = Unix.pipe() in
  (out_fd, mk_ch ~blocking:Lwt_sys.windows in_fd)

#if windows

let mkfifo name perms =
  return (Unix.mkfifo name perms)

#else

let mkfifo name perms =
  run_job (Jobs.mkfifo_job name perms)

#endif

(* +-----------------------------------------------------------------+
   | Symbolic links                                                  |
   +-----------------------------------------------------------------+ *)

#if windows

let symlink name1 name2 =
  return (Unix.symlink name1 name2)

#else

let symlink name1 name2 =
  run_job (Jobs.symlink_job name1 name2)

#endif

#if windows

let readlink name =
  return (Unix.readlink name)

#else

external readlink_job : string -> string job = "lwt_unix_readlink_job"

let readlink name =
  run_job (readlink_job name)

#endif

(* +-----------------------------------------------------------------+
   | Locking                                                         |
   +-----------------------------------------------------------------+ *)

type lock_command =
    Unix.lock_command =
  | F_ULOCK
  | F_LOCK
  | F_TLOCK
  | F_TEST
  | F_RLOCK
  | F_TRLOCK

#if windows

let lockf ch cmd size =
  check_descriptor ch;
  return (Unix.lockf (unix_file_descr ch) cmd size)

#else

external lockf_job : Unix.file_descr -> Unix.lock_command -> int -> unit job = "lwt_unix_lockf_job"

let lockf ch cmd size =
  check_descriptor ch;
  run_job (lockf_job (unix_file_descr ch) cmd size)

#endif

(* +-----------------------------------------------------------------+
   | User id, group id                                               |
   +-----------------------------------------------------------------+ *)

type passwd_entry =
    Unix.passwd_entry =
  {
    pw_name : string;
    pw_passwd : string;
    pw_uid : int;
    pw_gid : int;
    pw_gecos : string;
    pw_dir : string;
    pw_shell : string
  }

type group_entry =
    Unix.group_entry =
  {
    gr_name : string;
    gr_passwd : string;
    gr_gid : int;
    gr_mem : string array
  }

#if windows || android

let getlogin () =
  return (Unix.getlogin ())

#else

external getlogin_job : unit -> string job = "lwt_unix_getlogin_job"

let getlogin () =
  run_job (getlogin_job ())

#endif

#if windows || android

let getpwnam name =
  return (Unix.getpwnam name)

#else

external getpwnam_job : string -> Unix.passwd_entry job = "lwt_unix_getpwnam_job"

let getpwnam name =
  run_job (getpwnam_job name)

#endif

#if windows || android

let getgrnam name =
  return (Unix.getgrnam name)

#else

external getgrnam_job : string -> Unix.group_entry job = "lwt_unix_getgrnam_job"

let getgrnam name =
  run_job (getgrnam_job name)

#endif

#if windows || android

let getpwuid uid =
  return (Unix.getpwuid uid)

#else

external getpwuid_job : int -> Unix.passwd_entry job = "lwt_unix_getpwuid_job"

let getpwuid uid =
  run_job (getpwuid_job uid)

#endif

#if windows || android

let getgrgid gid =
  return (Unix.getgrgid gid)

#else

external getgrgid_job : int -> Unix.group_entry job = "lwt_unix_getgrgid_job"

let getgrgid gid =
  run_job (getgrgid_job gid)

#endif

(* +-----------------------------------------------------------------+
   | Sockets                                                         |
   +-----------------------------------------------------------------+ *)

type msg_flag =
    Unix.msg_flag =
  | MSG_OOB
  | MSG_DONTROUTE
  | MSG_PEEK

#if windows
let stub_recv = Unix.recv
#else
external stub_recv : Unix.file_descr -> string -> int -> int -> Unix.msg_flag list -> int = "lwt_unix_recv"
#endif

let recv ch buf pos len flags =
  if pos < 0 || len < 0 || pos > String.length buf - len then
    invalid_arg "Lwt_unix.recv"
  else
    wrap_syscall Read ch (fun () -> stub_recv (unix_file_descr ch) buf pos len flags)

#if windows
let stub_send = Unix.send
#else
external stub_send : Unix.file_descr -> string -> int -> int -> Unix.msg_flag list -> int = "lwt_unix_send"
#endif

let send ch buf pos len flags =
  if pos < 0 || len < 0 || pos > String.length buf - len then
    invalid_arg "Lwt_unix.send"
  else
    wrap_syscall Write ch (fun () -> stub_send (unix_file_descr ch) buf pos len flags)

#if windows
let stub_recvfrom = Unix.recvfrom
#else
external stub_recvfrom : Unix.file_descr -> string -> int -> int -> Unix.msg_flag list -> int * Unix.sockaddr = "lwt_unix_recvfrom"
#endif

let recvfrom ch buf pos len flags =
  if pos < 0 || len < 0 || pos > String.length buf - len then
    invalid_arg "Lwt_unix.recvfrom"
  else
    wrap_syscall Read ch (fun () -> stub_recvfrom (unix_file_descr ch) buf pos len flags)

#if windows
let stub_sendto = Unix.sendto
#else
external stub_sendto : Unix.file_descr -> string -> int -> int -> Unix.msg_flag list -> Unix.sockaddr -> int = "lwt_unix_sendto_byte" "lwt_unix_sendto"
#endif

let sendto ch buf pos len flags addr =
  if pos < 0 || len < 0 || pos > String.length buf - len then
    invalid_arg "Lwt_unix.sendto"
  else
    wrap_syscall Write ch (fun () -> stub_sendto (unix_file_descr ch) buf pos len flags addr)

type io_vector = {
  iov_buffer : string;
  iov_offset : int;
  iov_length : int;
}

let io_vector ~buffer ~offset ~length = {
  iov_buffer = buffer;
  iov_offset = offset;
  iov_length = length;
}

let check_io_vectors func_name iovs =
  List.iter (fun iov ->
               if iov.iov_offset < 0
                 || iov.iov_length < 0
                 || iov.iov_offset > String.length iov.iov_buffer - iov.iov_length then
                   invalid_arg func_name) iovs

#if windows

let recv_msg ~socket ~io_vectors =
  raise (Lwt_sys.Not_available "recv_msg")

#else

external stub_recv_msg : Unix.file_descr -> int -> io_vector list -> int * Unix.file_descr list = "lwt_unix_recv_msg"

let recv_msg ~socket ~io_vectors =
  check_io_vectors "Lwt_unix.recv_msg" io_vectors;
  let n_iovs = List.length io_vectors in
  wrap_syscall Read socket
    (fun () ->
       stub_recv_msg (unix_file_descr socket) n_iovs io_vectors)

#endif

#if windows

let send_msg ~socket ~io_vectors ~fds =
  raise (Lwt_sys.Not_available "send_msg")

#else

external stub_send_msg : Unix.file_descr -> int -> io_vector list -> int -> Unix.file_descr list -> int = "lwt_unix_send_msg"

let send_msg ~socket ~io_vectors ~fds =
  check_io_vectors "Lwt_unix.send_msg" io_vectors;
  let n_iovs = List.length io_vectors and n_fds = List.length fds in
  wrap_syscall Write socket
    (fun () ->
       stub_send_msg (unix_file_descr socket) n_iovs io_vectors n_fds fds)

#endif

type inet_addr = Unix.inet_addr

type socket_domain =
    Unix.socket_domain =
  | PF_UNIX
  | PF_INET
  | PF_INET6

type socket_type =
    Unix.socket_type =
  | SOCK_STREAM
  | SOCK_DGRAM
  | SOCK_RAW
  | SOCK_SEQPACKET

type sockaddr = Unix.sockaddr = ADDR_UNIX of string | ADDR_INET of inet_addr * int

let socket dom typ proto =
  let s = Unix.socket dom typ proto in
  mk_ch ~blocking:false s

type shutdown_command =
    Unix.shutdown_command =
  | SHUTDOWN_RECEIVE
  | SHUTDOWN_SEND
  | SHUTDOWN_ALL

let shutdown ch shutdown_command =
  check_descriptor ch;
  Fd.syscall_exn ch.fd (fun fd -> Unix.shutdown fd shutdown_command)

#if windows

external socketpair_stub : socket_domain -> socket_type -> int -> Unix.file_descr * Unix.file_descr = "lwt_unix_socketpair_stub"

#else

let socketpair_stub = Unix.socketpair

#endif

let socketpair dom typ proto =
  let (s1, s2) = socketpair_stub dom typ proto in
  (mk_ch ~blocking:false s1, mk_ch ~blocking:false s2)

  (* copied from Async_unix.Unix.Socket *)
let accept_interruptible t ~interrupt =
  let module U = Unix in
  let open Async.Std in
  Deferred.repeat_until_finished () (fun () ->
    match
      (* We call [accept] with [~nonblocking:true] because there is no way to use
          [select] to guarantee that an [accept] will not block (see Stevens' book on
          Unix Network Programming, p422). *)
      Fd.with_file_descr t.fd ~nonblocking:true
        (fun file_descr ->
          U.accept file_descr)
    with
    | `Already_closed -> return (`Finished `Socket_closed)
    | `Ok (file_descr, sockaddr) ->
      let fd =
        Fd.create (Fd.Kind.Socket `Active) file_descr
          (Info.of_string "socket [ listening on t ] [ client addr ]")
      in
      let t = make_file_descr fd in
      set_close_on_exec t;
      return (`Finished (`Ok (t, sockaddr)))
    | `Error (U.Unix_error (_ , _, _)) ->
      Fd.ready_to_interruptible t.fd `Read ~interrupt
      >>| (function
      | `Ready -> `Repeat ()
      | `Interrupted as x -> `Finished x
      | `Closed -> `Finished `Socket_closed
      | `Bad_fd -> failwiths "accept on bad file descriptor" t.fd <:sexp_of< Fd.t >>)
    | `Error exn -> raise exn)

let accept t =
  check_descriptor t ;
  accept_interruptible t ~interrupt:(Deferred.never ())
  >>| function
    | `Interrupted -> assert false  (* impossible *)
    | `Socket_closed -> Error (Failure "Lwt_unix.accept: socket closed")
    | `Ok (fd, sockaddr) -> Ok (fd, sockaddr)

let accept_n t n =
  let l = ref [] in
  let aux fd =
    begin
      try
        for _i = 1 to n do
          let fd, addr = Unix.accept fd in
          let fd =
            Fd.create (Fd.Kind.Socket `Active) fd
              (Info.of_string "socket [ listening on t ] [ client addr ]")
          in
          l := (make_file_descr fd, addr) :: !l
        done
      with
      | (Unix.Unix_error((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _) | Retry)
        when !l <> [] ->
        ()
    end ;
    List.rev !l, None
  in
  wrap_syscall Read t (fun () ->
    Fd.with_file_descr_exn ~nonblocking:true t.fd aux)
  >>| function
  | Ok v -> Ok v
  | Error e -> Ok (List.rev !l, Some e)

let connect_interruptible t sockaddr ~interrupt =
  let success () =
    let info = Info.of_string "connected" in
    Fd.replace t.fd (Fd.Kind.Socket `Active) info;
    `Ok t;
  in
  let fail_closed () = failwiths "connect on closed fd" t.fd <:sexp_of< Fd.t >> in
  match
    Fd.with_file_descr t.fd ~nonblocking:true
      (fun file_descr -> Unix.connect file_descr sockaddr)
  with
  | `Already_closed -> fail_closed ()
  | `Ok () -> Deferred.return (success ())
  | `Error (Unix.Unix_error ((Unix.EINPROGRESS | Unix.EINTR), _, _)) as e -> begin
    Fd.ready_to_interruptible t.fd `Write ~interrupt
    >>| function
    | `Closed -> fail_closed ()
    | `Bad_fd -> failwiths "connect on bad file descriptor" t.fd <:sexp_of< Fd.t >>
    | `Interrupted as x -> x
    | `Ready ->
      (* We call [getsockopt] to find out whether the connect has succeed or failed. *)
      match
        Fd.with_file_descr t.fd (fun file_descr ->
          Unix.getsockopt_int file_descr Unix.SO_ERROR)
      with
      | `Already_closed -> fail_closed ()
      | `Error exn -> raise exn
      | `Ok err ->
        if err = 0 then
          success ()
        else
          e
  end
  | `Error e -> raise e

let connect t addr =
  check_descriptor t ;
  connect_interruptible t addr ~interrupt:(Deferred.never ())
  >>| function
    | `Interrupted -> assert false  (* impossible *)
    | `Ok _t -> Ok ()
    | `Error e -> Error e

let setsockopt ch opt v =
  check_descriptor ch;
  Unix.setsockopt (unix_file_descr ch) opt v

let bind t sockaddr =
  check_descriptor t;
  set_close_on_exec t;
  Fd.syscall_exn t.fd (fun file_descr -> Unix.bind file_descr sockaddr) ;
  let info = Info.of_string "socket bound on <sockaddr> (Lwt)" in
  Fd.replace t.fd (Fd.Kind.Socket `Bound) info

let listen t cnt =
  check_descriptor t;
  Fd.syscall_exn t.fd (fun file_descr ->
    Unix.listen file_descr cnt);
  Fd.replace t.fd (Fd.Kind.Socket `Passive) (Info.of_string "listening")

let getpeername ch =
  check_descriptor ch;
  Unix.getpeername (unix_file_descr ch)

let getsockname ch =
  check_descriptor ch;
  Unix.getsockname (unix_file_descr ch)

type credentials = {
  cred_pid : int;
  cred_uid : int;
  cred_gid : int;
}

#if HAVE_GET_CREDENTIALS

external stub_get_credentials : Unix.file_descr -> credentials = "lwt_unix_get_credentials"

let get_credentials ch =
  check_descriptor ch;
  stub_get_credentials (unix_file_descr ch)

#else

let get_credentials ch =
  raise (Lwt_sys.Not_available "get_credentials")

#endif

(* +-----------------------------------------------------------------+
   | Socket options                                                  |
   +-----------------------------------------------------------------+ *)

type socket_bool_option =
    Unix.socket_bool_option =
  | SO_DEBUG
  | SO_BROADCAST
  | SO_REUSEADDR
  | SO_KEEPALIVE
  | SO_DONTROUTE
  | SO_OOBINLINE
  | SO_ACCEPTCONN
  | TCP_NODELAY
  | IPV6_ONLY

type socket_int_option =
    Unix.socket_int_option =
  | SO_SNDBUF
  | SO_RCVBUF
  | SO_ERROR
  | SO_TYPE
  | SO_RCVLOWAT
  | SO_SNDLOWAT

type socket_optint_option = Unix.socket_optint_option = SO_LINGER

type socket_float_option =
    Unix.socket_float_option =
  | SO_RCVTIMEO
  | SO_SNDTIMEO

let getsockopt t o =
  check_descriptor t ;
  Fd.with_file_descr_exn t.fd (fun fd -> Unix.getsockopt fd o)
let setsockopt t o b =
  check_descriptor t ;
  Fd.with_file_descr_exn t.fd (fun fd -> Unix.setsockopt fd o b)

let getsockopt_int t o =
  check_descriptor t ;
  Fd.with_file_descr_exn t.fd (fun fd -> Unix.getsockopt_int fd o)
let setsockopt_int t o b =
  check_descriptor t ;
  Fd.with_file_descr_exn t.fd (fun fd -> Unix.setsockopt_int fd o b)

let getsockopt_optint t o =
  check_descriptor t ;
  Fd.with_file_descr_exn t.fd (fun fd -> Unix.getsockopt_optint fd o)
let setsockopt_optint t o b =
  check_descriptor t ;
  Fd.with_file_descr_exn t.fd (fun fd -> Unix.setsockopt_optint fd o b)

let getsockopt_float t o =
  check_descriptor t ;
  Fd.with_file_descr_exn t.fd (fun fd -> Unix.getsockopt_float fd o)
let setsockopt_float t o b =
  check_descriptor t ;
  Fd.with_file_descr_exn t.fd (fun fd -> Unix.setsockopt_float fd o b)

let getsockopt_error t =
  check_descriptor t ;
  Fd.with_file_descr_exn t.fd Unix.getsockopt_error

(* +-----------------------------------------------------------------+
   | Host and protocol databases                                     |
   +-----------------------------------------------------------------+ *)

type host_entry =
    Unix.host_entry =
    {
      h_name : string;
      h_aliases : string array;
      h_addrtype : socket_domain;
      h_addr_list : inet_addr array
    }

type protocol_entry =
    Unix.protocol_entry =
    {
      p_name : string;
      p_aliases : string array;
      p_proto : int
    }

type service_entry =
    Unix.service_entry =
    {
      s_name : string;
      s_aliases : string array;
      s_port : int;
      s_proto : string
    }

#if windows

let gethostname () =
  return (Unix.gethostname ())

#else

external gethostname_job : unit -> string job = "lwt_unix_gethostname_job"

let gethostname () =
  run_job (gethostname_job ())

#endif

#if windows

let gethostbyname name =
  return (Unix.gethostbyname name)

#else

external gethostbyname_job : string -> Unix.host_entry job = "lwt_unix_gethostbyname_job"

let gethostbyname name =
  run_job (gethostbyname_job name)

#endif

#if windows

let gethostbyaddr addr =
  return (Unix.gethostbyaddr addr)

#else

external gethostbyaddr_job : Unix.inet_addr -> Unix.host_entry job = "lwt_unix_gethostbyaddr_job"

let gethostbyaddr addr =
  run_job (gethostbyaddr_job addr)

#endif

#if windows

let getprotobyname name =
  return (Unix.getprotobyname name)

#else

external getprotobyname_job : string -> Unix.protocol_entry job = "lwt_unix_getprotobyname_job"

let getprotobyname name =
  run_job (getprotobyname_job name)

#endif

#if windows

let getprotobynumber number =
  return (Unix.getprotobynumber number)

#else

external getprotobynumber_job : int -> Unix.protocol_entry job = "lwt_unix_getprotobynumber_job"

let getprotobynumber number =
  run_job (getprotobynumber_job number)

#endif

#if windows

let getservbyname name x =
  return (Unix.getservbyname name x)

#else

external getservbyname_job : string -> string -> Unix.service_entry job = "lwt_unix_getservbyname_job"

let getservbyname name x =
  run_job (getservbyname_job name x)

#endif

#if windows

let getservbyport port x =
  return (Unix.getservbyport port x)

#else

external getservbyport_job : int -> string -> Unix.service_entry job = "lwt_unix_getservbyport_job"

let getservbyport port x =
  run_job (getservbyport_job port x)

#endif

type addr_info =
    Unix.addr_info =
    {
      ai_family : socket_domain;
      ai_socktype : socket_type;
      ai_protocol : int;
      ai_addr : sockaddr;
      ai_canonname : string;
    }

type getaddrinfo_option =
    Unix.getaddrinfo_option =
  | AI_FAMILY of socket_domain
  | AI_SOCKTYPE of socket_type
  | AI_PROTOCOL of int
  | AI_NUMERICHOST
  | AI_CANONNAME
  | AI_PASSIVE

#if windows

let getaddrinfo host service opts =
  return (Unix.getaddrinfo host service opts)

#else

external getaddrinfo_job : string -> string -> Unix.getaddrinfo_option list -> Unix.addr_info list job = "lwt_unix_getaddrinfo_job"

let getaddrinfo host service opts =
  run_job (getaddrinfo_job host service opts) >>= fun l ->
  return (List.rev l)

#endif

type name_info =
    Unix.name_info =
    {
      ni_hostname : string;
      ni_service : string;
    }

type getnameinfo_option =
    Unix.getnameinfo_option =
  | NI_NOFQDN
  | NI_NUMERICHOST
  | NI_NAMEREQD
  | NI_NUMERICSERV
  | NI_DGRAM

#if windows

let getnameinfo addr opts =
  return (Unix.getnameinfo addr opts)

#else

external getnameinfo_job : Unix.sockaddr -> Unix.getnameinfo_option list -> Unix.name_info job = "lwt_unix_getnameinfo_job"

let getnameinfo addr opts =
  run_job (getnameinfo_job addr opts)

#endif

(* +-----------------------------------------------------------------+
   | Terminal interface                                              |
   +-----------------------------------------------------------------+ *)

type terminal_io =
    Unix.terminal_io =
    {
      mutable c_ignbrk : bool;
      mutable c_brkint : bool;
      mutable c_ignpar : bool;
      mutable c_parmrk : bool;
      mutable c_inpck : bool;
      mutable c_istrip : bool;
      mutable c_inlcr : bool;
      mutable c_igncr : bool;
      mutable c_icrnl : bool;
      mutable c_ixon : bool;
      mutable c_ixoff : bool;
      mutable c_opost : bool;
      mutable c_obaud : int;
      mutable c_ibaud : int;
      mutable c_csize : int;
      mutable c_cstopb : int;
      mutable c_cread : bool;
      mutable c_parenb : bool;
      mutable c_parodd : bool;
      mutable c_hupcl : bool;
      mutable c_clocal : bool;
      mutable c_isig : bool;
      mutable c_icanon : bool;
      mutable c_noflsh : bool;
      mutable c_echo : bool;
      mutable c_echoe : bool;
      mutable c_echok : bool;
      mutable c_echonl : bool;
      mutable c_vintr : char;
      mutable c_vquit : char;
      mutable c_verase : char;
      mutable c_vkill : char;
      mutable c_veof : char;
      mutable c_veol : char;
      mutable c_vmin : int;
      mutable c_vtime : int;
      mutable c_vstart : char;
      mutable c_vstop : char;
    }

type setattr_when =
    Unix.setattr_when =
  | TCSANOW
  | TCSADRAIN
  | TCSAFLUSH

type flush_queue =
    Unix.flush_queue =
  | TCIFLUSH
  | TCOFLUSH
  | TCIOFLUSH

type flow_action =
    Unix.flow_action =
  | TCOOFF
  | TCOON
  | TCIOFF
  | TCION

#if windows

let tcgetattr ch =
  check_descriptor ch;
  return (Unix.tcgetattr (unix_file_descr ch))

#else

external tcgetattr_job : Unix.file_descr -> Unix.terminal_io job = "lwt_unix_tcgetattr_job"

let tcgetattr ch =
  check_descriptor ch;
  run_job (tcgetattr_job (unix_file_descr ch))

#endif

#if windows

let tcsetattr ch when_ attrs =
  check_descriptor ch;
  return (Unix.tcsetattr (unix_file_descr ch) when_ attrs)

#else

external tcsetattr_job : Unix.file_descr -> Unix.setattr_when -> Unix.terminal_io -> unit job = "lwt_unix_tcsetattr_job"

let tcsetattr ch when_ attrs =
  check_descriptor ch;
  run_job (tcsetattr_job (unix_file_descr ch) when_ attrs)

#endif

#if windows

let tcsendbreak ch delay =
  check_descriptor ch;
  return (Unix.tcsendbreak (unix_file_descr ch) delay)

#else

let tcsendbreak ch delay =
  check_descriptor ch;
  run_job (Jobs.tcsendbreak_job (unix_file_descr ch) delay)

#endif

#if windows || android

let tcdrain ch =
  check_descriptor ch;
  return (Unix.tcdrain (unix_file_descr ch))

#else

let tcdrain ch =
  check_descriptor ch;
  run_job (Jobs.tcdrain_job (unix_file_descr ch))

#endif

#if windows

let tcflush ch q =
  check_descriptor ch;
  return (Unix.tcflush (unix_file_descr ch) q)

#else

let tcflush ch q =
  check_descriptor ch;
  run_job (Jobs.tcflush_job (unix_file_descr ch) q)

#endif

#if windows

let tcflow ch act =
  check_descriptor ch;
  return (Unix.tcflow (unix_file_descr ch) act)

#else

let tcflow ch act =
  check_descriptor ch;
  run_job (Jobs.tcflow_job (unix_file_descr ch) act)

#endif

(* +-----------------------------------------------------------------+
   | Reading notifications                                           |
   +-----------------------------------------------------------------+ *)

(* +-----------------------------------------------------------------+
   | Signals                                                         |
   +-----------------------------------------------------------------+ *)

type signal_handler_id = unit Ivar.t

let on_signal signum handler =
  let canceler = Ivar.create () in
  Signal.handle ~stop:(Ivar.read canceler)
    [ Signal.of_caml_int signum ]
    ~f:(fun sign -> handler (Signal.to_caml_int sign)) ;
  canceler

let on_signal_full signum handler =
  let canceler = Ivar.create () in
  Signal.handle ~stop:(Ivar.read canceler)
    [ Signal.of_caml_int signum ]
    ~f:(fun sign -> handler canceler (Signal.to_caml_int sign)) ;
  canceler

let disable_signal_handler ivar = Ivar.fill_if_empty ivar ()

let signal_count () = not_supported "Lwt_unix.signal_count"

let reinstall_signal_handler _ =
  (* Useless: Async allows multiple handlers per signal *)
  ()

(* +-----------------------------------------------------------------+
   | Processes                                                       |
   +-----------------------------------------------------------------+ *)

let fork () = not_supported "Lwt_unix.fork"

type process_status =
    Unix.process_status =
  | WEXITED of int
  | WSIGNALED of int
  | WSTOPPED of int

type wait_flag =
    Unix.wait_flag =
  | WNOHANG
  | WUNTRACED

type resource_usage = { ru_utime : float; ru_stime : float }

#if windows || android

let has_wait4 = false

let stub_wait4 flags pid =
  let pid, status = Unix.waitpid flags pid in
  (pid, status, { ru_utime = 0.0; ru_stime = 0.0 })

#else

let has_wait4 = true

external stub_wait4 : Unix.wait_flag list -> int -> int * Unix.process_status * resource_usage = "lwt_unix_wait4"

#endif

let wait_children = Lwt_sequence.create ()
let wait_count () = Lwt_sequence.length wait_children

#if not windows
let () =
  ignore begin
    on_signal Sys.sigchld
      (fun _ ->
         Lwt_sequence.iter_node_l begin fun node ->
           let wakener, flags, pid = Lwt_sequence.get node in
           try
             let (pid', _, _) as v = stub_wait4 flags pid in
             if pid' <> 0 then begin
               Lwt_sequence.remove node;
               Lwt.wakeup wakener v
             end
           with e ->
             Lwt_sequence.remove node;
             Lwt.wakeup_exn wakener e
         end wait_children)
  end
#endif

let _waitpid flags pid =
  try_lwt
    return (Unix.waitpid flags pid)

#if windows

let waitpid = _waitpid

#else

let waitpid flags pid =
  if List.mem Unix.WNOHANG flags then
    _waitpid flags pid
  else
    let flags = Unix.WNOHANG :: flags in
    lwt ((pid', _) as res) = _waitpid flags pid in
    if pid' <> 0 then
      return res
    else begin
      let (res, w) = Lwt.task () in
      let node = Lwt_sequence.add_l (w, flags, pid) wait_children in
      Lwt.on_cancel res (fun _ -> Lwt_sequence.remove node);
      lwt (pid, status, _) = res in
      return (pid, status)
    end

#endif

let _wait4 flags pid =
  try_lwt
    return (stub_wait4 flags pid)

#if windows || android

let wait4 = _wait4

#else

let wait4 flags pid =
  if List.mem Unix.WNOHANG flags then
    _wait4 flags pid
  else
    let flags = Unix.WNOHANG :: flags in
    lwt (pid', _, _) as res = _wait4 flags pid in
    if pid' <> 0 then
      return res
    else begin
      let (res, w) = Lwt.task () in
      let node = Lwt_sequence.add_l (w, flags, pid) wait_children in
      Lwt.on_cancel res (fun _ -> Lwt_sequence.remove node);
      res
    end

#endif

let wait () = waitpid [] (-1)

#if windows

external system_job : string -> int job = "lwt_unix_system_job"

let system cmd =
  lwt code = run_job (system_job ("cmd.exe /c " ^ cmd)) in
  return (Unix.WEXITED code)

#else

let system cmd =
  match Unix.fork () with
    | 0 ->
        begin try
          Unix.execv "/bin/sh" [| "/bin/sh"; "-c"; cmd |]
        with _ ->
          exit 127
        end
    | id ->
        waitpid [] id >|= snd

#endif

(* +-----------------------------------------------------------------+
   | Misc                                                            |
   +-----------------------------------------------------------------+ *)

let runnable = ref true

let run a_lwt =
  if !runnable then runnable := false else
    failwith "[lwt.unix] run called inside another run" ;
  let a_result = Thread_safe.block_on_async_exn (fun () -> a_lwt) in
  runnable := true ;
  match a_result with
  | Error exn -> raise exn
  | Ok a -> a

let handle_unix_error f x =
  try_lwt
    f x
  with exn ->
    Unix.handle_unix_error (fun () -> raise exn) ()

(* +-----------------------------------------------------------------+
   | System thread pool                                              |
   +-----------------------------------------------------------------+ *)

let pool_size () = not_supported "pool_size"
let set_pool_size _ = not_supported "set_pool_size"
let thread_count _ = not_supported "thread_count"
let thread_waiting_count  _ = not_supported "thread_waiting_count"

(* +-----------------------------------------------------------------+
   | CPUs                                                            |
   +-----------------------------------------------------------------+ *)

#if HAVE_GETCPU
external get_cpu : unit -> int = "lwt_unix_get_cpu"
#else
let get_cpu () = raise (Lwt_sys.Not_available "get_cpu")
#endif

#if HAVE_AFFINITY

external stub_get_affinity : int -> int list = "lwt_unix_get_affinity"
external stub_set_affinity : int -> int list -> unit = "lwt_unix_set_affinity"

let get_affinity ?(pid=0) () = stub_get_affinity pid
let set_affinity ?(pid=0) l = stub_set_affinity pid l

#else

let get_affinity ?pid () = raise (Lwt_sys.Not_available "get_affinity")
let set_affinity ?pid l = raise (Lwt_sys.Not_available "set_affinity")

#endif

(* +-----------------------------------------------------------------+
   | Error printing                                                  |
   +-----------------------------------------------------------------+ *)

let () =
  Printexc.register_printer
    (function
       | Unix.Unix_error(error, func, arg) ->
           let error =
             match error with
               | Unix.E2BIG -> "E2BIG"
               | Unix.EACCES -> "EACCES"
               | Unix.EAGAIN -> "EAGAIN"
               | Unix.EBADF -> "EBADF"
               | Unix.EBUSY -> "EBUSY"
               | Unix.ECHILD -> "ECHILD"
               | Unix.EDEADLK -> "EDEADLK"
               | Unix.EDOM -> "EDOM"
               | Unix.EEXIST -> "EEXIST"
               | Unix.EFAULT -> "EFAULT"
               | Unix.EFBIG -> "EFBIG"
               | Unix.EINTR -> "EINTR"
               | Unix.EINVAL -> "EINVAL"
               | Unix.EIO -> "EIO"
               | Unix.EISDIR -> "EISDIR"
               | Unix.EMFILE -> "EMFILE"
               | Unix.EMLINK -> "EMLINK"
               | Unix.ENAMETOOLONG -> "ENAMETOOLONG"
               | Unix.ENFILE -> "ENFILE"
               | Unix.ENODEV -> "ENODEV"
               | Unix.ENOENT -> "ENOENT"
               | Unix.ENOEXEC -> "ENOEXEC"
               | Unix.ENOLCK -> "ENOLCK"
               | Unix.ENOMEM -> "ENOMEM"
               | Unix.ENOSPC -> "ENOSPC"
               | Unix.ENOSYS -> "ENOSYS"
               | Unix.ENOTDIR -> "ENOTDIR"
               | Unix.ENOTEMPTY -> "ENOTEMPTY"
               | Unix.ENOTTY -> "ENOTTY"
               | Unix.ENXIO -> "ENXIO"
               | Unix.EPERM -> "EPERM"
               | Unix.EPIPE -> "EPIPE"
               | Unix.ERANGE -> "ERANGE"
               | Unix.EROFS -> "EROFS"
               | Unix.ESPIPE -> "ESPIPE"
               | Unix.ESRCH -> "ESRCH"
               | Unix.EXDEV -> "EXDEV"
               | Unix.EWOULDBLOCK -> "EWOULDBLOCK"
               | Unix.EINPROGRESS -> "EINPROGRESS"
               | Unix.EALREADY -> "EALREADY"
               | Unix.ENOTSOCK -> "ENOTSOCK"
               | Unix.EDESTADDRREQ -> "EDESTADDRREQ"
               | Unix.EMSGSIZE -> "EMSGSIZE"
               | Unix.EPROTOTYPE -> "EPROTOTYPE"
               | Unix.ENOPROTOOPT -> "ENOPROTOOPT"
               | Unix.EPROTONOSUPPORT -> "EPROTONOSUPPORT"
               | Unix.ESOCKTNOSUPPORT -> "ESOCKTNOSUPPORT"
               | Unix.EOPNOTSUPP -> "EOPNOTSUPP"
               | Unix.EPFNOSUPPORT -> "EPFNOSUPPORT"
               | Unix.EAFNOSUPPORT -> "EAFNOSUPPORT"
               | Unix.EADDRINUSE -> "EADDRINUSE"
               | Unix.EADDRNOTAVAIL -> "EADDRNOTAVAIL"
               | Unix.ENETDOWN -> "ENETDOWN"
               | Unix.ENETUNREACH -> "ENETUNREACH"
               | Unix.ENETRESET -> "ENETRESET"
               | Unix.ECONNABORTED -> "ECONNABORTED"
               | Unix.ECONNRESET -> "ECONNRESET"
               | Unix.ENOBUFS -> "ENOBUFS"
               | Unix.EISCONN -> "EISCONN"
               | Unix.ENOTCONN -> "ENOTCONN"
               | Unix.ESHUTDOWN -> "ESHUTDOWN"
               | Unix.ETOOMANYREFS -> "ETOOMANYREFS"
               | Unix.ETIMEDOUT -> "ETIMEDOUT"
               | Unix.ECONNREFUSED -> "ECONNREFUSED"
               | Unix.EHOSTDOWN -> "EHOSTDOWN"
               | Unix.EHOSTUNREACH -> "EHOSTUNREACH"
               | Unix.ELOOP -> "ELOOP"
               | Unix.EOVERFLOW -> "EOVERFLOW"
               | Unix.EUNKNOWNERR n -> Printf.sprintf "EUNKNOWNERR %d" n
           in
           Some(Printf.sprintf "Unix.Unix_error(Unix.%s, %S, %S)" error func arg)
       | _ ->
           None)
