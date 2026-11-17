/* Step 5-4 (G107): the Windows facts TRANSPORT §8.2.1 makes support depend on.
 *
 * One program, several roles chosen by argv[1], so it can spawn the processes a
 * question needs. Run with no argument (or `all [base]`) on a Windows machine: it
 * prints one `fact <question>.<name> <value>` line per measurement, and the build
 * it ran on (Q15), so two runs diff line by line. It needs no administrator rights
 * and changes no system setting; what the account cannot measure is reported as
 * `unmeasured`. The questions are those of tier5-plans/step5-4-windows.md §2.1.
 *
 * Build (MinGW-w64):
 *   gcc -O1 -Wall -o winprobe.exe winprobe.c -lws2_32 -ladvapi32 -lversion
 */
#define _WIN32_WINNT 0x0A00
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <mswsock.h>
#include <windows.h>
#include <winioctl.h>
#include <aclapi.h>
#include <winver.h>
#include <sddl.h>
#include <ntsecapi.h>
#include <wchar.h>
#include <stddef.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* afunix.h is not in every MinGW tree. */
#define LP_UNIX_PATH_MAX 108
typedef struct {
  ADDRESS_FAMILY sun_family;
  char sun_path[LP_UNIX_PATH_MAX];
} lp_sockaddr_un;
#ifndef SIO_AF_UNIX_GETPEERPID
#define SIO_AF_UNIX_GETPEERPID _WSAIOR(IOC_VENDOR, 256)
#endif
#ifndef IO_REPARSE_TAG_AF_UNIX
#define IO_REPARSE_TAG_AF_UNIX 0x80000023UL
#endif
/* GetCurrentProcessToken(): readable even when OpenProcessToken is refused. */
#define LP_SELF_TOKEN ((HANDLE)(LONG_PTR)-4)
#ifndef SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE
#define SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE 0x2
#endif

static HANDLE g_out = NULL; /* a child's result file; NULL: stdout */
static char g_self[MAX_PATH];
static char g_base[MAX_PATH]; /* the probe's scratch directory */
static char g_usersid[256];
static DWORD g_parent; /* the top-level probe's pid, for event names */
static char g_run[32] = "asis"; /* elevated, standard (filtered token) or asis */

/* ------------------------------------------------------------------ output */

static void fact(const char *name, const char *fmt, ...) {
  char buf[4096];
  int n = snprintf(buf, sizeof buf, "fact %s:%s ", g_run, name);
  va_list ap;
  va_start(ap, fmt);
  n += vsnprintf(buf + n, sizeof buf - n, fmt, ap);
  va_end(ap);
  if (n > (int)sizeof buf - 2) n = (int)sizeof buf - 2;
  buf[n++] = '\n';
  buf[n] = 0;
  if (g_out) {
    DWORD w;
    WriteFile(g_out, buf, (DWORD)n, &w, NULL);
  } else {
    fputs(buf, stdout);
    fflush(stdout);
  }
}

static const char *okerr(BOOL ok, DWORD err) {
  static char b[8][32];
  static int i = 0;
  i = (i + 1) % 8;
  if (ok) return "ok";
  snprintf(b[i], sizeof b[i], "err=%lu", (unsigned long)err);
  return b[i];
}
/* The error is read inside the function, after its argument (the call being
 * reported) has been evaluated. */
static const char *wsok(int r) {
  DWORD e = (DWORD)WSAGetLastError();
  return okerr(r == 0, e);
}
static const char *w32(BOOL r) {
  DWORD e = GetLastError();
  return okerr(r != 0, e);
}
#define WSOK(r) wsok(r)
#define W32(r) w32((BOOL)(r))

/* ----------------------------------------------------------------- sockets */

static int mkaddr(lp_sockaddr_un *a, const char *path) {
  memset(a, 0, sizeof *a);
  a->sun_family = AF_UNIX;
  strncpy(a->sun_path, path, sizeof a->sun_path - 1);
  return (int)sizeof *a;
}

static SOCKET usock(void) { return socket(AF_UNIX, SOCK_STREAM, 0); }

static int ubind(SOCKET s, const char *path) {
  lp_sockaddr_un a;
  int n = mkaddr(&a, path);
  return bind(s, (struct sockaddr *)&a, n);
}

static int uconnect(SOCKET s, const char *path) {
  lp_sockaddr_un a;
  int n = mkaddr(&a, path);
  return connect(s, (struct sockaddr *)&a, n);
}

/* A bound, listening socket at `path`, or INVALID_SOCKET with *err set. */
static SOCKET ulisten(const char *path, int backlog, int *err) {
  SOCKET s = usock();
  if (s == INVALID_SOCKET) { *err = WSAGetLastError(); return s; }
  if (ubind(s, path) != 0 || listen(s, backlog) != 0) {
    *err = WSAGetLastError();
    closesocket(s);
    return INVALID_SOCKET;
  }
  *err = 0;
  return s;
}

/* The peer pid through SIO_AF_UNIX_GETPEERPID, or (DWORD)-1 with *err set. */
static DWORD peerpid(SOCKET s, int *err) {
  ULONG pid = 0;
  DWORD ret = 0;
  if (WSAIoctl(s, SIO_AF_UNIX_GETPEERPID, NULL, 0, &pid, sizeof pid, &ret, NULL, NULL) != 0) {
    *err = WSAGetLastError();
    return (DWORD)-1;
  }
  *err = 0;
  return (DWORD)pid;
}

/* Waits up to ms for s to be readable (select); 1 readable, 0 timeout, -1 error. */
static int readable(SOCKET s, int ms) {
  fd_set r;
  FD_ZERO(&r);
  FD_SET(s, &r);
  struct timeval tv = {ms / 1000, (ms % 1000) * 1000};
  int n = select(0, &r, NULL, NULL, &tv);
  return n;
}

/* --------------------------------------------------------------- processes */

typedef struct {
  HANDLE proc, thread, outh;
  DWORD pid;
  char outpath[MAX_PATH];
  char role[64];
} child_t;

static HANDLE mkout(const char *role, const char *tag, char *path) {
  static int counter = 0;
  SECURITY_ATTRIBUTES sa = {sizeof sa, NULL, TRUE};
  snprintf(path, MAX_PATH, "%s\\r-%lu-%d-%s-%s.txt", g_base, (unsigned long)GetCurrentProcessId(),
           counter++, role, tag);
  return CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, &sa, CREATE_ALWAYS,
                     FILE_ATTRIBUTE_NORMAL, NULL);
}

/* Spawns `<self> <role> <outhandle> <tag> <args>`. The result file's handle is
 * always passed through PROC_THREAD_ATTRIBUTE_HANDLE_LIST with `extra` (which
 * must be inheritable); `inheritAll` instead inherits every inheritable handle
 * (the hygiene control). */
static BOOL spawn(child_t *c, const char *role, const char *tag, const char *args,
                  HANDLE *extra, int nextra, BOOL inheritAll, DWORD flags,
                  HANDLE token, const char *cwd) {
  memset(c, 0, sizeof *c);
  snprintf(c->role, sizeof c->role, "%s", role);
  c->outh = mkout(role, tag, c->outpath);
  if (c->outh == INVALID_HANDLE_VALUE) return FALSE;
  char cmd[4096];
  snprintf(cmd, sizeof cmd, "\"%s\" %s %llu %s %lu %s %s", g_self, role,
           (unsigned long long)(ULONG_PTR)c->outh, tag, (unsigned long)g_parent, g_base,
           args ? args : "");
  STARTUPINFOEXA si;
  ZeroMemory(&si, sizeof si);
  si.StartupInfo.cb = sizeof si;
  PROCESS_INFORMATION pi;
  ZeroMemory(&pi, sizeof pi);
  HANDLE list[16];
  int n = 0;
  list[n++] = c->outh;
  for (int i = 0; i < nextra && n < 16; i++) list[n++] = extra[i];
  LPPROC_THREAD_ATTRIBUTE_LIST al = NULL;
  if (!inheritAll) {
    SIZE_T sz = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &sz);
    al = (LPPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(GetProcessHeap(), 0, sz);
    if (!InitializeProcThreadAttributeList(al, 1, 0, &sz) ||
        !UpdateProcThreadAttribute(al, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, list,
                                   n * sizeof(HANDLE), NULL, NULL)) {
      DWORD e = GetLastError();
      HeapFree(GetProcessHeap(), 0, al);
      SetLastError(e);
      return FALSE;
    }
    si.lpAttributeList = al;
    flags |= EXTENDED_STARTUPINFO_PRESENT;
  }
  BOOL ok = token
                ? CreateProcessAsUserA(token, NULL, cmd, NULL, NULL, TRUE, flags, NULL, cwd,
                                       &si.StartupInfo, &pi)
                : CreateProcessA(NULL, cmd, NULL, NULL, TRUE, flags, NULL, cwd,
                                 &si.StartupInfo, &pi);
  DWORD e = GetLastError();
  if (al) {
    DeleteProcThreadAttributeList(al);
    HeapFree(GetProcessHeap(), 0, al);
  }
  if (!ok) {
    CloseHandle(c->outh);
    c->outh = NULL;
    SetLastError(e);
    return FALSE;
  }
  c->proc = pi.hProcess;
  c->thread = pi.hThread;
  c->pid = pi.dwProcessId;
  return TRUE;
}

/* Waits for the child (terminating it after ms), then copies its facts out. */
static void finish(child_t *c, DWORD ms, const char *q) {
  if (!c->proc) return;
  if (WaitForSingleObject(c->proc, ms) != WAIT_OBJECT_0) {
    char n[128];
    snprintf(n, sizeof n, "%s.%s.timeout", q, c->role);
    fact(n, "terminated after %lu ms", (unsigned long)ms);
    TerminateProcess(c->proc, 99);
    WaitForSingleObject(c->proc, 5000);
  }
  CloseHandle(c->outh);
  c->outh = NULL;
  FILE *f = fopen(c->outpath, "rb");
  if (f) {
    char line[4096];
    while (fgets(line, sizeof line, f)) {
      if (g_out) {
        DWORD w;
        WriteFile(g_out, line, (DWORD)strlen(line), &w, NULL);
      } else
        fputs(line, stdout);
    }
    fclose(f);
    fflush(stdout);
  }
  DeleteFileA(c->outpath);
  DWORD code = 0;
  if (GetExitCodeProcess(c->proc, &code) && code != 0) {
    char n[128];
    snprintf(n, sizeof n, "%s.%s.exit_code", q, c->role);
    fact(n, "0x%lx", (unsigned long)code);
  }
  CloseHandle(c->thread);
  CloseHandle(c->proc);
  c->proc = NULL;
}

static HANDLE event(const char *tag, const char *name) {
  char n[256];
  snprintf(n, sizeof n, "Local\\lcnprobe-%lu-%s-%s", (unsigned long)g_parent, tag, name);
  return CreateEventA(NULL, TRUE, FALSE, n);
}

static BOOL sid_of_token(HANDLE tok, char *out, size_t n) {
  BYTE buf[512];
  DWORD len = 0;
  if (!GetTokenInformation(tok, TokenUser, buf, sizeof buf, &len)) return FALSE;
  LPSTR s = NULL;
  if (!ConvertSidToStringSidA(((TOKEN_USER *)buf)->User.Sid, &s)) return FALSE;
  snprintf(out, n, "%s", s);
  LocalFree(s);
  return TRUE;
}

/* The operating-system identity of a token, as T l.1165 would compare it. */
static void token_summary(HANDLE tok, char *out, size_t n) {
  char user[256] = "?";
  sid_of_token(tok, user, sizeof user);
  TOKEN_ELEVATION el = {0};
  TOKEN_ELEVATION_TYPE et = 0;
  DWORD len;
  GetTokenInformation(tok, TokenElevation, &el, sizeof el, &len);
  GetTokenInformation(tok, TokenElevationType, &et, sizeof et, &len);
  BYTE buf[1024];
  DWORD il = 0;
  if (GetTokenInformation(tok, TokenIntegrityLevel, buf, sizeof buf, &len)) {
    PSID s = ((TOKEN_MANDATORY_LABEL *)buf)->Label.Sid;
    il = *GetSidSubAuthority(s, *GetSidSubAuthorityCount(s) - 1);
  }
  char logon[64] = "unknown";
  TOKEN_STATISTICS st;
  if (GetTokenInformation(tok, TokenStatistics, &st, sizeof st, &len)) {
    /* Loaded at run time: linking secur32 stops a restricted child from starting. */
    typedef NTSTATUS(NTAPI * getdata_t)(PLUID, PSECURITY_LOGON_SESSION_DATA *);
    typedef NTSTATUS(NTAPI * freebuf_t)(PVOID);
    HMODULE m = LoadLibraryA("secur32.dll");
    getdata_t getdata = m ? (getdata_t)(void *)GetProcAddress(m, "LsaGetLogonSessionData") : NULL;
    freebuf_t freebuf = m ? (freebuf_t)(void *)GetProcAddress(m, "LsaFreeReturnBuffer") : NULL;
    PSECURITY_LOGON_SESSION_DATA d = NULL;
    NTSTATUS r = getdata ? getdata(&st.AuthenticationId, &d) : (NTSTATUS)-1;
    if (!m)
      snprintf(logon, sizeof logon, "load-err=%lu", (unsigned long)GetLastError());
    else if (r == 0 && d) {
      snprintf(logon, sizeof logon, "%lu", (unsigned long)d->LogonType);
      freebuf(d);
    } else
      snprintf(logon, sizeof logon, "err=0x%lx", (unsigned long)r);
  } else
    snprintf(logon, sizeof logon, "stats-err=%lu", (unsigned long)GetLastError());
  snprintf(out, n, "user=%s elevated=%lu elevation_type=%d integrity=0x%lx logon_type=%s restricted=%d",
           user, (unsigned long)el.TokenIsElevated, (int)et, (unsigned long)il, logon,
           IsTokenRestricted(tok));
}

/* ---------------------------------------------------------- file security */

static HANDLE open_nofollow(const char *path, DWORD access) {
  return CreateFileA(path, access, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                     NULL, OPEN_EXISTING,
                     FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, NULL);
}

/* The owner and DACL of the object at path itself (reparse points not followed). */
static void sddl_of(const char *path, char *out, size_t n) {
  HANDLE h = open_nofollow(path, READ_CONTROL);
  if (h == INVALID_HANDLE_VALUE) {
    snprintf(out, n, "open-err=%lu", (unsigned long)GetLastError());
    return;
  }
  PSECURITY_DESCRIPTOR sd = NULL;
  DWORD r = GetSecurityInfo(h, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION |
                                               DACL_SECURITY_INFORMATION,
                            NULL, NULL, NULL, NULL, &sd);
  CloseHandle(h);
  if (r != ERROR_SUCCESS) {
    snprintf(out, n, "get-err=%lu", (unsigned long)r);
    return;
  }
  LPSTR s = NULL;
  if (ConvertSecurityDescriptorToStringSecurityDescriptorA(
          sd, SDDL_REVISION_1, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION, &s,
          NULL)) {
    snprintf(out, n, "%s", s);
    LocalFree(s);
  } else
    snprintf(out, n, "conv-err=%lu", (unsigned long)GetLastError());
  LocalFree(sd);
}

/* Sets a protected DACL given in SDDL ("D:P(...)") on the object at path itself. */
static DWORD set_dacl(const char *path, const char *sddl) {
  PSECURITY_DESCRIPTOR sd = NULL;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorA(sddl, SDDL_REVISION_1, &sd, NULL))
    return GetLastError();
  BOOL present = FALSE, def = FALSE;
  PACL dacl = NULL;
  GetSecurityDescriptorDacl(sd, &present, &dacl, &def);
  HANDLE h = open_nofollow(path, WRITE_DAC | READ_CONTROL);
  if (h == INVALID_HANDLE_VALUE) {
    DWORD e = GetLastError();
    LocalFree(sd);
    return e;
  }
  DWORD r = SetSecurityInfo(h, SE_FILE_OBJECT,
                            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                            NULL, NULL, dacl, NULL);
  CloseHandle(h);
  LocalFree(sd);
  return r;
}

/* Attributes, reparse tag and 128-bit file id of the object at path itself. */
typedef struct {
  DWORD err, attrs, tag;
  FILE_ID_INFO id;
} objinfo;

static objinfo info_of(const char *path) {
  objinfo o;
  memset(&o, 0, sizeof o);
  HANDLE h = open_nofollow(path, FILE_READ_ATTRIBUTES);
  if (h == INVALID_HANDLE_VALUE) {
    o.err = GetLastError();
    return o;
  }
  FILE_ATTRIBUTE_TAG_INFO t;
  if (!GetFileInformationByHandleEx(h, FileAttributeTagInfo, &t, sizeof t))
    o.err = GetLastError();
  else {
    o.attrs = t.FileAttributes;
    o.tag = t.ReparseTag;
  }
  if (!GetFileInformationByHandleEx(h, FileIdInfo, &o.id, sizeof o.id) && !o.err)
    o.err = GetLastError();
  CloseHandle(h);
  return o;
}

/* §8.2.1 l.1157's check: the object at path is the AF_UNIX socket object we
 * recorded, and no ancestor below `trusted` is a reparse point. */
static const char *validate(const char *path, const FILE_ID_INFO *expect, const char *trusted) {
  static char why[128];
  objinfo o = info_of(path);
  if (o.err) {
    snprintf(why, sizeof why, "reject:open-err=%lu", (unsigned long)o.err);
    return why;
  }
  if (!(o.attrs & FILE_ATTRIBUTE_REPARSE_POINT)) return "reject:not-reparse";
  if (o.tag != IO_REPARSE_TAG_AF_UNIX) {
    snprintf(why, sizeof why, "reject:tag=0x%08lx", (unsigned long)o.tag);
    return why;
  }
  if (expect && (o.id.VolumeSerialNumber != expect->VolumeSerialNumber ||
                 memcmp(&o.id.FileId, &expect->FileId, sizeof o.id.FileId) != 0))
    return "reject:id-mismatch";
  char p[MAX_PATH];
  snprintf(p, sizeof p, "%s", path);
  size_t tl = strlen(trusted);
  for (;;) {
    char *s = strrchr(p, '\\');
    if (!s || (size_t)(s - p) < tl) break;
    *s = 0;
    objinfo a = info_of(p);
    if (a.err) {
      snprintf(why, sizeof why, "reject:ancestor-open-err=%lu", (unsigned long)a.err);
      return why;
    }
    if (a.attrs & FILE_ATTRIBUTE_REPARSE_POINT) {
      snprintf(why, sizeof why, "reject:ancestor-reparse=0x%08lx", (unsigned long)a.tag);
      return why;
    }
  }
  return "accept";
}

/* A directory junction at `link` pointing at the absolute directory `target`. */
static DWORD mkjunction(const char *link, const char *target) {
  if (!CreateDirectoryA(link, NULL)) return GetLastError();
  WCHAR sub[MAX_PATH], prn[MAX_PATH];
  WCHAR wt[MAX_PATH];
  MultiByteToWideChar(CP_ACP, 0, target, -1, wt, MAX_PATH);
  _snwprintf(sub, MAX_PATH, L"\\??\\%ls", wt);
  _snwprintf(prn, MAX_PATH, L"%ls", wt);
  USHORT sl = (USHORT)(wcslen(sub) * sizeof(WCHAR)), pl = (USHORT)(wcslen(prn) * sizeof(WCHAR));
  BYTE buf[4096];
  memset(buf, 0, sizeof buf);
  struct {
    DWORD tag;
    WORD len, res, soff, slen, poff, plen;
  } *hdr = (void *)buf;
  hdr->tag = IO_REPARSE_TAG_MOUNT_POINT;
  hdr->soff = 0;
  hdr->slen = sl;
  hdr->poff = (WORD)(sl + sizeof(WCHAR));
  hdr->plen = pl;
  BYTE *pb = buf + 16;
  memcpy(pb, sub, sl);
  memcpy(pb + sl + sizeof(WCHAR), prn, pl);
  hdr->len = (WORD)(8 + sl + sizeof(WCHAR) + pl + sizeof(WCHAR));
  HANDLE h = CreateFileA(link, GENERIC_WRITE, 0, NULL, OPEN_EXISTING,
                         FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, NULL);
  if (h == INVALID_HANDLE_VALUE) return GetLastError();
  DWORD ret;
  BOOL ok = DeviceIoControl(h, FSCTL_SET_REPARSE_POINT, buf, 8 + hdr->len, NULL, 0, &ret, NULL);
  DWORD e = ok ? 0 : GetLastError();
  CloseHandle(h);
  return e;
}

/* The token the probe runs under: what the ACL facts depend on. */
static void token_facts(void) {
  HANDLE tok;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &tok)) return;
  TOKEN_ELEVATION el;
  TOKEN_ELEVATION_TYPE et = 0;
  DWORD len;
  BOOL elevated = GetTokenInformation(tok, TokenElevation, &el, sizeof el, &len) && el.TokenIsElevated;
  GetTokenInformation(tok, TokenElevationType, &et, sizeof et, &len);
  BYTE buf[8192];
  DWORD il = 0;
  if (GetTokenInformation(tok, TokenIntegrityLevel, buf, sizeof buf, &len)) {
    PSID s = ((TOKEN_MANDATORY_LABEL *)buf)->Label.Sid;
    il = *GetSidSubAuthority(s, *GetSidSubAuthorityCount(s) - 1);
  }
  char owner[256] = "";
  if (GetTokenInformation(tok, TokenOwner, buf, sizeof buf, &len)) {
    LPSTR s = NULL;
    if (ConvertSidToStringSidA(((TOKEN_OWNER *)buf)->Owner, &s)) {
      snprintf(owner, sizeof owner, "%s", s);
      LocalFree(s);
    }
  }
  fact("Q15.token", "elevated=%d elevation_type=%d integrity=0x%lx default_owner=%s restricted=%d",
       elevated, (int)et, (unsigned long)il, owner, IsTokenRestricted(tok));
  char privs[2048] = "";
  if (GetTokenInformation(tok, TokenPrivileges, buf, sizeof buf, &len)) {
    TOKEN_PRIVILEGES *tp = (TOKEN_PRIVILEGES *)buf;
    for (DWORD i = 0; i < tp->PrivilegeCount; i++) {
      if (!(tp->Privileges[i].Attributes & SE_PRIVILEGE_ENABLED)) continue;
      char nm[64];
      DWORD nl = sizeof nm;
      if (LookupPrivilegeNameA(NULL, &tp->Privileges[i].Luid, nm, &nl)) {
        strncat(privs, privs[0] ? "," : "", sizeof privs - strlen(privs) - 1);
        strncat(privs, nm, sizeof privs - strlen(privs) - 1);
      }
    }
  }
  fact("Q15.enabled_privileges", "%s", privs[0] ? privs : "none");
  CloseHandle(tok);
  char id[512];
  token_summary(LP_SELF_TOKEN, id, sizeof id);
  fact("Q15.token_identity", "%s", id);
}

/* A UAC-style filtered token from our own: Administrators deny-only, every
 * privilege but SeChangeNotify removed, medium integrity, the user as default
 * owner and a user-only default DACL. A restricted version of our own token,
 * so CreateProcessAsUser needs no privilege. */
static HANDLE make_standard_token(void) {
  HANDLE tok, std = NULL;
  if (!OpenProcessToken(GetCurrentProcess(),
                        TOKEN_DUPLICATE | TOKEN_ASSIGN_PRIMARY | TOKEN_QUERY | TOKEN_ADJUST_DEFAULT,
                        &tok))
    return NULL;
  PSID ba = NULL, me = NULL, med = NULL;
  ConvertStringSidToSidA("S-1-5-32-544", &ba);
  ConvertStringSidToSidA(g_usersid, &me);
  ConvertStringSidToSidA("S-1-16-8192", &med);
  SID_AND_ATTRIBUTES dis[1] = {{ba, 0}};
  if (!CreateRestrictedToken(tok, DISABLE_MAX_PRIVILEGE, 1, dis, 0, NULL, 0, NULL, &std)) {
    fact("Q15.standard_token", "create %s", okerr(FALSE, GetLastError()));
    std = NULL;
  } else {
    TOKEN_OWNER to = {me};
    BOOL o = SetTokenInformation(std, TokenOwner, &to, sizeof to);
    const char *os = W32(o);
    TOKEN_MANDATORY_LABEL ml;
    ml.Label.Sid = med;
    ml.Label.Attributes = SE_GROUP_INTEGRITY;
    BOOL i = SetTokenInformation(std, TokenIntegrityLevel, &ml, sizeof ml + GetLengthSid(med));
    const char *is = W32(i);
    char sddl[512];
    snprintf(sddl, sizeof sddl, "D:(A;;GA;;;%s)(A;;GA;;;SY)", g_usersid);
    PSECURITY_DESCRIPTOR sd = NULL;
    BOOL dd = FALSE;
    if (ConvertStringSecurityDescriptorToSecurityDescriptorA(sddl, SDDL_REVISION_1, &sd, NULL)) {
      BOOL pr, df;
      PACL acl = NULL;
      GetSecurityDescriptorDacl(sd, &pr, &acl, &df);
      TOKEN_DEFAULT_DACL tdd = {acl};
      dd = SetTokenInformation(std, TokenDefaultDacl, &tdd, sizeof tdd);
    }
    const char *ds = W32(dd);
    fact("Q15.standard_token", "create ok owner=%s integrity=%s default_dacl=%s", os, is, ds);
    if (sd) LocalFree(sd);
  }
  LocalFree(ba);
  LocalFree(me);
  LocalFree(med);
  CloseHandle(tok);
  return std;
}

/* ===================================================================== Q15 */

static void q15_build(void) {
  typedef LONG(WINAPI * rgv_t)(OSVERSIONINFOEXW *);
  OSVERSIONINFOEXW v;
  memset(&v, 0, sizeof v);
  v.dwOSVersionInfoSize = sizeof v;
  rgv_t rgv = (rgv_t)GetProcAddress(GetModuleHandleA("ntdll.dll"), "RtlGetVersion");
  if (rgv && rgv(&v) == 0)
    fact("Q15.version", "%lu.%lu.%lu", (unsigned long)v.dwMajorVersion,
         (unsigned long)v.dwMinorVersion, (unsigned long)v.dwBuildNumber);
  DWORD ubr = 0, sz = sizeof ubr;
  const char *key = "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion";
  if (RegGetValueA(HKEY_LOCAL_MACHINE, key, "UBR", RRF_RT_REG_DWORD, NULL, &ubr, &sz) == 0)
    fact("Q15.ubr", "%lu", (unsigned long)ubr);
  const char *names[] = {"ProductName", "DisplayVersion", "EditionID", "InstallationType"};
  for (int i = 0; i < 4; i++) {
    char s[256];
    DWORD n = sizeof s;
    char fn[64];
    snprintf(fn, sizeof fn, "Q15.%s", names[i]);
    if (RegGetValueA(HKEY_LOCAL_MACHINE, key, names[i], RRF_RT_REG_SZ, NULL, s, &n) == 0)
      fact(fn, "%s", s);
  }
  const char *drv = "C:\\Windows\\System32\\drivers\\afunix.sys";
  DWORD dummy, vs = GetFileVersionInfoSizeA(drv, &dummy);
  if (vs) {
    void *vb = malloc(vs);
    VS_FIXEDFILEINFO *fi;
    UINT fl;
    if (GetFileVersionInfoA(drv, 0, vs, vb) && VerQueryValueA(vb, "\\", (void **)&fi, &fl))
      fact("Q15.afunix_sys", "%u.%u.%u.%u", HIWORD(fi->dwFileVersionMS),
           LOWORD(fi->dwFileVersionMS), HIWORD(fi->dwFileVersionLS),
           LOWORD(fi->dwFileVersionLS));
    free(vb);
  } else
    fact("Q15.afunix_sys", "unreadable err=%lu", (unsigned long)GetLastError());
  BOOL inJob = FALSE;
  IsProcessInJob(GetCurrentProcess(), NULL, &inJob);
  fact("Q15.probe_in_job", "%d", (int)inJob);
  fact("Q15.user_sid", "%s", g_usersid);
}

/* ====================================================================== Q1 */

static void q1_basics(void) {
  char p[MAX_PATH], p2[MAX_PATH];
  int e;
  snprintf(p, sizeof p, "%s\\b1.sock", g_base);
  SOCKET l = ulisten(p, 8, &e);
  fact("Q1.listen", "%s", l == INVALID_SOCKET ? okerr(FALSE, e) : "ok");
  if (l == INVALID_SOCKET) return;

  WSAPROTOCOL_INFOW pi;
  int pl = sizeof pi;
  if (getsockopt(l, SOL_SOCKET, SO_PROTOCOL_INFOW, (char *)&pi, &pl) == 0) {
    fact("Q1.protocol", "%ls", pi.szProtocol);
    fact("Q1.service_flags1", "0x%08lx ifs_handles=%d", (unsigned long)pi.dwServiceFlags1,
         (pi.dwServiceFlags1 & XP1_IFS_HANDLES) ? 1 : 0);
    fact("Q1.provider_flags", "0x%08lx", (unsigned long)pi.dwProviderFlags);
  } else
    fact("Q1.protocol", "%s", WSOK(-1));

  objinfo o = info_of(p);
  fact("Q1.bound_object", "attrs=0x%08lx tag=0x%08lx err=%lu", (unsigned long)o.attrs,
       (unsigned long)o.tag, (unsigned long)o.err);

  /* What CreateFile without FILE_FLAG_OPEN_REPARSE_POINT does with a socket object. */
  HANDLE hf = CreateFileA(p, FILE_READ_ATTRIBUTES, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                          FILE_FLAG_BACKUP_SEMANTICS, NULL);
  fact("Q1.open_following", "%s", hf == INVALID_HANDLE_VALUE ? okerr(FALSE, GetLastError()) : "ok");
  if (hf != INVALID_HANDLE_VALUE) CloseHandle(hf);

  SOCKET s2 = usock();
  int r = ubind(s2, p);
  fact("Q1.bind_existing_socket", "%s", WSOK(r));
  closesocket(s2);

  snprintf(p2, sizeof p2, "%s\\plain.txt", g_base);
  HANDLE f = CreateFileA(p2, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
  CloseHandle(f);
  s2 = usock();
  fact("Q1.bind_existing_file", "%s", WSOK(ubind(s2, p2)));
  closesocket(s2);
  DeleteFileA(p2);

  int v = -1, vl = sizeof v;
  r = getsockopt(l, SOL_SOCKET, SO_ACCEPTCONN, (char *)&v, &vl);
  fact("Q1.so_acceptconn_listener", "%s value=%d", WSOK(r), v);
  snprintf(p2, sizeof p2, "%s\\b2.sock", g_base);
  s2 = usock();
  ubind(s2, p2);
  v = -1;
  vl = sizeof v;
  r = getsockopt(s2, SOL_SOCKET, SO_ACCEPTCONN, (char *)&v, &vl);
  fact("Q1.so_acceptconn_bound_only", "%s value=%d", WSOK(r), v);
  closesocket(s2);
  fact("Q1.bound_only_file_after_close", "%s",
       GetFileAttributesA(p2) == INVALID_FILE_ATTRIBUTES ? "absent" : "present");
  DeleteFileA(p2);

  lp_sockaddr_un a;
  int al = sizeof a;
  memset(&a, 0, sizeof a);
  r = getsockname(l, (struct sockaddr *)&a, &al);
  fact("Q1.getsockname", "%s len=%d match=%d", WSOK(r), al, strcmp(a.sun_path, p) == 0);

  v = -1;
  vl = sizeof v;
  getsockopt(l, SOL_SOCKET, SO_SNDBUF, (char *)&v, &vl);
  int rb = -1;
  vl = sizeof rb;
  getsockopt(l, SOL_SOCKET, SO_RCVBUF, (char *)&rb, &vl);
  fact("Q1.bufsizes", "sndbuf=%d rcvbuf=%d", v, rb);

  /* Path length: the longest name that binds. */
  {
    int best = 0;
    char lp[LP_UNIX_PATH_MAX + 16];
    for (int len = (int)strlen(g_base) + 8; len <= LP_UNIX_PATH_MAX + 2; len++) {
      int pad = len - (int)strlen(g_base) - 1;
      if (pad < 1) continue;
      snprintf(lp, sizeof lp, "%s\\", g_base);
      size_t k = strlen(lp);
      for (int i = 0; i < pad && k < sizeof lp - 1; i++) lp[k++] = 'x';
      lp[k] = 0;
      SOCKET t = usock();
      lp_sockaddr_un la;
      memset(&la, 0, sizeof la);
      la.sun_family = AF_UNIX;
      int fits = strlen(lp) <= sizeof la.sun_path;
      if (fits) memcpy(la.sun_path, lp, strlen(lp));
      if (fits && bind(t, (struct sockaddr *)&la, sizeof la) == 0) {
        best = (int)strlen(lp);
        closesocket(t);
        DeleteFileA(lp);
      } else
        closesocket(t);
    }
    fact("Q1.max_path_bytes", "%d (sun_path %d)", best, LP_UNIX_PATH_MAX);
  }

  /* connect, accept, the pid both ways in one process */
  SOCKET c = usock();
  r = uconnect(c, p);
  fact("Q1.connect", "%s", WSOK(r));
  SOCKET acc = accept(l, NULL, NULL);
  fact("Q1.accept", "%s", acc == INVALID_SOCKET ? WSOK(-1) : "ok");
  if (acc == INVALID_SOCKET) {
    closesocket(c);
    closesocket(l);
    return;
  }
  DWORD pc = peerpid(c, &e), pa = peerpid(acc, &e);
  fact("Q1.peerpid_same_process", "caller=%ld acceptor=%ld self=%lu", (long)pc, (long)pa,
       (unsigned long)GetCurrentProcessId());

  /* half-close */
  shutdown(c, SD_SEND);
  char b[16];
  int n = recv(acc, b, sizeof b, 0);
  fact("Q1.half_close_eof", "recv=%d", n);
  n = send(acc, "x", 1, 0);
  int n2 = recv(c, b, sizeof b, 0);
  fact("Q1.half_close_reply", "send=%d recv=%d", n, n2);
  closesocket(acc);
  n = recv(c, b, sizeof b, 0);
  fact("Q1.peer_close", "recv=%d err=%d", n, n < 0 ? WSAGetLastError() : 0);
  closesocket(c);

  /* select and WSAPoll on AF_UNIX */
  c = usock();
  uconnect(c, p);
  acc = accept(l, NULL, NULL);
  send(acc, "y", 1, 0);
  fact("Q1.select_readable", "%d", readable(c, 1000));
  WSAPOLLFD pf = {c, POLLRDNORM, 0};
  r = WSAPoll(&pf, 1, 1000);
  fact("Q1.wsapoll", "r=%d revents=0x%x", r, pf.revents);

  /* non-blocking: an empty read, and filling the send buffer */
  u_long nb = 1;
  ioctlsocket(c, FIONBIO, &nb);
  recv(c, b, 1, 0);
  n = recv(c, b, 1, 0);
  fact("Q1.nonblocking_empty_recv", "recv=%d err=%d", n, WSAGetLastError());
  {
    static char big[65536];
    long total = 0;
    int ferr = 0;
    for (int i = 0; i < 4096; i++) {
      int k = send(c, big, sizeof big, 0);
      if (k < 0) {
        ferr = WSAGetLastError();
        break;
      }
      total += k;
    }
    fact("Q1.fill_send", "buffered=%ld err=%d", total, ferr);
    fd_set w;
    FD_ZERO(&w);
    FD_SET(c, &w);
    struct timeval tv = {0, 200000};
    fact("Q1.select_writable_when_full", "%d", select(0, NULL, &w, NULL, &tv));
  }
  closesocket(acc);
  closesocket(c);

  /* non-blocking connects past the backlog */
  {
    char bp[MAX_PATH];
    snprintf(bp, sizeof bp, "%s\\bl.sock", g_base);
    SOCKET bl = ulisten(bp, 1, &e);
    char res[512] = "";
    SOCKET cs[6];
    for (int i = 0; i < 6; i++) {
      cs[i] = usock();
      ioctlsocket(cs[i], FIONBIO, &nb);
      int rr = uconnect(cs[i], bp);
      char one[32];
      snprintf(one, sizeof one, "%s%d", i ? "," : "", rr == 0 ? 0 : WSAGetLastError());
      strncat(res, one, sizeof res - strlen(res) - 1);
    }
    fact("Q1.nonblocking_connect_past_backlog", "%s", res);
    fd_set w;
    FD_ZERO(&w);
    for (int i = 0; i < 6; i++) FD_SET(cs[i], &w);
    struct timeval tv = {0, 200000};
    fact("Q1.connect_writable_before_accept", "%d", select(0, NULL, &w, NULL, &tv));
    for (int i = 0; i < 6; i++) closesocket(cs[i]);
    closesocket(bl);
    DeleteFileA(bp);
  }

  /* deleting the path while listening */
  BOOL del = DeleteFileA(p);
  fact("Q1.delete_while_listening", "%s", W32(del));
  c = usock();
  r = uconnect(c, p);
  fact("Q1.connect_after_delete", "%s", WSOK(r));
  closesocket(c);
  SOCKET l2 = ulisten(p, 8, &e);
  fact("Q1.rebind_after_delete_old_open", "%s", l2 == INVALID_SOCKET ? okerr(FALSE, e) : "ok");
  if (l2 != INVALID_SOCKET) {
    c = usock();
    uconnect(c, p);
    nb = 1;
    ioctlsocket(l, FIONBIO, &nb);
    ioctlsocket(l2, FIONBIO, &nb);
    Sleep(50);
    SOCKET x1 = accept(l, NULL, NULL), x2 = accept(l2, NULL, NULL);
    fact("Q1.rebind_who_accepts", "old=%d new=%d", x1 != INVALID_SOCKET, x2 != INVALID_SOCKET);
    if (x1 != INVALID_SOCKET) closesocket(x1);
    if (x2 != INVALID_SOCKET) closesocket(x2);
    closesocket(c);
    closesocket(l2);
  }
  closesocket(l);
  fact("Q1.file_after_listener_close", "%s",
       GetFileAttributesA(p) == INVALID_FILE_ATTRIBUTES ? "absent" : "present");
  DeleteFileA(p);
}

/* ================================================================ Q2-Q5 */

/* Child: a Module Host serving a transferred listener. Args after the common
 * ones: <mode inherit|dup> <socket-value|info-file> <naccept>. */
static int role_host(int argc, char **argv, const char *tag) {
  if (argc < 9) return 2;
  const char *mode = argv[6];
  int nacc = atoi(argv[8]);
  char q[96];
  SOCKET s = INVALID_SOCKET;
  if (strcmp(mode, "inherit") == 0) {
    s = (SOCKET)_strtoui64(argv[7], NULL, 10);
  } else {
    HANDLE ei = event(tag, "info");
    WaitForSingleObject(ei, 20000);
    WSAPROTOCOL_INFOW pi;
    FILE *f = fopen(argv[7], "rb");
    size_t got = f ? fread(&pi, 1, sizeof pi, f) : 0;
    if (f) fclose(f);
    if (got != sizeof pi) {
      snprintf(q, sizeof q, "Q3.%s.host_info", tag);
      fact(q, "unreadable");
      return 3;
    }
    s = WSASocketW(FROM_PROTOCOL_INFO, FROM_PROTOCOL_INFO, FROM_PROTOCOL_INFO, &pi, 0,
                   WSA_FLAG_OVERLAPPED);
    snprintf(q, sizeof q, "Q3.%s.host_wsasocket", tag);
    fact(q, "%s value=%llu", s == INVALID_SOCKET ? WSOK(-1) : "ok", (unsigned long long)s);
    int t0 = -1, tl0 = sizeof t0;
    int r0 = getsockopt(s, SOL_SOCKET, SO_TYPE, (char *)&t0, &tl0);
    snprintf(q, sizeof q, "Q3.%s.host_dup_usable_before_reuse", tag);
    fact(q, "%s so_type=%d", WSOK(r0), t0);
    SOCKET again = WSASocketW(FROM_PROTOCOL_INFO, FROM_PROTOCOL_INFO, FROM_PROTOCOL_INFO, &pi,
                              0, WSA_FLAG_OVERLAPPED);
    int t1 = -1, tl1 = sizeof t1;
    int r1 = again == INVALID_SOCKET ? -1 : getsockopt(again, SOL_SOCKET, SO_TYPE, (char *)&t1, &tl1);
    snprintf(q, sizeof q, "Q4.%s.info_reused_by_target", tag);
    fact(q, "%s same_value=%d usable=%d", again == INVALID_SOCKET ? WSOK(-1) : "returned",
         again == s, r1 == 0);
    if (again != INVALID_SOCKET && again != s) closesocket(again);
  }
  int t = -1, tl = sizeof t;
  int r = getsockopt(s, SOL_SOCKET, SO_TYPE, (char *)&t, &tl);
  snprintf(q, sizeof q, "Q3.%s.host_listener_usable", tag);
  fact(q, "%s so_type=%d", WSOK(r), t);
  int ac = -1;
  tl = sizeof ac;
  getsockopt(s, SOL_SOCKET, SO_ACCEPTCONN, (char *)&ac, &tl);
  snprintf(q, sizeof q, "Q3.%s.host_acceptconn", tag);
  fact(q, "%d", ac);
  snprintf(q, sizeof q, "Q2.%s.host_pid", tag);
  fact(q, "%lu", (unsigned long)GetCurrentProcessId());
  SetEvent(event(tag, "ready"));
  WaitForSingleObject(event(tag, "go"), 20000);
  for (int i = 0; i < nacc; i++) {
    int rd = readable(s, 15000);
    if (rd == 0) {
      snprintf(q, sizeof q, "Q2.%s.host_accept%d", tag, i);
      fact(q, "not-readable in 15 s");
      break;
    } /* rd < 0: select refused the socket; accept blocks instead */
    SOCKET a = accept(s, NULL, NULL);
    snprintf(q, sizeof q, "Q2.%s.host_accept%d", tag, i);
    if (a == INVALID_SOCKET) {
      fact(q, "%s", WSOK(-1));
      break;
    }
    int e;
    DWORD pp = peerpid(a, &e);
    fact(q, "ok accepted_peerpid=%ld", (long)pp);
    /* Q14: checking the connecting client's token from that pid */
    HANDLE ph = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pp);
    char sid[256] = "";
    if (ph) {
      HANDLE tok;
      if (OpenProcessToken(ph, TOKEN_QUERY, &tok)) {
        sid_of_token(tok, sid, sizeof sid);
        CloseHandle(tok);
      }
      CloseHandle(ph);
    }
    snprintf(q, sizeof q, "Q14.%s.acceptor_reads_client_token", tag);
    fact(q, "%s same_user=%d", ph ? "ok" : okerr(FALSE, GetLastError()),
         strcmp(sid, g_usersid) == 0);
    send(a, "k", 1, 0);
    Sleep(100);
    closesocket(a);
  }
  WaitForSingleObject(event(tag, "quit"), 20000);
  closesocket(s);
  return 0;
}

/* Child: a consumer that connects and verifies the peer. Args: <path> <handle-file|->. */
static int role_consumer(int argc, char **argv, const char *tag) {
  if (argc < 8) return 2;
  const char *path = argv[6];
  char q[128];
  SOCKET c = usock();
  int r = uconnect(c, path);
  snprintf(q, sizeof q, "Q2.%s.consumer_connect", tag);
  fact(q, "%s", WSOK(r));
  int e;
  DWORD pp = peerpid(c, &e);
  snprintf(q, sizeof q, "Q2.%s.consumer_peerpid", tag);
  fact(q, "%ld err=%d", (long)pp, e);
  SetEvent(event(tag, "conn"));
  if (strcmp(argv[7], "-") != 0) {
    /* Q5: handles duplicated into this process by the Runtime before it ran. */
    FILE *f = fopen(argv[7], "r");
    char name[32];
    unsigned long long hv;
    while (f && fscanf(f, "%31s %llu", name, &hv) == 2) {
      HANDLE h = (HANDLE)(ULONG_PTR)hv;
      DWORD id = GetProcessId(h);
      DWORD w = WaitForSingleObject(h, 0);
      HANDLE tok = NULL;
      BOOL tk = OpenProcessToken(h, TOKEN_QUERY, &tok);
      DWORD tke = tk ? 0 : GetLastError();
      char sid[256] = "";
      if (tk) {
        sid_of_token(tok, sid, sizeof sid);
        CloseHandle(tok);
      }
      HANDLE wide = NULL;
      BOOL wd = DuplicateHandle(GetCurrentProcess(), h, GetCurrentProcess(), &wide,
                                PROCESS_VM_READ, FALSE, 0);
      DWORD wde = wd ? 0 : GetLastError();
      if (wd) CloseHandle(wide);
      snprintf(q, sizeof q, "Q5.%s.ref_%s", tag, name);
      fact(q, "pid=%lu matches_peer=%d alive=%d token=%s same_user=%d widen_vm_read=%s", (unsigned long)id,
           id == pp, w == WAIT_TIMEOUT, okerr(tk, tke), strcmp(sid, g_usersid) == 0,
           okerr(wd, wde));
    }
    if (f) fclose(f);
    /* What a same-user process can open from the pid alone (G58 context). */
    HANDLE any = OpenProcess(PROCESS_ALL_ACCESS, FALSE, pp);
    snprintf(q, sizeof q, "Q5.%s.open_peer_all_access_from_pid", tag);
    fact(q, "%s", any ? "ok" : okerr(FALSE, GetLastError()));
    if (any) CloseHandle(any);
  }
  char b;
  int rd = readable(c, 15000);
  int n = rd != 0 ? recv(c, &b, 1, 0) : -1;
  snprintf(q, sizeof q, "Q2.%s.consumer_served", tag);
  fact(q, "%s", n == 1 ? "ok" : "no");
  pp = peerpid(c, &e);
  snprintf(q, sizeof q, "Q2.%s.consumer_peerpid_after_accept", tag);
  fact(q, "%ld err=%d", (long)pp, e);
  closesocket(c);
  return 0;
}

/* Child: a third process handed the target's WSAPROTOCOL_INFOW. Args: <info-file>. */
static int role_third(int argc, char **argv, const char *tag) {
  if (argc < 7) return 2;
  WSAPROTOCOL_INFOW pi;
  FILE *f = fopen(argv[6], "rb");
  size_t got = f ? fread(&pi, 1, sizeof pi, f) : 0;
  if (f) fclose(f);
  char q[96];
  snprintf(q, sizeof q, "Q4.%s.info_used_by_third_process", tag);
  if (got != sizeof pi) {
    fact(q, "unreadable");
    return 3;
  }
  SOCKET s = WSASocketW(FROM_PROTOCOL_INFO, FROM_PROTOCOL_INFO, FROM_PROTOCOL_INFO, &pi, 0,
                        WSA_FLAG_OVERLAPPED);
  const char *rs = s == INVALID_SOCKET ? WSOK(-1) : "returned";
  int t = -1, tl = sizeof t, ac = -1, al = sizeof ac;
  int r = s == INVALID_SOCKET ? -1 : getsockopt(s, SOL_SOCKET, SO_TYPE, (char *)&t, &tl);
  if (r == 0) getsockopt(s, SOL_SOCKET, SO_ACCEPTCONN, (char *)&ac, &al);
  fact(q, "%s value=%llu usable=%d acceptconn=%d", rs, (unsigned long long)s, r == 0, ac);
  /* Not closed: the value may name an unrelated handle of this process. */
  return 0;
}

/* Child: a Runtime that creates the listener, hands it to a host, closes its
 * copy and exits (Q2 V4). Args: <path>. */
static int role_creator(int argc, char **argv, const char *tag) {
  if (argc < 7) return 2;
  int e;
  SOCKET l = ulisten(argv[6], 8, &e);
  char q[96];
  snprintf(q, sizeof q, "Q2.%s.creator_pid", tag);
  fact(q, "%lu listen=%s", (unsigned long)GetCurrentProcessId(),
       l == INVALID_SOCKET ? okerr(FALSE, e) : "ok");
  if (l == INVALID_SOCKET) return 3;
  SetHandleInformation((HANDLE)l, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
  child_t h;
  char args[128], htag[64];
  snprintf(htag, sizeof htag, "%s", tag);
  snprintf(args, sizeof args, "inherit %llu 1", (unsigned long long)l);
  HANDLE ex[1] = {(HANDLE)l};
  /* The host must outlive us: its facts go to its own file, read by the top. */
  if (!spawn(&h, "host", htag, args, ex, 1, FALSE, 0, NULL, NULL)) {
    fact(q, "spawn-host-err=%lu", (unsigned long)GetLastError());
    return 3;
  }
  WaitForSingleObject(event(tag, "ready"), 20000);
  closesocket(l);
  FILE *f;
  char fp[MAX_PATH];
  snprintf(fp, sizeof fp, "%s\\host-%s.txt", g_base, tag);
  f = fopen(fp, "w");
  if (f) {
    fprintf(f, "%lu %s\n", (unsigned long)h.pid, h.outpath);
    fclose(f);
  }
  CloseHandle(h.outh);
  CloseHandle(h.thread);
  CloseHandle(h.proc);
  return 0;
}

static void write_handles(const char *file, const char **names, HANDLE *hs, int n) {
  FILE *f = fopen(file, "w");
  for (int i = 0; f && i < n; i++)
    fprintf(f, "%s %llu\n", names[i], (unsigned long long)(ULONG_PTR)hs[i]);
  if (f) fclose(f);
}

/* One attribution case: the Runtime (this process) creates and listens, a host
 * accepts, a consumer connects. mode: inherit or dup. closeFirst: the Runtime
 * closes its listener before the consumer connects. connectFirst: the consumer
 * connects before the host is told to accept. */
static void attribution_case(const char *tag, const char *mode, BOOL closeFirst,
                             BOOL connectFirst) {
  char q[96], p[MAX_PATH], args[512];
  int e;
  snprintf(p, sizeof p, "%s\\%s.sock", g_base, tag);
  SOCKET l = ulisten(p, 8, &e);
  if (l == INVALID_SOCKET) {
    snprintf(q, sizeof q, "Q2.%s.listen", tag);
    fact(q, "%s", okerr(FALSE, e));
    return;
  }
  HANDLE evReady = event(tag, "ready"), evGo = event(tag, "go"), evQuit = event(tag, "quit"),
         evConn = event(tag, "conn"), evInfo = event(tag, "info");
  child_t host, cons;
  char infofile[MAX_PATH];
  snprintf(infofile, sizeof infofile, "%s\\%s.info", g_base, tag);
  BOOL ok;
  if (strcmp(mode, "inherit") == 0) {
    SetHandleInformation((HANDLE)l, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
    snprintf(args, sizeof args, "inherit %llu 1", (unsigned long long)l);
    HANDLE ex[1] = {(HANDLE)l};
    ok = spawn(&host, "host", tag, args, ex, 1, FALSE, 0, NULL, NULL);
    SetHandleInformation((HANDLE)l, HANDLE_FLAG_INHERIT, 0);
  } else {
    snprintf(args, sizeof args, "dup %s 1", infofile);
    ok = spawn(&host, "host", tag, args, NULL, 0, FALSE, 0, NULL, NULL);
    if (ok) {
      WSAPROTOCOL_INFOW pi;
      int r = WSADuplicateSocketW(l, host.pid, &pi);
      snprintf(q, sizeof q, "Q3.%s.wsaduplicatesocket", tag);
      fact(q, "%s", WSOK(r));
      FILE *f = fopen(infofile, "wb");
      if (f) {
        fwrite(&pi, 1, sizeof pi, f);
        fclose(f);
      }
      SetEvent(evInfo);
    }
  }
  snprintf(q, sizeof q, "Q2.%s.spawn_host", tag);
  if (!ok) {
    fact(q, "%s", okerr(FALSE, GetLastError()));
    closesocket(l);
    return;
  }
  fact(q, "ok runtime_pid=%lu host_pid=%lu", (unsigned long)GetCurrentProcessId(),
       (unsigned long)host.pid);
  WaitForSingleObject(evReady, 20000);
  if (strcmp(mode, "dup") == 0) {
    child_t third;
    snprintf(args, sizeof args, "%s", infofile);
    if (spawn(&third, "third", "third", args, NULL, 0, FALSE, 0, NULL, NULL))
      finish(&third, 15000, "Q4");
  }
  if (closeFirst) closesocket(l);
  if (!connectFirst) {
    SetEvent(evGo);
    Sleep(300);
  }
  /* Q5: the consumer gets minimal-rights handles to both candidates before it runs. */
  char hfile[MAX_PATH];
  snprintf(hfile, sizeof hfile, "%s\\%s.handles", g_base, tag);
  snprintf(args, sizeof args, "%s %s", p, hfile);
  ok = spawn(&cons, "consumer", tag, args, NULL, 0, FALSE, CREATE_SUSPENDED, NULL, NULL);
  if (ok) {
    HANDLE hs[2] = {NULL, NULL};
    DWORD rights = PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE;
    DuplicateHandle(GetCurrentProcess(), GetCurrentProcess(), cons.proc, &hs[0], rights, FALSE, 0);
    DuplicateHandle(GetCurrentProcess(), host.proc, cons.proc, &hs[1], rights, FALSE, 0);
    const char *names[2] = {"runtime", "host"};
    write_handles(hfile, names, hs, 2);
    ResumeThread(cons.thread);
    if (connectFirst) {
      WaitForSingleObject(evConn, 15000);
      Sleep(200);
      SetEvent(evGo);
    }
    finish(&cons, 30000, "Q2");
  } else {
    snprintf(q, sizeof q, "Q2.%s.spawn_consumer", tag);
    fact(q, "%s", okerr(FALSE, GetLastError()));
    SetEvent(evGo);
  }
  SetEvent(evQuit);
  finish(&host, 30000, "Q2");
  if (!closeFirst) closesocket(l);
  DeleteFileA(p);
  DeleteFileA(hfile);
  DeleteFileA(infofile);
  CloseHandle(evReady);
  CloseHandle(evGo);
  CloseHandle(evQuit);
  CloseHandle(evConn);
  CloseHandle(evInfo);
}

/* Q2 V4: the creator exits before the consumer connects. */
static void attribution_creator_exits(void) {
  const char *tag = "v4";
  char p[MAX_PATH], args[512], q[96];
  snprintf(p, sizeof p, "%s\\%s.sock", g_base, tag);
  child_t cr;
  snprintf(args, sizeof args, "%s", p);
  HANDLE evGo = event(tag, "go"), evQuit = event(tag, "quit");
  if (!spawn(&cr, "creator", tag, args, NULL, 0, FALSE, 0, NULL, NULL)) {
    fact("Q2.v4.spawn_creator", "%s", okerr(FALSE, GetLastError()));
    return;
  }
  DWORD crpid = cr.pid;
  HANDLE crh = NULL; /* held so the creator's pid is not reused */
  DuplicateHandle(GetCurrentProcess(), cr.proc, GetCurrentProcess(), &crh, SYNCHRONIZE, FALSE, 0);
  finish(&cr, 30000, "Q2");
  char fp[MAX_PATH], hostout[MAX_PATH] = "";
  unsigned long hostpid = 0;
  snprintf(fp, sizeof fp, "%s\\host-%s.txt", g_base, tag);
  FILE *f = fopen(fp, "r");
  if (f) {
    if (fscanf(f, "%lu %259s", &hostpid, hostout) != 2) hostpid = 0;
    fclose(f);
  }
  DeleteFileA(fp);
  fact("Q2.v4.creator_exited", "creator_pid=%lu alive=%d host_pid=%lu", (unsigned long)crpid,
       WaitForSingleObject(crh, 0) == WAIT_TIMEOUT, hostpid);
  SetEvent(evGo);
  Sleep(300);
  child_t cons;
  snprintf(args, sizeof args, "%s -", p);
  if (spawn(&cons, "consumer", tag, args, NULL, 0, FALSE, 0, NULL, NULL))
    finish(&cons, 30000, "Q2");
  SetEvent(evQuit);
  HANDLE hh = hostpid ? OpenProcess(SYNCHRONIZE, FALSE, hostpid) : NULL;
  if (hh) {
    WaitForSingleObject(hh, 20000);
    CloseHandle(hh);
  }
  /* The host's facts are in its own file. */
  f = hostout[0] ? fopen(hostout, "rb") : NULL;
  if (f) {
    char line[4096];
    while (fgets(line, sizeof line, f)) fputs(line, stdout);
    fclose(f);
    DeleteFileA(hostout);
  }
  (void)q;
  CloseHandle(crh);
  CloseHandle(evGo);
  CloseHandle(evQuit);
  DeleteFileA(p);
}

/* ====================================================================== Q4 */

static int role_hyg(int argc, char **argv, const char *tag) {
  if (argc < 8) return 2;
  HANDLE ev = (HANDLE)(ULONG_PTR)_strtoui64(argv[6], NULL, 10);
  SOCKET s = (SOCKET)_strtoui64(argv[7], NULL, 10);
  DWORD fl = 0;
  BOOL hv = GetHandleInformation(ev, &fl);
  DWORD w = hv ? WaitForSingleObject(ev, 0) : WAIT_FAILED;
  char q[96];
  snprintf(q, sizeof q, "Q4.%s.unlisted_event_in_child", tag);
  fact(q, "%s", hv && w == WAIT_OBJECT_0 ? "present (inherited)" : "absent");
  int t = -1, tl = sizeof t;
  int r = getsockopt(s, SOL_SOCKET, SO_TYPE, (char *)&t, &tl);
  snprintf(q, sizeof q, "Q4.%s.listed_socket_in_child", tag);
  fact(q, "%s", r == 0 ? "present" : "absent");
  DWORD cnt = 0;
  GetProcessHandleCount(GetCurrentProcess(), &cnt);
  snprintf(q, sizeof q, "Q4.%s.child_handle_count", tag);
  fact(q, "%lu", (unsigned long)cnt);
  return 0;
}

static void q4_hygiene(void) {
  char p[MAX_PATH], args[256];
  int e;
  snprintf(p, sizeof p, "%s\\hyg.sock", g_base);
  SOCKET l = ulisten(p, 4, &e);
  if (l == INVALID_SOCKET) return;
  SECURITY_ATTRIBUTES sa = {sizeof sa, NULL, TRUE};
  HANDLE ev = CreateEventA(&sa, TRUE, TRUE, NULL); /* inheritable, signalled, unlisted */
  SetHandleInformation((HANDLE)l, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
  snprintf(args, sizeof args, "%llu %llu", (unsigned long long)(ULONG_PTR)ev,
           (unsigned long long)l);
  HANDLE ex[1] = {(HANDLE)l};
  child_t c;
  if (spawn(&c, "hyg", "list", args, ex, 1, FALSE, 0, NULL, NULL)) finish(&c, 15000, "Q4");
  if (spawn(&c, "hyg", "inheritall", args, NULL, 0, TRUE, 0, NULL, NULL))
    finish(&c, 15000, "Q4");
  CloseHandle(ev);
  closesocket(l);
  DeleteFileA(p);
}

/* ============================================================ Q5 liveness */

static void q5_liveness(void) {
  child_t c;
  if (!spawn(&c, "sleep", "sleep", "200", NULL, 0, FALSE, 0, NULL, NULL)) return;
  HANDLE h = NULL;
  DuplicateHandle(GetCurrentProcess(), c.proc, GetCurrentProcess(), &h,
                  PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, 0);
  DWORD pid = c.pid;
  fact("Q5.min_rights_alive", "%d", WaitForSingleObject(h, 0) == WAIT_TIMEOUT);
  finish(&c, 10000, "Q5");
  HANDLE tok = NULL;
  BOOL tk = OpenProcessToken(h, TOKEN_QUERY, &tok);
  DWORD tke = tk ? 0 : GetLastError();
  if (tk) CloseHandle(tok);
  fact("Q5.after_exit", "signalled=%d pid_kept=%d token=%s",
       WaitForSingleObject(h, 0) == WAIT_OBJECT_0, GetProcessId(h) == pid, okerr(tk, tke));
  CloseHandle(h);
}

/* ================================================================ Q6-Q8 */

static int role_acl(int argc, char **argv, const char *tag) {
  if (argc < 8) return 2;
  const char *dir = argv[6], *sock = argv[7];
  char q[128], tmp[MAX_PATH];
  HANDLE tok;
  if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &tok))
    CloseHandle(tok);
  else {
    snprintf(q, sizeof q, "Q7.%s.open_own_token", tag);
    fact(q, "%s", okerr(FALSE, GetLastError()));
  }
  char me[512];
  token_summary(LP_SELF_TOKEN, me, sizeof me);
  snprintf(q, sizeof q, "Q7.%s.token", tag);
  fact(q, "%s", me);
  SOCKET c = usock();
  snprintf(q, sizeof q, "Q7.%s.connect", tag);
  fact(q, "%s", WSOK(uconnect(c, sock)));
  closesocket(c);
  struct {
    const char *name;
    DWORD access;
  } opens[] = {{"open_sock_write_dac", WRITE_DAC},
               {"open_sock_write_owner", WRITE_OWNER},
               {"open_sock_delete", DELETE},
               {"open_sock_write_attrs", FILE_WRITE_ATTRIBUTES}};
  for (int i = 0; i < 4; i++) {
    HANDLE h = open_nofollow(sock, opens[i].access);
    snprintf(q, sizeof q, "Q7.%s.%s", tag, opens[i].name);
    fact(q, "%s", h == INVALID_HANDLE_VALUE ? okerr(FALSE, GetLastError()) : "ok");
    if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
  }
  struct {
    const char *name;
    DWORD access;
  } dopens[] = {{"open_dir_write_dac", WRITE_DAC}, {"open_dir_delete", DELETE}};
  for (int i = 0; i < 2; i++) {
    HANDLE h = open_nofollow(dir, dopens[i].access);
    snprintf(q, sizeof q, "Q7.%s.%s", tag, dopens[i].name);
    fact(q, "%s", h == INVALID_HANDLE_VALUE ? okerr(FALSE, GetLastError()) : "ok");
    if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
  }
  snprintf(tmp, sizeof tmp, "%s\\planted.txt", dir);
  HANDLE pf = CreateFileA(tmp, GENERIC_WRITE, 0, NULL, CREATE_NEW, 0, NULL);
  snprintf(q, sizeof q, "Q7.%s.plant_file_in_dir", tag);
  fact(q, "%s", pf == INVALID_HANDLE_VALUE ? okerr(FALSE, GetLastError()) : "ok");
  if (pf != INVALID_HANDLE_VALUE) {
    CloseHandle(pf);
    DeleteFileA(tmp);
  }
  snprintf(tmp, sizeof tmp, "%s.mv", sock);
  BOOL mv = MoveFileExA(sock, tmp, 0);
  snprintf(q, sizeof q, "Q7.%s.rename_sock", tag);
  fact(q, "%s", W32(mv));
  if (mv) MoveFileExA(tmp, sock, 0);
  BOOL del = DeleteFileA(sock);
  snprintf(q, sizeof q, "Q7.%s.delete_sock", tag);
  fact(q, "%s", W32(del));
  return 0;
}

/* The single-right masks tried for connect, with OWNER RIGHTS as the only ACE. */
static const struct {
  const char *name;
  DWORD mask;
} k_masks[] = {
    {"all", 0x1F01FF},           {"generic_read", 0x120089}, {"generic_write", 0x120116},
    {"write_data_sync", 0x100002}, {"write_data", 0x000002},   {"read_data_sync", 0x100001},
    {"append_sync", 0x100004},   {"execute_sync", 0x100020}, {"read_attrs_sync", 0x100080},
    {"write_attrs_sync", 0x100100}, {"sync_only", 0x100000},    {"none", 0},
};

static void q6_q8_acl(HANDLE restrictedTok, HANDLE writeRestrictedTok) {
  char d[MAX_PATH], s[MAX_PATH], sd[2048], sddl[1024];
  int e;
  /* Q8: what the scratch dir and a fresh dir give a socket object by inheritance. */
  sddl_of(g_base, sd, sizeof sd);
  fact("Q8.base_dir_sddl", "%s", sd);
  snprintf(d, sizeof d, "%s\\acl", g_base);
  CreateDirectoryA(d, NULL);
  snprintf(s, sizeof s, "%s\\inh.sock", d);
  SOCKET l = ulisten(s, 4, &e);
  sddl_of(s, sd, sizeof sd);
  fact("Q8.socket_sddl_default", "%s", sd);
  if (l != INVALID_SOCKET) closesocket(l);
  DeleteFileA(s);

  /* A protected, non-null DACL on the endpoint directory, inheritable to files. */
  snprintf(sddl, sizeof sddl, "D:P(A;OICI;FA;;;%s)", g_usersid);
  DWORD r = set_dacl(d, sddl);
  fact("Q8.set_protected_dir_dacl", "%s", okerr(r == 0, r));
  sddl_of(d, sd, sizeof sd);
  fact("Q8.dir_sddl_protected", "%s", sd);
  l = ulisten(s, 4, &e);
  sddl_of(s, sd, sizeof sd);
  fact("Q8.socket_sddl_in_protected_dir", "%s", sd);
  if (l != INVALID_SOCKET) {
    snprintf(sddl, sizeof sddl, "D:P(A;;FA;;;%s)", g_usersid);
    r = set_dacl(s, sddl);
    fact("Q8.set_dacl_on_socket_object", "%s", okerr(r == 0, r));
    sddl_of(s, sd, sizeof sd);
    fact("Q8.socket_sddl_after_set", "%s", sd);
    closesocket(l);
  }
  DeleteFileA(s);

  /* Q6: which right connect needs, with OWNER RIGHTS (S-1-3-4) as the only ACE. */
  DWORD connectMask = 0;
  for (size_t i = 0; i < sizeof k_masks / sizeof k_masks[0]; i++) {
    char sp[MAX_PATH], n[96];
    snprintf(sp, sizeof sp, "%s\\m%02u.sock", d, (unsigned)i);
    SOCKET ml = ulisten(sp, 4, &e);
    if (ml == INVALID_SOCKET) continue;
    if (k_masks[i].mask)
      snprintf(sddl, sizeof sddl, "D:P(A;;0x%lx;;;OW)", (unsigned long)k_masks[i].mask);
    else
      snprintf(sddl, sizeof sddl, "D:P");
    r = set_dacl(sp, sddl);
    SOCKET c = usock();
    int cr = uconnect(c, sp);
    int ce = cr ? WSAGetLastError() : 0;
    closesocket(c);
    snprintf(n, sizeof n, "Q6.connect_owner_rights_%s", k_masks[i].name);
    fact(n, "set=%s connect=%s", okerr(r == 0, r), okerr(cr == 0, ce));
    DWORD lo = k_masks[i].mask & 0xFFFF; /* the specific rights, without SYNCHRONIZE */
    if (cr == 0 && !connectMask && lo && !(lo & (lo - 1)))
      connectMask = k_masks[i].mask; /* the first single file right that suffices */
    HANDLE wd = open_nofollow(sp, WRITE_DAC);
    snprintf(n, sizeof n, "Q7.owner_rights_%s_owner_write_dac", k_masks[i].name);
    fact(n, "%s", wd == INVALID_HANDLE_VALUE ? okerr(FALSE, GetLastError()) : "ok");
    if (wd != INVALID_HANDLE_VALUE) CloseHandle(wd);
    closesocket(ml);
    BOOL del = DeleteFileA(sp);
    snprintf(n, sizeof n, "Q6.delete_owner_rights_%s_via_dir", k_masks[i].name);
    fact(n, "%s", W32(del));
  }
  fact("Q6.connect_right", "0x%lx", (unsigned long)connectMask);
  if (!connectMask) connectMask = 0x100002;

  /* The same user without FILE_DELETE_CHILD on the directory. */
  {
    char d2[MAX_PATH], sp[MAX_PATH];
    snprintf(d2, sizeof d2, "%s\\nodc", g_base);
    CreateDirectoryA(d2, NULL);
    snprintf(sp, sizeof sp, "%s\\n.sock", d2);
    SOCKET ml = ulisten(sp, 4, &e);
    snprintf(sddl, sizeof sddl, "D:P(A;;0x%lx;;;OW)", (unsigned long)connectMask);
    set_dacl(sp, sddl);
    snprintf(sddl, sizeof sddl, "D:P(A;;0x1F01BF;;;%s)", g_usersid);
    set_dacl(d2, sddl);
    BOOL del = DeleteFileA(sp);
    fact("Q6.delete_without_dir_delete_child", "%s", W32(del));
    if (ml != INVALID_SOCKET) closesocket(ml);
    snprintf(sddl, sizeof sddl, "D:P(A;OICI;FA;;;%s)", g_usersid);
    set_dacl(d2, sddl);
    DeleteFileA(sp);
    RemoveDirectoryA(d2);
  }

  /* Q7: a consumer of the same user, plain and with restricted tokens. The
   * directory and socket grant the user everything and RESTRICTED (S-1-5-12)
   * only traverse/read and the connect right. */
  struct {
    const char *tag;
    HANDLE tok;
  } kinds[] = {{"plain", NULL}, {"restricted", restrictedTok}, {"write_restricted", writeRestrictedTok}};
  for (int k = 0; k < 3; k++) {
    if (k > 0 && !kinds[k].tok) {
      char n[96];
      snprintf(n, sizeof n, "Q7.%s", kinds[k].tag);
      fact(n, "unmeasured (no token)");
      continue;
    }
    char rd[MAX_PATH], sp[MAX_PATH], args[600];
    snprintf(rd, sizeof rd, "%s\\r%d", g_base, k);
    CreateDirectoryA(rd, NULL);
    snprintf(sddl, sizeof sddl, "D:P(A;OICI;FA;;;%s)(A;;0x1200A9;;;RC)", g_usersid);
    set_dacl(rd, sddl);
    snprintf(sp, sizeof sp, "%s\\e.sock", rd);
    SOCKET ml = ulisten(sp, 4, &e);
    snprintf(sddl, sizeof sddl, "D:P(A;;FA;;;%s)(A;;0x%lx;;;RC)", g_usersid,
             (unsigned long)connectMask);
    r = set_dacl(sp, sddl);
    char n[96];
    snprintf(n, sizeof n, "Q7.%s.endpoint_dacl", kinds[k].tag);
    sddl_of(sp, sd, sizeof sd);
    fact(n, "set=%s %s", okerr(r == 0, r), sd);
    snprintf(args, sizeof args, "%s %s", rd, sp);
    child_t c;
    /* Accept in a thread-free way: a non-blocking listener drained after. */
    if (spawn(&c, "acl", kinds[k].tag, args, NULL, 0, FALSE, 0, kinds[k].tok,
              kinds[k].tok ? "C:\\Windows" : NULL))
      finish(&c, 20000, "Q7");
    else {
      snprintf(n, sizeof n, "Q7.%s.spawn", kinds[k].tag);
      fact(n, "%s", okerr(FALSE, GetLastError()));
    }
    if (ml != INVALID_SOCKET) closesocket(ml);
    snprintf(sddl, sizeof sddl, "D:P(A;;FA;;;%s)", g_usersid);
    set_dacl(sp, sddl);
    DeleteFileA(sp);
    RemoveDirectoryA(rd);
  }
  RemoveDirectoryA(d);
}

/* Restricted tokens for Q7: restricting SIDs Everyone, Users, Authenticated
 * Users, the logon SID and RESTRICTED (so the process can load system DLLs);
 * the write-restricted one restricts writes to RESTRICTED alone. */
static void make_tokens(HANDLE *restricted, HANDLE *writeRestricted) {
  *restricted = *writeRestricted = NULL;
  HANDLE tok;
  if (!OpenProcessToken(GetCurrentProcess(),
                        TOKEN_DUPLICATE | TOKEN_ASSIGN_PRIMARY | TOKEN_QUERY, &tok))
    return;
  BYTE gbuf[8192];
  DWORD len;
  PSID logon = NULL;
  if (GetTokenInformation(tok, TokenGroups, gbuf, sizeof gbuf, &len)) {
    TOKEN_GROUPS *g = (TOKEN_GROUPS *)gbuf;
    for (DWORD i = 0; i < g->GroupCount; i++)
      if (g->Groups[i].Attributes & SE_GROUP_LOGON_ID) logon = g->Groups[i].Sid;
  }
  const char *names[] = {"S-1-1-0", "S-1-5-32-545", "S-1-5-11", "S-1-5-12"};
  SID_AND_ATTRIBUTES ra[5];
  int n = 0;
  for (int i = 0; i < 4; i++) {
    PSID s = NULL;
    if (ConvertStringSidToSidA(names[i], &s)) {
      ra[n].Sid = s;
      ra[n].Attributes = 0;
      n++;
    }
  }
  if (logon) {
    ra[n].Sid = logon;
    ra[n].Attributes = 0;
    n++;
  }
  if (!CreateRestrictedToken(tok, 0, 0, NULL, 0, NULL, (DWORD)n, ra, restricted)) {
    fact("Q7.create_restricted_token", "%s", okerr(FALSE, GetLastError()));
    *restricted = NULL;
  }
  SID_AND_ATTRIBUTES wr[1];
  PSID rc = NULL;
  ConvertStringSidToSidA("S-1-5-12", &rc);
  wr[0].Sid = rc;
  wr[0].Attributes = 0;
  if (!CreateRestrictedToken(tok, WRITE_RESTRICTED, 0, NULL, 0, NULL, 1, wr, writeRestricted)) {
    fact("Q7.create_write_restricted_token", "%s", okerr(FALSE, GetLastError()));
    *writeRestricted = NULL;
  }
  CloseHandle(tok);
}

/* The probe binary must be readable by RESTRICTED for a restricted child to start. */
static void grant_self_to_restricted(void) {
  PACL old = NULL, nw = NULL;
  PSECURITY_DESCRIPTOR sd = NULL;
  if (GetNamedSecurityInfoA(g_self, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION, NULL, NULL, &old,
                            NULL, &sd) != ERROR_SUCCESS)
    return;
  PSID rc = NULL;
  ConvertStringSidToSidA("S-1-5-12", &rc);
  EXPLICIT_ACCESSA ea;
  memset(&ea, 0, sizeof ea);
  ea.grfAccessPermissions = FILE_GENERIC_READ | FILE_GENERIC_EXECUTE;
  ea.grfAccessMode = GRANT_ACCESS;
  ea.Trustee.TrusteeForm = TRUSTEE_IS_SID;
  ea.Trustee.ptstrName = (LPSTR)rc;
  if (SetEntriesInAclA(1, &ea, old, &nw) == ERROR_SUCCESS) {
    DWORD r = SetNamedSecurityInfoA(g_self, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION, NULL, NULL,
                                    nw, NULL);
    fact("Q7.grant_probe_exe_to_restricted", "%s", okerr(r == 0, r));
    LocalFree(nw);
  }
  LocalFree(rc);
  LocalFree(sd);
}

/* ====================================================================== Q9 */

/* Sets the owner of the object at path itself to the SID given as a string. */
static DWORD set_owner(const char *path, const char *sidstr) {
  PSID sid = NULL;
  if (!ConvertStringSidToSidA(sidstr, &sid)) return GetLastError();
  HANDLE h = open_nofollow(path, WRITE_OWNER | READ_CONTROL);
  if (h == INVALID_HANDLE_VALUE) {
    DWORD e = GetLastError();
    LocalFree(sid);
    return e;
  }
  DWORD r = SetSecurityInfo(h, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION, sid, NULL, NULL,
                            NULL);
  CloseHandle(h);
  LocalFree(sid);
  return r;
}

/* G332 (Fable's review of the spike): whether the Runtime can name its own user as the owner
 * of the endpoint directory and socket object under every token, and the volume facts a
 * placement must check (persistent ACLs, reparse points, a local fixed drive). */
static void q8_owner_volume(void) {
  char d[MAX_PATH], s[MAX_PATH], sd[2048];
  int e;
  snprintf(d, sizeof d, "%s\\own", g_base);
  CreateDirectoryA(d, NULL);
  sddl_of(d, sd, sizeof sd);
  fact("Q8.owner.dir_default", "%s", sd);
  DWORD r = set_owner(d, g_usersid);
  sddl_of(d, sd, sizeof sd);
  fact("Q8.owner.set_dir_owner_user", "%s %s", okerr(r == 0, r), sd);
  snprintf(s, sizeof s, "%s\\o.sock", d);
  SOCKET l = ulisten(s, 4, &e);
  sddl_of(s, sd, sizeof sd);
  fact("Q8.owner.socket_in_owned_dir", "%s", sd);
  if (l != INVALID_SOCKET) {
    r = set_owner(s, g_usersid);
    sddl_of(s, sd, sizeof sd);
    fact("Q8.owner.set_socket_owner_user", "%s %s", okerr(r == 0, r), sd);
    /* Another principal as owner: refused unless the token may restore (SeRestore). */
    r = set_owner(s, "S-1-5-18");
    fact("Q8.owner.set_socket_owner_system", "%s", okerr(r == 0, r));
    closesocket(l);
  }
  DeleteFileA(s);
  RemoveDirectoryA(d);

  HANDLE h = open_nofollow(g_base, FILE_READ_ATTRIBUTES);
  if (h == INVALID_HANDLE_VALUE) {
    fact("Q8.volume", "open-err=%lu", (unsigned long)GetLastError());
    return;
  }
  WCHAR fs[MAX_PATH + 1];
  DWORD serial = 0, maxlen = 0, flags = 0;
  BOOL ok = GetVolumeInformationByHandleW(h, NULL, 0, &serial, &maxlen, &flags, fs, MAX_PATH + 1);
  if (ok)
    fact("Q8.volume.flags", "fs=%ls persistent_acls=%d reparse_points=%d flags=0x%08lx", fs,
         (flags & FILE_PERSISTENT_ACLS) != 0, (flags & FILE_SUPPORTS_REPARSE_POINTS) != 0,
         (unsigned long)flags);
  else
    fact("Q8.volume.flags", "err=%lu", (unsigned long)GetLastError());
  /* Succeeds only for a file on a network redirector (SMB and the like). */
  FILE_REMOTE_PROTOCOL_INFO rp;
  memset(&rp, 0, sizeof rp);
  ok = GetFileInformationByHandleEx(h, FileRemoteProtocolInfo, &rp, sizeof rp);
  DWORD rpe = ok ? 0 : GetLastError();
  CloseHandle(h);
  if (ok)
    fact("Q8.volume.remote_protocol", "remote protocol=0x%08lx", (unsigned long)rp.Protocol);
  else
    fact("Q8.volume.remote_protocol", "local err=%lu", (unsigned long)rpe);
  char root[MAX_PATH];
  if (GetVolumePathNameA(g_base, root, sizeof root))
    fact("Q8.volume.drive_type", "%u", (unsigned)GetDriveTypeA(root));
  else
    fact("Q8.volume.drive_type", "err=%lu", (unsigned long)GetLastError());
}

static void q9_reparse(void) {
  char p[MAX_PATH], t[MAX_PATH], j[MAX_PATH], q[96];
  int e;
  snprintf(p, sizeof p, "%s\\rp.sock", g_base);
  SOCKET l = ulisten(p, 4, &e);
  if (l == INVALID_SOCKET) return;
  objinfo o = info_of(p);
  FILE_ID_INFO id = o.id;
  fact("Q9.real_socket", "%s", validate(p, &id, g_base));

  /* connect follows an ancestor junction; bind does too */
  snprintf(t, sizeof t, "%s\\real", g_base);
  snprintf(j, sizeof j, "%s\\jdir", g_base);
  CreateDirectoryA(t, NULL);
  DWORD jr = mkjunction(j, t);
  fact("Q9.make_junction", "%s", okerr(jr == 0, jr));
  if (!jr) {
    char via[MAX_PATH], real[MAX_PATH];
    snprintf(via, sizeof via, "%s\\a.sock", j);
    snprintf(real, sizeof real, "%s\\a.sock", t);
    SOCKET jl = ulisten(via, 4, &e);
    fact("Q9.bind_through_ancestor_junction", "%s lands_in_target=%d",
         jl == INVALID_SOCKET ? okerr(FALSE, e) : "ok",
         GetFileAttributesA(real) != INVALID_FILE_ATTRIBUTES);
    if (jl != INVALID_SOCKET) {
      objinfo jo = info_of(real);
      fact("Q9.ancestor_junction_path", "%s", validate(via, &jo.id, g_base));
      SOCKET c = usock();
      fact("Q9.connect_through_ancestor_junction", "%s", WSOK(uconnect(c, via)));
      closesocket(c);
      closesocket(jl);
    }
    DeleteFileA(real);
    /* a junction at the leaf */
    char leaf[MAX_PATH];
    snprintf(leaf, sizeof leaf, "%s\\leafj.sock", g_base);
    DWORD lr = mkjunction(leaf, t);
    if (!lr) {
      fact("Q9.leaf_junction", "%s", validate(leaf, &id, g_base));
      SOCKET b = usock();
      fact("Q9.bind_on_leaf_junction", "%s", WSOK(ubind(b, leaf)));
      closesocket(b);
      RemoveDirectoryA(leaf);
    }
    RemoveDirectoryA(j);
  }

  /* symbolic links (need the privilege or Developer Mode) */
  {
    char sl[MAX_PATH], dangling[MAX_PATH], dtarget[MAX_PATH];
    snprintf(sl, sizeof sl, "%s\\sl.sock", g_base);
    BOOL ok = CreateSymbolicLinkA(sl, p, SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE);
    if (!ok) {
      fact("Q9.symlink", "unmeasured create=%s", okerr(FALSE, GetLastError()));
    } else {
      fact("Q9.leaf_symlink", "%s", validate(sl, &id, g_base));
      SOCKET c = usock();
      fact("Q9.connect_through_leaf_symlink", "%s", WSOK(uconnect(c, sl)));
      closesocket(c);
      DeleteFileA(sl);
      snprintf(dangling, sizeof dangling, "%s\\dl.sock", g_base);
      snprintf(dtarget, sizeof dtarget, "%s\\dtarget.sock", t);
      if (CreateSymbolicLinkA(dangling, dtarget, SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE)) {
        SOCKET b = usock();
        int br = ubind(b, dangling);
        const char *brs = WSOK(br);
        fact("Q9.bind_on_dangling_symlink", "%s target_created=%d", brs,
             GetFileAttributesA(dtarget) != INVALID_FILE_ATTRIBUTES);
        closesocket(b);
        DeleteFileA(dangling);
        DeleteFileA(dtarget);
      }
    }
  }
  RemoveDirectoryA(t);

  /* a file, a directory, another socket at the recorded path */
  closesocket(l);
  DeleteFileA(p);
  HANDLE f = CreateFileA(p, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
  CloseHandle(f);
  fact("Q9.regular_file", "%s", validate(p, &id, g_base));
  DeleteFileA(p);
  CreateDirectoryA(p, NULL);
  fact("Q9.directory", "%s", validate(p, &id, g_base));
  RemoveDirectoryA(p);
  l = ulisten(p, 4, &e);
  fact("Q9.other_socket_same_path", "%s", validate(p, &id, g_base));
  if (l != INVALID_SOCKET) closesocket(l);
  DeleteFileA(p);
  fact("Q9.missing", "%s", validate(p, &id, g_base));
  (void)q;
}

/* ===================================================================== Q10 */

static void q10_ancestors(const char *leaf) {
  char p[MAX_PATH];
  snprintf(p, sizeof p, "%s", leaf);
  /* collect ancestors, root first */
  char paths[32][MAX_PATH];
  int n = 0;
  for (;;) {
    snprintf(paths[n++], MAX_PATH, "%s", p);
    char *s = strrchr(p, '\\');
    if (!s || n >= 32) break;
    if (s == p + 2) { /* "C:\" */
      s[1] = 0;
      snprintf(paths[n++], MAX_PATH, "%s", p);
      break;
    }
    *s = 0;
  }
  const char *who[] = {"S-1-1-0", "S-1-5-32-545", "S-1-5-11", "S-1-5-4", "S-1-3-0", "S-1-5-12"};
  const char *wn[] = {"Everyone", "Users", "AuthenticatedUsers", "Interactive", "CreatorOwner",
                      "Restricted"};
  for (int i = n - 1, k = 0; i >= 0; i--, k++) {
    char name[64], sd[2048], risky[512] = "";
    objinfo o = info_of(paths[i]);
    sddl_of(paths[i], sd, sizeof sd);
    PACL dacl = NULL;
    PSECURITY_DESCRIPTOR psd = NULL;
    HANDLE h = open_nofollow(paths[i], READ_CONTROL);
    if (h != INVALID_HANDLE_VALUE) {
      GetSecurityInfo(h, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION, NULL, NULL, &dacl, NULL,
                      &psd);
      CloseHandle(h);
    }
    for (int w = 0; dacl && w < 6; w++) {
      PSID sid = NULL;
      ConvertStringSidToSidA(who[w], &sid);
      TRUSTEE_A tr;
      BuildTrusteeWithSidA(&tr, sid);
      ACCESS_MASK m = 0;
      if (GetEffectiveRightsFromAclA(dacl, &tr, &m) == ERROR_SUCCESS) {
        ACCESS_MASK bad = m & (DELETE | WRITE_DAC | WRITE_OWNER | FILE_DELETE_CHILD |
                               FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY);
        if (bad) {
          char one[64];
          snprintf(one, sizeof one, "%s%s:0x%lx", risky[0] ? "," : "", wn[w], (unsigned long)bad);
          strncat(risky, one, sizeof risky - strlen(risky) - 1);
        }
      }
      LocalFree(sid);
    }
    if (psd) LocalFree(psd);
    snprintf(name, sizeof name, "Q10.ancestor%02d", k);
    fact(name, "path=%s reparse=%d tag=0x%08lx risky=%s", paths[i],
         (o.attrs & FILE_ATTRIBUTE_REPARSE_POINT) != 0, (unsigned long)o.tag,
         risky[0] ? risky : "none");
    snprintf(name, sizeof name, "Q10.ancestor%02d_sddl", k);
    fact(name, "%s", sd);
  }
}

/* ===================================================================== Q12 */

static int role_pair(int argc, char **argv, const char *tag) {
  if (argc < 7) return 2;
  SOCKET s = (SOCKET)_strtoui64(argv[6], NULL, 10);
  int e;
  DWORD pp = peerpid(s, &e);
  char b[8] = "";
  int n = readable(s, 10000) == 1 ? recv(s, b, 4, 0) : -1;
  int w = send(s, "pong", 4, 0);
  char q[96];
  snprintf(q, sizeof q, "Q12.%s.child_end", tag);
  fact(q, "peerpid=%ld recv=%d send=%d", (long)pp, n, w);
  return 0;
}

static void q12_pair(void) {
  char p[MAX_PATH];
  int e;
  snprintf(p, sizeof p, "%s\\pair.sock", g_base);
  SOCKET l = ulisten(p, 1, &e);
  if (l == INVALID_SOCKET) return;
  SOCKET c = usock();
  uconnect(c, p);
  SOCKET a = accept(l, NULL, NULL);
  closesocket(l);
  BOOL del = DeleteFileA(p);
  const char *dels = W32(del);
  DWORD pc = peerpid(c, &e), pa = peerpid(a, &e);
  fact("Q12.pair", "accept=%s unlinked=%s both_ends_self=%d", a == INVALID_SOCKET ? "err" : "ok",
       dels, pc == GetCurrentProcessId() && pa == GetCurrentProcessId());
  if (a == INVALID_SOCKET) return;
  SetHandleInformation((HANDLE)a, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
  char args[64];
  snprintf(args, sizeof args, "%llu", (unsigned long long)a);
  HANDLE ex[1] = {(HANDLE)a};
  child_t ch;
  if (spawn(&ch, "pair", "pair", args, ex, 1, FALSE, 0, NULL, NULL)) {
    closesocket(a); /* the child holds the only copy now */
    send(c, "ping", 4, 0);
    char b[8] = "";
    int n = readable(c, 10000) == 1 ? recv(c, b, 4, 0) : -1;
    fact("Q12.parent_end", "recv=%d data=%.4s peerpid_after_handoff=%ld", n, b,
         (long)peerpid(c, &e));
    finish(&ch, 15000, "Q12");
  }
  closesocket(c);
}

/* ===================================================================== Q13 */

static int role_jobchild(int argc, char **argv, const char *tag) {
  (void)argc;
  (void)argv;
  child_t g;
  char q[96];
  BOOL ok = spawn(&g, "sleep", "grand", "60000", NULL, 0, FALSE, 0, NULL, NULL);
  snprintf(q, sizeof q, "Q13.%s.grandchild", tag);
  fact(q, "%s pid=%lu", ok ? "ok" : okerr(FALSE, GetLastError()), (unsigned long)(ok ? g.pid : 0));
  child_t b;
  BOOL br = spawn(&b, "sleep", "breakaway", "100", NULL, 0, FALSE, CREATE_BREAKAWAY_FROM_JOB, NULL,
                  NULL);
  snprintf(q, sizeof q, "Q13.%s.breakaway_spawn", tag);
  fact(q, "%s", br ? "ok (escaped)" : okerr(FALSE, GetLastError()));
  if (br) finish(&b, 5000, "Q13");
  if (ok) {
    char fp[MAX_PATH];
    snprintf(fp, sizeof fp, "%s\\grand.pid", g_base);
    FILE *f = fopen(fp, "w");
    if (f) {
      fprintf(f, "%lu\n", (unsigned long)g.pid);
      fclose(f);
    }
  }
  SetEvent(event(tag, "spawned"));
  Sleep(60000);
  return 0;
}

static void q13_job(void) {
  HANDLE job = CreateJobObjectA(NULL, NULL);
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION li;
  memset(&li, 0, sizeof li);
  li.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  BOOL sl = SetInformationJobObject(job, JobObjectExtendedLimitInformation, &li, sizeof li);
  fact("Q13.create_job", "%s limits=%s", job ? "ok" : "err", W32(sl));
  for (int round = 0; round < 2; round++) {
    const char *tag = round == 0 ? "terminate" : "close";
    HANDLE j = round == 0 ? job : CreateJobObjectA(NULL, NULL);
    if (round == 1) SetInformationJobObject(j, JobObjectExtendedLimitInformation, &li, sizeof li);
    child_t c;
    HANDLE evs = event(tag, "spawned");
    if (!spawn(&c, "jobchild", tag, "", NULL, 0, FALSE, CREATE_SUSPENDED, NULL, NULL)) continue;
    BOOL as = AssignProcessToJobObject(j, c.proc);
    char n[96];
    snprintf(n, sizeof n, "Q13.%s.assign_nested", tag);
    fact(n, "%s", W32(as));
    ResumeThread(c.thread);
    WaitForSingleObject(evs, 15000);
    char fp[MAX_PATH];
    snprintf(fp, sizeof fp, "%s\\grand.pid", g_base);
    unsigned long gp = 0;
    FILE *f = fopen(fp, "r");
    if (f) {
      if (fscanf(f, "%lu", &gp) != 1) gp = 0;
      fclose(f);
    }
    DeleteFileA(fp);
    HANDLE gh = gp ? OpenProcess(SYNCHRONIZE, FALSE, gp) : NULL;
    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION ai;
    QueryInformationJobObject(j, JobObjectBasicAccountingInformation, &ai, sizeof ai, NULL);
    snprintf(n, sizeof n, "Q13.%s.active_before", tag);
    fact(n, "%lu", (unsigned long)ai.ActiveProcesses);
    DWORD t0 = GetTickCount();
    if (round == 0)
      TerminateJobObject(j, 77);
    else
      CloseHandle(j);
    DWORD wc = WaitForSingleObject(c.proc, 10000);
    DWORD wg = gh ? WaitForSingleObject(gh, 10000) : WAIT_FAILED;
    DWORD active = 99;
    if (round == 0) {
      for (int i = 0; i < 100; i++) {
        QueryInformationJobObject(j, JobObjectBasicAccountingInformation, &ai, sizeof ai, NULL);
        active = ai.ActiveProcesses;
        if (!active) break;
        Sleep(10);
      }
    }
    snprintf(n, sizeof n, "Q13.%s.after", tag);
    fact(n, "child_gone=%d grandchild_gone=%d active=%ld ms=%lu", wc == WAIT_OBJECT_0,
         wg == WAIT_OBJECT_0, round == 0 ? (long)active : -1L,
         (unsigned long)(GetTickCount() - t0));
    if (gh) CloseHandle(gh);
    finish(&c, 1000, "Q13");
    CloseHandle(evs);
  }
  CloseHandle(job);
}

/* Deletes what children left in the scratch directory (not recursive). */
static void cleanup_base(void) {
  char pat[MAX_PATH], f[MAX_PATH];
  snprintf(pat, sizeof pat, "%s\\*", g_base);
  WIN32_FIND_DATAA fd;
  HANDLE h = FindFirstFileA(pat, &fd);
  if (h == INVALID_HANDLE_VALUE) return;
  do {
    if (!strcmp(fd.cFileName, ".") || !strcmp(fd.cFileName, "..")) continue;
    snprintf(f, sizeof f, "%s\\%s", g_base, fd.cFileName);
    if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
      RemoveDirectoryA(f);
    else
      DeleteFileA(f);
  } while (FindNextFileA(h, &fd));
  FindClose(h);
}

/* ==================================================================== main */

/* ------------------------------------------ Q1 paths: encodings and aliases */

static void q1_paths(void) {
  char q[128];
  int e;
  fact("Q1.paths.acp", "%u", GetACP());
  WCHAR wbase[MAX_PATH];
  MultiByteToWideChar(CP_ACP, 0, g_base, -1, wbase, MAX_PATH);
  static const WCHAR *names[] = {L"n-\u00e9", L"n-\u6f22"};
  static const char *labels[] = {"latin1", "cjk"};
  for (int i = 0; i < 2; i++) {
    WCHAR wdir[MAX_PATH], wsock[MAX_PATH];
    _snwprintf(wdir, MAX_PATH, L"%ls\\%ls", wbase, names[i]);
    CreateDirectoryW(wdir, NULL);
    _snwprintf(wsock, MAX_PATH, L"%ls\\u.s", wdir);
    char u8[400], acp[400];
    int nu = WideCharToMultiByte(CP_UTF8, 0, wsock, -1, u8, sizeof u8, NULL, NULL);
    BOOL lossy = FALSE;
    WideCharToMultiByte(CP_ACP, WC_NO_BEST_FIT_CHARS, wsock, -1, acp, sizeof acp, NULL, &lossy);
    const char *bytes[] = {u8, acp};
    const char *enc[] = {"utf8", "acp"};
    for (int k = 0; k < 2; k++) {
      snprintf(q, sizeof q, "Q1.paths.%s_%s", labels[i], enc[k]);
      if (k == 1 && lossy) {
        fact(q, "unrepresentable in code page %u", GetACP());
        continue;
      }
      SOCKET s = usock();
      int r = ubind(s, bytes[k]);
      int we = r ? WSAGetLastError() : 0;
      BOOL at = GetFileAttributesW(wsock) != INVALID_FILE_ATTRIBUTES;
      fact(q, "bind=%s file_at_wide_name=%d path_bytes=%d", okerr(r == 0, we), at,
           (int)strlen(bytes[k]));
      closesocket(s);
      DeleteFileW(wsock);
    }
    (void)nu;
    RemoveDirectoryW(wdir);
  }
  /* Case, 8.3 and final-path aliases of one listener. */
  char dir[MAX_PATH], sock[MAX_PATH], alias[MAX_PATH];
  snprintf(dir, sizeof dir, "%s\\LongSocketDirectoryName", g_base);
  CreateDirectoryA(dir, NULL);
  snprintf(sock, sizeof sock, "%s\\s.sock", dir);
  SOCKET l = ulisten(sock, 8, &e);
  if (l == INVALID_SOCKET) {
    fact("Q1.paths.alias_listen", "err=%d", e);
    return;
  }
  snprintf(alias, sizeof alias, "%s", sock);
  /* Not CharUpperA: importing user32.dll stops a restricted child from starting
   * (0xc0000142 under an ssh logon, seen while building this probe). */
  for (char *k = alias; *k; k++)
    if (*k >= 'a' && *k <= 'z') *k = (char)(*k - 'a' + 'A');
  SOCKET c = usock();
  fact("Q1.paths.connect_upper_case", "%s", WSOK(uconnect(c, alias)));
  closesocket(c);
  char shortdir[MAX_PATH] = "";
  DWORD sl = GetShortPathNameA(dir, shortdir, sizeof shortdir);
  if (sl && _stricmp(shortdir, dir) != 0) {
    snprintf(alias, sizeof alias, "%s\\s.sock", shortdir);
    c = usock();
    fact("Q1.paths.connect_short_name", "%s via=%s", WSOK(uconnect(c, alias)), shortdir);
    closesocket(c);
    HANDLE h = open_nofollow(alias, FILE_READ_ATTRIBUTES);
    char fin[MAX_PATH] = "";
    if (h != INVALID_HANDLE_VALUE) {
      GetFinalPathNameByHandleA(h, fin, sizeof fin, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
      CloseHandle(h);
    }
    const char *f = strncmp(fin, "\\\\?\\", 4) == 0 ? fin + 4 : fin;
    fact("Q1.paths.final_path_via_short_name", "exact=%d nocase=%d", strcmp(f, sock) == 0,
         _stricmp(f, sock) == 0);
  } else
    fact("Q1.paths.connect_short_name", "no 8.3 name (len=%lu)", (unsigned long)sl);
  /* The final path of a handle opened through an ancestor junction. */
  char j[MAX_PATH], via[MAX_PATH];
  snprintf(j, sizeof j, "%s\\jfp", g_base);
  DWORD jr = mkjunction(j, dir);
  if (!jr) {
    snprintf(via, sizeof via, "%s\\s.sock", j);
    c = usock();
    fact("Q1.paths.connect_via_ancestor_junction", "%s", WSOK(uconnect(c, via)));
    closesocket(c);
    HANDLE h = open_nofollow(via, FILE_READ_ATTRIBUTES);
    DWORD oe = h == INVALID_HANDLE_VALUE ? GetLastError() : 0;
    char fin[MAX_PATH] = "";
    if (h != INVALID_HANDLE_VALUE) {
      GetFinalPathNameByHandleA(h, fin, sizeof fin, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
      CloseHandle(h);
    }
    const char *f = strncmp(fin, "\\\\?\\", 4) == 0 ? fin + 4 : fin;
    fact("Q10.final_path_through_junction", "open=%s equals_opened=%d equals_real=%d",
         okerr(oe == 0, oe), _stricmp(f, via) == 0, _stricmp(f, sock) == 0);
    HANDLE jd = CreateFileA(j, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                            OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    fact("Q10.open_junction_dir_following", "%s",
         jd == INVALID_HANDLE_VALUE ? okerr(FALSE, GetLastError()) : "ok");
    if (jd != INVALID_HANDLE_VALUE) CloseHandle(jd);
    char plain[MAX_PATH];
    snprintf(plain, sizeof plain, "%s\\plain.txt", dir);
    HANDLE pf = CreateFileA(plain, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    if (pf != INVALID_HANDLE_VALUE) CloseHandle(pf);
    snprintf(plain, sizeof plain, "%s\\plain.txt", j);
    pf = CreateFileA(plain, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    fact("Q10.open_regular_file_through_junction", "%s",
         pf == INVALID_HANDLE_VALUE ? okerr(FALSE, GetLastError()) : "ok");
    if (pf != INVALID_HANDLE_VALUE) CloseHandle(pf);
    snprintf(plain, sizeof plain, "%s\\plain.txt", dir);
    DeleteFileA(plain);
    RemoveDirectoryA(j);
  } else
    fact("Q10.final_path_through_junction", "junction %s", okerr(FALSE, jr));
  closesocket(l);
  DeleteFileA(sock);
  RemoveDirectoryA(dir);
}

/* ------------------------- Q5 (T l.1168): the peer query once the peer ended */

static int role_connector(int argc, char **argv, const char *tag) {
  if (argc < 8) return 2;
  SOCKET c = usock();
  int r = uconnect(c, argv[6]);
  char one = 1;
  if (r == 0) send(c, &one, 1, 0);
  if (!strcmp(argv[7], "wait")) {
    HANDLE go = event(tag, "go");
    WaitForSingleObject(go, 10000);
  }
  return r == 0 ? 0 : 3; /* exits without closesocket */
}

static void q5_peer_exit(void) {
  char p[MAX_PATH], args[MAX_PATH + 16];
  int e;
  snprintf(p, sizeof p, "%s\\pe.sock", g_base);
  SOCKET l = ulisten(p, 4, &e);
  if (l == INVALID_SOCKET) {
    fact("Q5.peer_exit.listen", "err=%d", e);
    return;
  }
  child_t c;
  /* The peer exits before the accept. */
  snprintf(args, sizeof args, "%s exit", p);
  if (spawn(&c, "connector", "pxa", args, NULL, 0, FALSE, 0, NULL, NULL)) {
    DWORD cpid = c.pid;
    WaitForSingleObject(c.proc, 10000);
    finish(&c, 1000, "Q5");
    SOCKET a = accept(l, NULL, NULL);
    int pe = 0;
    DWORD pp = a == INVALID_SOCKET ? 0 : peerpid(a, &pe);
    fact("Q5.peer_exit.exited_before_accept", "accept=%s peerpid_is_peer=%d err=%d",
         a == INVALID_SOCKET ? "err" : "ok", pp == cpid, pe);
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pp);
    DWORD xc = 0;
    if (h) GetExitCodeProcess(h, &xc);
    fact("Q5.peer_exit.open_exited_pid", "%s exit_code=0x%lx",
         h ? "opened" : okerr(FALSE, GetLastError()), (unsigned long)xc);
    if (h) CloseHandle(h);
    char b[4];
    int n1 = a == INVALID_SOCKET ? -1 : recv(a, b, 4, 0);
    int e1 = n1 < 0 ? WSAGetLastError() : 0;
    int n2 = a == INVALID_SOCKET ? -1 : recv(a, b, 4, 0);
    int e2 = n2 < 0 ? WSAGetLastError() : 0;
    fact("Q5.peer_exit.recv_after_exit", "%d(err=%d),%d(err=%d)", n1, e1, n2, e2);
    if (a != INVALID_SOCKET) closesocket(a);
    h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pp);
    fact("Q5.peer_exit.open_exited_pid_after_close", "%s",
         h ? "opened" : okerr(FALSE, GetLastError()));
    if (h) CloseHandle(h);
  } else
    fact("Q5.peer_exit.spawn", "%s", okerr(FALSE, GetLastError()));
  /* Accepted while the peer lives, queried again after it exits. */
  HANDLE go = event("pxb", "go");
  snprintf(args, sizeof args, "%s wait", p);
  if (spawn(&c, "connector", "pxb", args, NULL, 0, FALSE, 0, NULL, NULL)) {
    DWORD cpid = c.pid;
    SOCKET a = accept(l, NULL, NULL);
    int pe1 = 0, pe2 = 0;
    DWORD p1 = peerpid(a, &pe1);
    SetEvent(go);
    WaitForSingleObject(c.proc, 10000);
    finish(&c, 1000, "Q5");
    DWORD p2 = peerpid(a, &pe2);
    fact("Q5.peer_exit.query_after_exit", "alive_is_peer=%d exited_is_peer=%d err=%d",
         p1 == cpid, p2 == cpid, pe2);
    closesocket(a);
  }
  CloseHandle(go);
  closesocket(l);
  DeleteFileA(p);
}

static void run_all(void);

static int child_main(int argc, char **argv) {
  /* argv: self role outhandle tag parentpid base ... */
  if (argc < 6) return 2;
  g_out = (HANDLE)(ULONG_PTR)_strtoui64(argv[2], NULL, 10);
  const char *role = argv[1], *tag = argv[3];
  g_parent = strtoul(argv[4], NULL, 10);
  if (!GetEnvironmentVariableA("LCNPROBE_RUN", g_run, sizeof g_run)) snprintf(g_run, sizeof g_run, "asis");
  snprintf(g_base, sizeof g_base, "%s", argv[5]);
  if (strcmp(role, "suite") && strcmp(role, "acl")) {
    char id[512], q[128];
    token_summary(LP_SELF_TOKEN, id, sizeof id);
    snprintf(q, sizeof q, "Q15.proc.%s.%s", role, tag);
    fact(q, "%s", id);
  }
  if (!strcmp(role, "connector")) return role_connector(argc, argv, tag);
  if (!strcmp(role, "host")) return role_host(argc, argv, tag);
  if (!strcmp(role, "consumer")) return role_consumer(argc, argv, tag);
  if (!strcmp(role, "third")) return role_third(argc, argv, tag);
  if (!strcmp(role, "creator")) return role_creator(argc, argv, tag);
  if (!strcmp(role, "hyg")) return role_hyg(argc, argv, tag);
  if (!strcmp(role, "acl")) return role_acl(argc, argv, tag);
  if (!strcmp(role, "pair")) return role_pair(argc, argv, tag);
  if (!strcmp(role, "jobchild")) return role_jobchild(argc, argv, tag);
  if (!strcmp(role, "suite") && argc > 6) {
    /* The whole suite again, in its own directory and event namespace. */
    g_parent = GetCurrentProcessId();
    snprintf(g_base, sizeof g_base, "%s", argv[6]);
    run_all();
    return 0;
  }
  if (!strcmp(role, "sleep")) {
    Sleep(argc > 6 ? (DWORD)atol(argv[6]) : 1000);
    return 0;
  }
  return 2;
}

int main(int argc, char **argv) {
  WSADATA wd;
  if (WSAStartup(MAKEWORD(2, 2), &wd) != 0) return 1;
  GetModuleFileNameA(NULL, g_self, sizeof g_self);
  HANDLE tok;
  if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &tok)) {
    sid_of_token(tok, g_usersid, sizeof g_usersid);
    CloseHandle(tok);
  }
  if (argc > 1 && strcmp(argv[1], "all") != 0) return child_main(argc, argv);

  g_parent = GetCurrentProcessId();
  if (argc > 2)
    snprintf(g_base, sizeof g_base, "%s", argv[2]);
  else {
    char tmp[MAX_PATH];
    GetTempPathA(sizeof tmp, tmp);
    size_t l = strlen(tmp);
    if (l && tmp[l - 1] == '\\') tmp[l - 1] = 0;
    snprintf(g_base, sizeof g_base, "%s\\lp%lu", tmp, (unsigned long)g_parent);
  }
  char full[MAX_PATH];
  GetFullPathNameA(g_base, sizeof full, full, NULL);
  snprintf(g_base, sizeof g_base, "%s", full);

  BOOL elevated = FALSE;
  if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &tok)) {
    TOKEN_ELEVATION el;
    DWORD len;
    elevated = GetTokenInformation(tok, TokenElevation, &el, sizeof el, &len) && el.TokenIsElevated;
    CloseHandle(tok);
  }
  grant_self_to_restricted();
  snprintf(g_run, sizeof g_run, "%s", elevated ? "elevated" : "asis");
  SetEnvironmentVariableA("LCNPROBE_RUN", g_run);
  run_all();
  if (elevated) {
    /* The same suite as a standard user would run it. */
    HANDLE std = make_standard_token();
    if (std) {
      char sbase[MAX_PATH];
      snprintf(sbase, sizeof sbase, "%ss", g_base);
      SetEnvironmentVariableA("LCNPROBE_RUN", "standard");
      CreateDirectoryA(g_base, NULL); /* for the suite's result file */
      child_t c;
      char args[MAX_PATH + 8];
      snprintf(args, sizeof args, "%s", sbase);
      if (spawn(&c, "suite", "standard", args, NULL, 0, FALSE, 0, std, NULL))
        finish(&c, 300000, "probe");
      else
        fact("probe.standard_run", "spawn %s", okerr(FALSE, GetLastError()));
      CloseHandle(std);
      cleanup_base();
      RemoveDirectoryA(g_base);
    }
  }
  fact("probe.done", "%s", "ok");
  WSACleanup();
  return 0;
}

/* Every question, in this process's run kind, under g_base. */
static void run_all(void) {
  CreateDirectoryA(g_base, NULL);
  fact("probe.base", "%s", g_base);
  token_facts();
  q15_build();
  q1_basics();
  q1_paths();
  attribution_case("v1", "inherit", FALSE, FALSE);
  attribution_case("v2", "inherit", FALSE, TRUE);
  attribution_case("v3", "inherit", TRUE, FALSE);
  attribution_creator_exits();
  attribution_case("v5", "dup", FALSE, FALSE);
  attribution_case("v6", "dup", TRUE, TRUE);
  q4_hygiene();
  q5_liveness();
  q5_peer_exit();
  HANDLE rt, wrt;
  make_tokens(&rt, &wrt);
  q6_q8_acl(rt, wrt);
  q8_owner_volume();
  if (rt) CloseHandle(rt);
  if (wrt) CloseHandle(wrt);
  q9_reparse();
  q10_ancestors(g_base);
  q12_pair();
  q13_job();
  Sleep(500);
  cleanup_base();
  fact("probe.base_removed", "%s", W32(RemoveDirectoryA(g_base)));
}
