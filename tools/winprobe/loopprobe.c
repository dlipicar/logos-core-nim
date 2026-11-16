/* Step 5-4 (G107), Q11: the Winsock calls loopprobe.nim drives from chronos's
 * Windows dispatcher. Every call returns 0 or a positive Win32/WSA error code,
 * unless its comment says otherwise. Windows only. */
#define _WIN32_WINNT 0x0A00
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <mswsock.h>
#include <windows.h>
#include <winternl.h>
#include <stdint.h>
#include <string.h>

typedef struct {
  ADDRESS_FAMILY sun_family;
  char sun_path[108];
} lp_sun;
#define LP_GETPEERPID _WSAIOR(IOC_VENDOR, 256)
#ifndef SIO_BASE_HANDLE
#define SIO_BASE_HANDLE _WSAIOR(IOC_WS2, 34)
#endif

static int mkaddr(lp_sun *a, const char *p) {
  memset(a, 0, sizeof *a);
  a->sun_family = AF_UNIX;
  strncpy(a->sun_path, p, sizeof a->sun_path - 1);
  return (int)sizeof *a;
}

int lp_init(void) {
  WSADATA w;
  return WSAStartup(MAKEWORD(2, 2), &w);
}

/* An overlapped-capable AF_UNIX stream socket, or (uintptr_t)-1. */
uintptr_t lp_socket(void) {
  SOCKET s = WSASocketW(AF_UNIX, SOCK_STREAM, 0, NULL, 0, WSA_FLAG_OVERLAPPED);
  return s == INVALID_SOCKET ? (uintptr_t)-1 : (uintptr_t)s;
}

int lp_bind_listen(uintptr_t s, const char *p, int backlog) {
  lp_sun a;
  int n = mkaddr(&a, p);
  if (bind((SOCKET)s, (struct sockaddr *)&a, n) || listen((SOCKET)s, backlog))
    return WSAGetLastError();
  return 0;
}

int lp_bind(uintptr_t s, const char *p) {
  lp_sun a;
  int n = mkaddr(&a, p);
  return bind((SOCKET)s, (struct sockaddr *)&a, n) ? WSAGetLastError() : 0;
}

int lp_connect(uintptr_t s, const char *p) {
  lp_sun a;
  int n = mkaddr(&a, p);
  return connect((SOCKET)s, (struct sockaddr *)&a, n) ? WSAGetLastError() : 0;
}

/* Blocking accept; (uintptr_t)-1 on error. */
uintptr_t lp_accept(uintptr_t l) {
  SOCKET a = accept((SOCKET)l, NULL, NULL);
  return a == INVALID_SOCKET ? (uintptr_t)-1 : (uintptr_t)a;
}

int lp_nonblock(uintptr_t s, int on) {
  u_long v = (u_long)on;
  return ioctlsocket((SOCKET)s, FIONBIO, &v) ? WSAGetLastError() : 0;
}

int lp_close(uintptr_t s) { return closesocket((SOCKET)s) ? WSAGetLastError() : 0; }

int lp_shutdown_send(uintptr_t s) { return shutdown((SOCKET)s, SD_SEND) ? WSAGetLastError() : 0; }

/* Bytes received or sent (>= 0), or -error. */
long lp_recv(uintptr_t s, void *b, int n) {
  int r = recv((SOCKET)s, (char *)b, n, 0);
  return r >= 0 ? r : -(long)WSAGetLastError();
}
long lp_send(uintptr_t s, const void *b, int n) {
  int r = send((SOCKET)s, (const char *)b, n, 0);
  return r >= 0 ? r : -(long)WSAGetLastError();
}

/* The peer pid, or 0. */
unsigned long lp_peerpid(uintptr_t s) {
  ULONG pid = 0;
  DWORD ret = 0;
  if (WSAIoctl((SOCKET)s, LP_GETPEERPID, NULL, 0, &pid, sizeof pid, &ret, NULL, NULL)) return 0;
  return pid;
}

/* 1 if writable within ms, 0 if not, -error. */
int lp_writable(uintptr_t s, int ms) {
  fd_set w;
  FD_ZERO(&w);
  FD_SET((SOCKET)s, &w);
  struct timeval tv = {ms / 1000, (ms % 1000) * 1000};
  int n = select(0, NULL, &w, NULL, &tv);
  return n < 0 ? -WSAGetLastError() : n;
}

/* --------------------------------------------------- (a) overlapped I/O */

int lp_wsarecv(uintptr_t s, void *b, unsigned long n, void *ovl) {
  WSABUF wb;
  wb.len = n;
  wb.buf = (char *)b;
  DWORD flags = 0, got = 0;
  if (WSARecv((SOCKET)s, &wb, 1, &got, &flags, (LPWSAOVERLAPPED)ovl, NULL) == 0) return 0;
  int e = WSAGetLastError();
  return e == WSA_IO_PENDING ? 0 : e;
}

int lp_wsasend(uintptr_t s, const void *b, unsigned long n, void *ovl) {
  WSABUF wb;
  wb.len = n;
  wb.buf = (char *)b;
  DWORD sent = 0;
  if (WSASend((SOCKET)s, &wb, 1, &sent, 0, (LPWSAOVERLAPPED)ovl, NULL) == 0) return 0;
  int e = WSAGetLastError();
  return e == WSA_IO_PENDING ? 0 : e;
}

int lp_acceptex(uintptr_t l, uintptr_t a, void *buf, void *ovl) {
  LPFN_ACCEPTEX fn = NULL;
  GUID g = WSAID_ACCEPTEX;
  DWORD n = 0;
  if (WSAIoctl((SOCKET)l, SIO_GET_EXTENSION_FUNCTION_POINTER, &g, sizeof g, &fn, sizeof fn, &n,
               NULL, NULL))
    return WSAGetLastError();
  DWORD bytes = 0;
  if (fn((SOCKET)l, (SOCKET)a, buf, 0, sizeof(lp_sun) + 16, sizeof(lp_sun) + 16, &bytes,
         (LPOVERLAPPED)ovl))
    return 0;
  int e = WSAGetLastError();
  return e == ERROR_IO_PENDING ? 0 : e;
}

int lp_update_accept(uintptr_t a, uintptr_t l) {
  SOCKET ls = (SOCKET)l;
  return setsockopt((SOCKET)a, SOL_SOCKET, SO_UPDATE_ACCEPT_CONTEXT, (char *)&ls, sizeof ls)
             ? WSAGetLastError()
             : 0;
}

/* ConnectEx: *stage is 1 when loading the function failed, 2 when the call
 * failed, 3 when it is pending or done. */
int lp_connectex(uintptr_t s, const char *p, void *ovl, int *stage) {
  LPFN_CONNECTEX fn = NULL;
  GUID g = WSAID_CONNECTEX;
  DWORD n = 0;
  *stage = 1;
  if (WSAIoctl((SOCKET)s, SIO_GET_EXTENSION_FUNCTION_POINTER, &g, sizeof g, &fn, sizeof fn, &n,
               NULL, NULL))
    return WSAGetLastError();
  lp_sun a;
  int al = mkaddr(&a, p);
  *stage = 2;
  if (fn((SOCKET)s, (struct sockaddr *)&a, al, NULL, 0, NULL, (LPOVERLAPPED)ovl)) {
    *stage = 3;
    return 0;
  }
  int e = WSAGetLastError();
  if (e == ERROR_IO_PENDING) {
    *stage = 3;
    return 0;
  }
  return e;
}

/* ------------------------------------------- (c) WSAEventSelect readiness */

void *lp_event(void) { return CreateEventA(NULL, FALSE, FALSE, NULL); } /* auto-reset */

int lp_eventselect(uintptr_t s, void *ev, long mask) {
  return WSAEventSelect((SOCKET)s, (WSAEVENT)ev, mask) ? WSAGetLastError() : 0;
}

/* The recorded network events (FD_* bits), or -error; errs[i] per FD_*_BIT. */
long lp_enum_events(uintptr_t s, void *ev, int *errs) {
  WSANETWORKEVENTS ne;
  if (WSAEnumNetworkEvents((SOCKET)s, (WSAEVENT)ev, &ne)) return -(long)WSAGetLastError();
  for (int i = 0; i < FD_MAX_EVENTS; i++) errs[i] = ne.iErrorCode[i];
  return ne.lNetworkEvents;
}

void lp_close_handle(void *h) { CloseHandle((HANDLE)h); }

/* --------------------------------------------------------- (d) AFD poll */

typedef struct {
  HANDLE Handle;
  ULONG Events;
  NTSTATUS Status;
} lp_afd_handle_info;

typedef struct {
  LARGE_INTEGER Timeout;
  ULONG NumberOfHandles;
  ULONG Exclusive;
  lp_afd_handle_info Handles[1];
} lp_afd_poll_info;

#define LP_IOCTL_AFD_POLL 0x00012024
#ifndef STATUS_PENDING
#define STATUS_PENDING ((NTSTATUS)0x00000103L)
#endif

typedef NTSTATUS(NTAPI *ntcreatefile_t)(PHANDLE, ACCESS_MASK, POBJECT_ATTRIBUTES, PIO_STATUS_BLOCK,
                                        PLARGE_INTEGER, ULONG, ULONG, ULONG, ULONG, PVOID, ULONG);
typedef NTSTATUS(NTAPI *ntioctl_t)(HANDLE, HANDLE, PVOID, PVOID, PIO_STATUS_BLOCK, ULONG, PVOID,
                                   ULONG, PVOID, ULONG);
typedef ULONG(NTAPI *rtlstatus_t)(NTSTATUS);

static ntcreatefile_t p_create;
static ntioctl_t p_ioctl;
static rtlstatus_t p_status;

static int load_nt(void) {
  if (p_create) return 1;
  HMODULE nt = GetModuleHandleA("ntdll.dll");
  p_create = (ntcreatefile_t)(void *)GetProcAddress(nt, "NtCreateFile");
  p_ioctl = (ntioctl_t)(void *)GetProcAddress(nt, "NtDeviceIoControlFile");
  p_status = (rtlstatus_t)(void *)GetProcAddress(nt, "RtlNtStatusToDosError");
  return p_create && p_ioctl && p_status;
}

/* A handle to the AFD device for polling, or NULL with *err set. */
void *lp_afd_open(int *err) {
  if (!load_nt()) {
    *err = -1;
    return NULL;
  }
  static WCHAR name[] = L"\\Device\\Afd\\LcnProbe";
  UNICODE_STRING us;
  us.Length = (USHORT)(sizeof name - sizeof(WCHAR));
  us.MaximumLength = (USHORT)sizeof name;
  us.Buffer = name;
  OBJECT_ATTRIBUTES oa;
  InitializeObjectAttributes(&oa, &us, 0, NULL, NULL);
  IO_STATUS_BLOCK iosb;
  HANDLE h = NULL;
  NTSTATUS st = p_create(&h, SYNCHRONIZE, &oa, &iosb, NULL, 0, FILE_SHARE_READ | FILE_SHARE_WRITE,
                         1 /* FILE_OPEN */, 0, NULL, 0);
  if (st) {
    *err = (int)p_status(st);
    return NULL;
  }
  *err = 0;
  return h;
}

/* The base provider socket, or (uintptr_t)-1 with *err set. */
uintptr_t lp_base_handle(uintptr_t s, int *err) {
  SOCKET b = INVALID_SOCKET;
  DWORD n = 0;
  if (WSAIoctl((SOCKET)s, SIO_BASE_HANDLE, NULL, 0, &b, sizeof b, &n, NULL, NULL)) {
    *err = WSAGetLastError();
    return (uintptr_t)-1;
  }
  *err = 0;
  return (uintptr_t)b;
}

size_t lp_afd_info_size(void) { return sizeof(lp_afd_poll_info); }

/* Starts one poll of `base` for `events` (AFD_POLL_* bits). The completion goes
 * to the port `afd` is associated with, with `ovl` as its OVERLAPPED. */
int lp_afd_poll(void *afd, uintptr_t base, unsigned long events, void *info, void *ovl) {
  lp_afd_poll_info *pi = (lp_afd_poll_info *)info;
  memset(pi, 0, sizeof *pi);
  pi->Timeout.QuadPart = INT64_MAX;
  pi->NumberOfHandles = 1;
  pi->Exclusive = FALSE;
  pi->Handles[0].Handle = (HANDLE)base;
  pi->Handles[0].Events = events;
  IO_STATUS_BLOCK *iosb = (IO_STATUS_BLOCK *)ovl;
  iosb->Status = STATUS_PENDING;
  NTSTATUS st = p_ioctl((HANDLE)afd, NULL, NULL, ovl, iosb, LP_IOCTL_AFD_POLL, pi, sizeof *pi, pi,
                        sizeof *pi);
  if (st == 0 || st == STATUS_PENDING) return 0;
  return (int)p_status(st);
}

unsigned long lp_afd_events(void *info) {
  lp_afd_poll_info *pi = (lp_afd_poll_info *)info;
  return pi->NumberOfHandles ? pi->Handles[0].Events : 0;
}

/* ------------------------------------------------- child-process helpers */

int lp_lasterr(void) { return WSAGetLastError(); }

int lp_inherit(uintptr_t h, int on) {
  return SetHandleInformation((HANDLE)h, HANDLE_FLAG_INHERIT, on ? HANDLE_FLAG_INHERIT : 0)
             ? 0
             : (int)GetLastError();
}

/* Starts `cmd` with every inheritable handle; the process handle, or NULL. */
void *lp_spawn(char *cmd) {
  STARTUPINFOA si;
  PROCESS_INFORMATION pi;
  memset(&si, 0, sizeof si);
  si.cb = sizeof si;
  if (!CreateProcessA(NULL, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) return NULL;
  CloseHandle(pi.hThread);
  return pi.hProcess;
}

/* The exit code, or -1 on timeout. */
long lp_wait(void *p, int ms) {
  if (WaitForSingleObject((HANDLE)p, (DWORD)ms) != WAIT_OBJECT_0) return -1;
  DWORD code = 0;
  GetExitCodeProcess((HANDLE)p, &code);
  CloseHandle((HANDLE)p);
  return (long)code;
}

int lp_cancel(void *h, void *ovl) {
  return CancelIoEx((HANDLE)h, (LPOVERLAPPED)ovl) ? 0 : (int)GetLastError();
}
