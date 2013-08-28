/* Lightweight thread library for Objective Caml
 * http://www.ocsigen.org/lwt
 * Module Lwt_unix_stubs
 * Copyright (C) 2009-2010 Jérémie Dimino
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
 */

#include "lwt_config.h"

#if defined(LWT_ON_WINDOWS)
#  include <winsock2.h>
#  include <windows.h>
#endif

#define _GNU_SOURCE
#define _POSIX_PTHREAD_SEMANTICS

#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/signals.h>
#include <caml/config.h>
#include <caml/custom.h>
#include <caml/bigarray.h>
#include <caml/callback.h>

#include <assert.h>
#include <stdio.h>
#include <signal.h>
#include <errno.h>

#if !defined(LWT_ON_WINDOWS) && defined(SIGRTMIN) && defined(SIGRTMAX)
#define LWT_UNIX_SIGNAL_ASYNC_SWITCH SIGRTMIN
#define LWT_UNIX_HAVE_ASYNC_SWITCH
#include <setjmp.h>
#else
#endif

#include "lwt_unix.h"

#if !defined(LWT_ON_WINDOWS)
#  include <unistd.h>
#  include <sys/socket.h>
#  include <sys/types.h>
#  include <sys/stat.h>
#  include <sys/param.h>
#  include <sys/un.h>
#  include <sys/mman.h>
#  include <string.h>
#  include <fcntl.h>
#  include <dirent.h>
#  include <pwd.h>
#  include <grp.h>
#  include <netdb.h>
#  include <termios.h>
#  include <sched.h>
#  include <netinet/in.h>
#  include <arpa/inet.h>
#endif

#if defined(HAVE_EVENTFD)
#  include <sys/eventfd.h>
#endif

//#define DEBUG_MODE

#if defined(DEBUG_MODE)
#  include <sys/syscall.h>
#  define DEBUG(fmt, ...) { fprintf(stderr, "lwt-debug[%d]: %s: " fmt "\n", (pid_t)syscall(SYS_gettid), __FUNCTION__, ##__VA_ARGS__); fflush(stderr); }
#else
#  define DEBUG(fmt, ...)
#endif

/* +-----------------------------------------------------------------+
   | OS-dependent functions                                          |
   +-----------------------------------------------------------------+ */

#if defined(LWT_ON_WINDOWS)
#  include "lwt_unix_windows.c"
#else
#  include "lwt_unix_unix.c"
#endif

/* +-----------------------------------------------------------------+
   | Utils                                                           |
   +-----------------------------------------------------------------+ */

void *lwt_unix_malloc(size_t size)
{
  void *ptr = malloc(size);
  if (ptr == NULL) {
    perror("cannot allocate memory");
    abort();
  }
  return ptr;
}

void *lwt_unix_realloc(void *ptr, size_t size)
{
  void *new_ptr = realloc(ptr, size);
  if (new_ptr == NULL) {
    perror("cannot allocate memory");
    abort();
  }
  return new_ptr;
}

char *lwt_unix_strdup(char *str)
{
  char *new_str = strdup(str);
  if (new_str == NULL) {
    perror("cannot allocate memory");
    abort();
  }
  return new_str;
}

void lwt_unix_not_available(char const *feature)
{
  caml_raise_with_arg(*caml_named_value("lwt:not-available"), caml_copy_string(feature));
}

/* +-----------------------------------------------------------------+
   | Operation on bigarrays                                          |
   +-----------------------------------------------------------------+ */

CAMLprim value lwt_unix_blit_bytes_bytes(value val_buf1, value val_ofs1, value val_buf2, value val_ofs2, value val_len)
{
  memmove((char*)Caml_ba_data_val(val_buf2) + Long_val(val_ofs2),
         (char*)Caml_ba_data_val(val_buf1) + Long_val(val_ofs1),
         Long_val(val_len));
  return Val_unit;
}

CAMLprim value lwt_unix_blit_string_bytes(value val_buf1, value val_ofs1, value val_buf2, value val_ofs2, value val_len)
{
  memcpy((char*)Caml_ba_data_val(val_buf2) + Long_val(val_ofs2),
         String_val(val_buf1) + Long_val(val_ofs1),
         Long_val(val_len));
  return Val_unit;
}

CAMLprim value lwt_unix_blit_bytes_string(value val_buf1, value val_ofs1, value val_buf2, value val_ofs2, value val_len)
{
  memcpy(String_val(val_buf2) + Long_val(val_ofs2),
         (char*)Caml_ba_data_val(val_buf1) + Long_val(val_ofs1),
         Long_val(val_len));
  return Val_unit;
}

CAMLprim value lwt_unix_fill_bytes(value val_buf, value val_ofs, value val_len, value val_char)
{
  memset((char*)Caml_ba_data_val(val_buf) + Long_val(val_ofs), Int_val(val_char), Long_val(val_len));
  return Val_unit;
}

CAMLprim value lwt_unix_mapped(value v_bstr)
{
  return Val_bool(Caml_ba_array_val(v_bstr)->flags & CAML_BA_MAPPED_FILE);
}

/* +-----------------------------------------------------------------+
   | Byte order                                                      |
   +-----------------------------------------------------------------+ */

value lwt_unix_system_byte_order()
{
#ifdef ARCH_BIG_ENDIAN
  return Val_int(1);
#else
  return Val_int(0);
#endif
}

/* +-----------------------------------------------------------------+
   | Threading                                                       |
   +-----------------------------------------------------------------+ */

#if defined(HAVE_PTHREAD)

void lwt_unix_launch_thread(void* (*start)(void*), void* data)
{
  pthread_t thread;
  pthread_attr_t attr;
  int result;

  pthread_attr_init(&attr);

  /* The thread is created in detached state so we do not have to join
     it when it terminates: */
  pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);

  result = pthread_create(&thread, &attr, start, data);

  if (result) unix_error(result, "launch_thread", Nothing);

  pthread_attr_destroy (&attr);
}

lwt_unix_thread lwt_unix_thread_self()
{
  return pthread_self();
}

int lwt_unix_thread_equal(lwt_unix_thread thread1, lwt_unix_thread thread2)
{
  return pthread_equal(thread1, thread2);
}

void lwt_unix_mutex_init(lwt_unix_mutex *mutex)
{
  pthread_mutex_init(mutex, NULL);
}

void lwt_unix_mutex_destroy(lwt_unix_mutex *mutex)
{
  pthread_mutex_destroy(mutex);
}

void lwt_unix_mutex_lock(lwt_unix_mutex *mutex)
{
  pthread_mutex_lock(mutex);
}

void lwt_unix_mutex_unlock(lwt_unix_mutex *mutex)
{
  pthread_mutex_unlock(mutex);
}

void lwt_unix_condition_init(lwt_unix_condition *condition)
{
  pthread_cond_init(condition, NULL);
}

void lwt_unix_condition_destroy(lwt_unix_condition *condition)
{
  pthread_cond_destroy(condition);
}

void lwt_unix_condition_signal(lwt_unix_condition *condition)
{
  pthread_cond_signal(condition);
}

void lwt_unix_condition_broadcast(lwt_unix_condition *condition)
{
  pthread_cond_broadcast(condition);
}

void lwt_unix_condition_wait(lwt_unix_condition *condition, lwt_unix_mutex *mutex)
{
  pthread_cond_wait(condition, mutex);
}

#elif defined(LWT_ON_WINDOWS)

void lwt_unix_launch_thread(void* (*start)(void*), void* data)
{
  HANDLE handle = CreateThread(NULL, 0, (LPTHREAD_START_ROUTINE)start, data, 0, NULL);
  if (handle) CloseHandle(handle);
}

lwt_unix_thread lwt_unix_thread_self()
{
  return GetCurrentThreadId();
}

int lwt_unix_thread_equal(lwt_unix_thread thread1, lwt_unix_thread thread2)
{
  return thread1 == thread2;
}

void lwt_unix_mutex_init(lwt_unix_mutex *mutex)
{
  InitializeCriticalSection(mutex);
}

void lwt_unix_mutex_destroy(lwt_unix_mutex *mutex)
{
  DeleteCriticalSection(mutex);
}

void lwt_unix_mutex_lock(lwt_unix_mutex *mutex)
{
  EnterCriticalSection(mutex);
}

void lwt_unix_mutex_unlock(lwt_unix_mutex *mutex)
{
  LeaveCriticalSection(mutex);
}

struct wait_list {
  HANDLE event;
  struct wait_list *next;
};

struct lwt_unix_condition {
  CRITICAL_SECTION mutex;
  struct wait_list *waiters;
};

void lwt_unix_condition_init(lwt_unix_condition *condition)
{
  InitializeCriticalSection(&condition->mutex);
  condition->waiters = NULL;
}

void lwt_unix_condition_destroy(lwt_unix_condition *condition)
{
  DeleteCriticalSection(&condition->mutex);
}

void lwt_unix_condition_signal(lwt_unix_condition *condition)
{
  struct wait_list *node;
  EnterCriticalSection(&condition->mutex);

  node = condition->waiters;
  if (node) {
    condition->waiters = node->next;
    SetEvent(node->event);
  }
  LeaveCriticalSection(&condition->mutex);
}

void lwt_unix_condition_broadcast(lwt_unix_condition *condition)
{
  struct wait_list *node;
  EnterCriticalSection(&condition->mutex);
  for (node = condition->waiters; node; node = node->next)
    SetEvent(node->event);
  condition->waiters = NULL;
  LeaveCriticalSection(&condition->mutex);
}

void lwt_unix_condition_wait(lwt_unix_condition *condition, lwt_unix_mutex *mutex)
{
  struct wait_list node;

  /* Create the event for the notification. */
  node.event = CreateEvent(NULL, FALSE, FALSE, NULL);

  /* Add the node to the condition. */
  EnterCriticalSection(&condition->mutex);
  node.next = condition->waiters;
  condition->waiters = &node;
  LeaveCriticalSection(&condition->mutex);

  /* Release the mutex. */
  LeaveCriticalSection(mutex);

  /* Wait for a signal. */
  WaitForSingleObject(node.event, INFINITE);

  /* The event is no more used. */
  CloseHandle(node.event);

  /* Re-acquire the mutex. */
  EnterCriticalSection(mutex);
}

#else

#  error "no threading library available!"

#endif

/* +-----------------------------------------------------------------+
   | Socketpair on windows                                           |
   +-----------------------------------------------------------------+ */

#if defined(LWT_ON_WINDOWS)

static void lwt_unix_socketpair(int domain, int type, int protocol, SOCKET sockets[2])
{
  union {
    struct sockaddr_in inaddr;
    struct sockaddr addr;
  } a;
  SOCKET listener;
  int addrlen = sizeof(a.inaddr);
  int reuse = 1;
  DWORD err;

  sockets[0] = INVALID_SOCKET;
  sockets[1] = INVALID_SOCKET;

  listener = socket(domain, type, protocol);
  if (listener == INVALID_SOCKET)
    goto failure;

  memset(&a, 0, sizeof(a));
  a.inaddr.sin_family = domain;
  a.inaddr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  a.inaddr.sin_port = 0;

  if (setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, (char*) &reuse, sizeof(reuse)) == -1)
    goto failure;

  if  (bind(listener, &a.addr, sizeof(a.inaddr)) == SOCKET_ERROR)
    goto failure;

  memset(&a, 0, sizeof(a));
  if  (getsockname(listener, &a.addr, &addrlen) == SOCKET_ERROR)
    goto failure;

  a.inaddr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  a.inaddr.sin_family = AF_INET;

  if (listen(listener, 1) == SOCKET_ERROR)
    goto failure;

  sockets[0] = socket(domain, type, protocol);
  if (sockets[0] == INVALID_SOCKET)
    goto failure;

  if (connect(sockets[0], &a.addr, sizeof(a.inaddr)) == SOCKET_ERROR)
    goto failure;

  sockets[1] = accept(listener, NULL, NULL);
  if (sockets[1] == INVALID_SOCKET)
    goto failure;

  closesocket(listener);
  return;

 failure:
  err = WSAGetLastError();
  closesocket(listener);
  closesocket(sockets[0]);
  closesocket(sockets[1]);
  win32_maperr(err);
  uerror("socketpair", Nothing);
}

static int socket_domain_table[] = {
  PF_UNIX, PF_INET
};

static int socket_type_table[] = {
  SOCK_STREAM, SOCK_DGRAM, SOCK_RAW, SOCK_SEQPACKET
};

CAMLprim value lwt_unix_socketpair_stub(value domain, value type, value protocol)
{
  CAMLparam3(domain, type, protocol);
  CAMLlocal1(result);
  SOCKET sockets[2];
  lwt_unix_socketpair(socket_domain_table[Int_val(domain)],
                      socket_type_table[Int_val(type)],
                      Int_val(protocol),
                      sockets);
  result = caml_alloc_tuple(2);
  Store_field(result, 0, win_alloc_socket(sockets[0]));
  Store_field(result, 1, win_alloc_socket(sockets[1]));
  CAMLreturn(result);
}

#endif

/* +-----------------------------------------------------------------+
   | Jobs                                                            |
   +-----------------------------------------------------------------+ */

/* Description of jobs. */
struct custom_operations job_ops = {
  "lwt.unix.job",
  custom_finalize_default,
  custom_compare_default,
  custom_hash_default,
  custom_serialize_default,
  custom_deserialize_default
};

/* Get the job structure contained in a custom value. */
#define Job_val(v) *(lwt_unix_job*)Data_custom_val(v)

value lwt_unix_alloc_job(lwt_unix_job job)
{
  value val_job = caml_alloc_custom(&job_ops, sizeof(lwt_unix_job), 0, 1);
  Job_val(val_job) = job;
  return val_job;
}

void lwt_unix_free_job(lwt_unix_job job)
{
  free(job);
}

CAMLprim value lwt_unix_self_result(value val_job)
{
  lwt_unix_job job = Job_val(val_job);
  return job->result(job);
}

CAMLprim value lwt_unix_run_job_sync_no_result(value val_job)
{
  lwt_unix_job job = Job_val(val_job);
  caml_enter_blocking_section();
  job->worker(job);
  caml_leave_blocking_section();
  return Val_unit;
}

CAMLprim value lwt_unix_run_job_sync(value val_job)
{
  lwt_unix_job job = Job_val(val_job);
  caml_enter_blocking_section();
  job->worker(job);
  caml_leave_blocking_section();
  return job->result(job);
}
