// dispramd lends slices of the GB10 display carveout to CUDA processes.
//
// The firmware reserves a 2046 MiB DISPLAY_FRM carveout for the display, and the RM reports it
// through NV2080_CTRL_CMD_FB_GET_CARVEOUT_REGION_INFO. On GB10 the driver allocates nothing from
// it. dispramd wraps a slice of that range in an NV01_MEMORY_LIST_SYSTEM object, exports the
// object as a file descriptor, and passes the descriptor to the client, which imports it with
// cuMemImportFromShareableHandle (POSIX fd) or cudaImportExternalMemory (opaque fd).
//
// Protocol, compatible with the kindling-spark-os dispram clients: SOCK_SEQPACKET on SOCKET_PATH,
// one JSON object per message, and every request carries "key": "kindlingai_1".
//   {"op": "info"}              -> {"base", "size", "free", "largest"}
//   {"op": "alloc", "size": N}  -> {"ok": true, "base", "size"} with the fd attached (SCM_RIGHTS),
//                                  or {"ok": false, "error"}
// Slices are 2 MiB granular. A connection's slices return to the free list when it closes.
//
// The RM structures change between driver releases, so dispramd is compiled against the headers
// of NVIDIA_VERSION and runs only when that driver is loaded.
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include "nvtypes.h"
#include "nvmisc.h"
#include "nvos.h"
#include "nvstatus.h"
#include "class/cl0000.h"
#include "class/cl0080.h"
#include "class/cl2080.h"
#include "class/cl84a0.h"
#include "ctrl/ctrl0000/ctrl0000unix.h"
#include "ctrl/ctrl2080/ctrl2080fb.h"
#include "nv-ioctl.h"
#include "nv-ioctl-numbers.h"
#include "nv_escape.h"

#ifndef NVIDIA_VERSION
#error "NVIDIA_VERSION must name the driver release the RM headers come from"
#endif

#define SOCKET_PATH "/run/dispram/dispram.sock"
#define KEY "kindlingai_1"
#define GRAN (2ULL << 20)
#define MAX_RANGES 4096
#define MAX_EVENTS 64

static void logf_(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fputs("dispramd: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

// RM client

static int ctl = -1;
static NvHandle client;
static const NvHandle device = 0x5c000001, subdevice = 0x5c000002;
static NvHandle next_list = 0x5c000010;

static int rm_alloc(NvHandle parent, NvHandle handle, NvU32 cls, void *params, NvU32 size)
{
    NVOS21_PARAMETERS p = {
        .hRoot = client, .hObjectParent = parent, .hObjectNew = handle, .hClass = cls,
        .pAllocParms = NV_PTR_TO_NvP64(params), .paramsSize = size,
    };
    if (ioctl(ctl, _IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_ALLOC, NVOS21_PARAMETERS), &p) < 0)
        return -errno;
    if (cls == NV01_ROOT_CLIENT)
        client = p.hObjectNew;
    return (int)p.status;
}

static int rm_control(NvHandle object, NvU32 cmd, void *params, NvU32 size)
{
    NVOS54_PARAMETERS p = {
        .hClient = client, .hObject = object, .cmd = cmd,
        .params = NV_PTR_TO_NvP64(params), .paramsSize = size,
    };
    if (ioctl(ctl, _IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_CONTROL, NVOS54_PARAMETERS), &p) < 0)
        return -errno;
    return (int)p.status;
}

static int rm_free(NvHandle handle)
{
    NVOS00_PARAMETERS p = {.hRoot = client, .hObjectParent = device, .hObjectOld = handle};
    if (ioctl(ctl, _IOWR(NV_IOCTL_MAGIC, NV_ESC_RM_FREE, NVOS00_PARAMETERS), &p) < 0)
        return -errno;
    return (int)p.status;
}

// Opens an RM client with device 0 and its subdevice.
static int rm_open(void)
{
    ctl = open("/dev/nvidiactl", O_RDWR | O_CLOEXEC);
    int gpu = open("/dev/nvidia0", O_RDWR | O_CLOEXEC);
    if (ctl < 0 || gpu < 0) {
        logf_("open /dev/nvidiactl, /dev/nvidia0: %s", strerror(errno));
        return -1;
    }
    nv_ioctl_rm_api_version_t ver = {.cmd = NV_RM_API_VERSION_CMD_QUERY};
    if (ioctl(ctl, _IOWR(NV_IOCTL_MAGIC, NV_ESC_CHECK_VERSION_STR, ver), &ver) < 0) {
        logf_("RM API version query: %s", strerror(errno));
        return -1;
    }
    nv_ioctl_register_fd_t reg = {.ctl_fd = ctl};
    if (ioctl(gpu, _IOWR(NV_IOCTL_MAGIC, NV_ESC_REGISTER_FD, reg), &reg) < 0) {
        logf_("register control fd: %s", strerror(errno));
        return -1;
    }
    int st;
    if ((st = rm_alloc(0, 0, NV01_ROOT_CLIENT, NULL, 0))) {
        logf_("alloc client: status 0x%x", st);
        return -1;
    }
    NV0080_ALLOC_PARAMETERS dev = {.deviceId = 0};
    if ((st = rm_alloc(client, device, NV01_DEVICE_0, &dev, sizeof dev))) {
        logf_("alloc device: status 0x%x", st);
        return -1;
    }
    NV2080_ALLOC_PARAMETERS sub = {.subDeviceId = 0};
    if ((st = rm_alloc(device, subdevice, NV20_SUBDEVICE_0, &sub, sizeof sub))) {
        logf_("alloc subdevice: status 0x%x", st);
        return -1;
    }
    return 0;
}

// Reads the DISPLAY_FRM carveout from the RM.
static int rm_display_frm(uint64_t *base, uint64_t *size)
{
    NV2080_CTRL_FB_GET_CARVEOUT_REGION_INFO_PARAMS info = {0};
    if (rm_control(subdevice, NV2080_CTRL_CMD_FB_GET_CARVEOUT_REGION_INFO, &info, sizeof info))
        return -1;
    for (NvU32 i = 0; i < info.numCarveoutRegions; i++)
        if (info.carveoutRegion[i].carveoutType == NV2080_CTRL_FB_GET_CARVEOUT_REGION_CARVEOUT_TYPE_DISPLAY_FRM) {
            *base = info.carveoutRegion[i].base;
            *size = info.carveoutRegion[i].size;
            return 0;
        }
    return -1;
}

// Wraps [base, base+size) in a contiguous memory-list object and exports it. Returns the fd and
// stores the object's handle in *handle, or returns -1.
static int rm_export_range(uint64_t base, uint64_t size, NvHandle *handle)
{
    NvHandle list = next_list++;
    NvU64 pfn = base >> 12;
    NV_MEMORY_LIST_ALLOCATION_PARAMS p = {
        .pageCount = 1,
        .size = size,
        .limit = size - 1,
        .pageNumberList = NV_PTR_TO_NvP64(&pfn),
        .flagsOs02 = DRF_DEF(OS02, _FLAGS, _PHYSICALITY, _CONTIGUOUS) |
                     DRF_DEF(OS02, _FLAGS, _COHERENCY, _CACHED),
    };
    int st = rm_alloc(device, list, NV01_MEMORY_LIST_SYSTEM, &p, sizeof p);
    if (st) {
        logf_("alloc memory list: status 0x%x", st);
        return -1;
    }
    int fd = open("/dev/nvidiactl", O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        rm_free(list);
        return -1;
    }
    NV0000_CTRL_OS_UNIX_EXPORT_OBJECT_TO_FD_PARAMS e = {
        .object = {.type = NV0000_CTRL_OS_UNIX_EXPORT_OBJECT_TYPE_RM,
                   .data.rmObject = {.hDevice = device, .hParent = device, .hObject = list}},
        .fd = fd,
    };
    if ((st = rm_control(client, NV0000_CTRL_CMD_OS_UNIX_EXPORT_OBJECT_TO_FD, &e, sizeof e))) {
        logf_("export to fd: status 0x%x", st);
        close(fd);
        rm_free(list);
        return -1;
    }
    *handle = list;
    return fd;
}

// Free list: sorted, disjoint [start, end) ranges inside the carveout.

struct range {
    uint64_t start, end;
};

static uint64_t carveout_base, carveout_size;
static struct range free_ranges[MAX_RANGES];
static size_t nfree;

static int carve(uint64_t size, uint64_t *start)
{
    for (size_t i = 0; i < nfree; i++) {
        struct range *r = &free_ranges[i];
        if (r->end - r->start < size)
            continue;
        *start = r->start;
        r->start += size;
        if (r->start == r->end) {
            memmove(r, r + 1, (nfree - i - 1) * sizeof *r);
            nfree--;
        }
        return 0;
    }
    return -1;
}

static void release(uint64_t start, uint64_t size)
{
    uint64_t end = start + size;
    size_t i = 0;
    while (i < nfree && free_ranges[i].start < start)
        i++;
    // Slices come from the free list, so the list always has room for the range they leave.
    memmove(&free_ranges[i + 1], &free_ranges[i], (nfree - i) * sizeof free_ranges[0]);
    free_ranges[i] = (struct range){start, end};
    nfree++;
    if (i + 1 < nfree && free_ranges[i].end == free_ranges[i + 1].start) {
        free_ranges[i].end = free_ranges[i + 1].end;
        memmove(&free_ranges[i + 1], &free_ranges[i + 2], (nfree - i - 2) * sizeof free_ranges[0]);
        nfree--;
    }
    if (i > 0 && free_ranges[i - 1].end == free_ranges[i].start) {
        free_ranges[i - 1].end = free_ranges[i].end;
        memmove(&free_ranges[i], &free_ranges[i + 1], (nfree - i - 1) * sizeof free_ranges[0]);
        nfree--;
    }
}

static int stats(char *buf, size_t len)
{
    uint64_t total = 0, largest = 0;
    for (size_t i = 0; i < nfree; i++) {
        uint64_t n = free_ranges[i].end - free_ranges[i].start;
        total += n;
        if (n > largest)
            largest = n;
    }
    return snprintf(buf, len, "\"base\": %" PRIu64 ", \"size\": %" PRIu64 ", \"free\": %" PRIu64
                    ", \"largest\": %" PRIu64, carveout_base, carveout_size, total, largest);
}

// Connections and the slices they hold.

struct slice {
    uint64_t start, size;
    NvHandle handle;
};

struct conn {
    int fd;
    struct slice *slices;
    size_t nslices, cap;
    struct conn *next;
};

static struct conn *conns;

static void close_conn(int epfd, struct conn *c)
{
    for (size_t i = 0; i < c->nslices; i++) {
        rm_free(c->slices[i].handle);
        release(c->slices[i].start, c->slices[i].size);
        logf_("freed 0x%" PRIx64 " + %" PRIu64 " MiB", c->slices[i].start, c->slices[i].size >> 20);
    }
    epoll_ctl(epfd, EPOLL_CTL_DEL, c->fd, NULL);
    close(c->fd);
    for (struct conn **p = &conns; *p; p = &(*p)->next)
        if (*p == c) {
            *p = c->next;
            break;
        }
    free(c->slices);
    free(c);
}

// Request parsing. Requests are flat JSON objects with string and integer values.

// Returns a pointer to the value of "name" in msg, or NULL.
static const char *field(const char *msg, const char *name)
{
    char pat[32];
    snprintf(pat, sizeof pat, "\"%s\"", name);
    const char *p = strstr(msg, pat);
    if (!p)
        return NULL;
    p += strlen(pat);
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')
        p++;
    if (*p++ != ':')
        return NULL;
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')
        p++;
    return p;
}

// True when "name" holds the string value want.
static int field_is(const char *msg, const char *name, const char *want)
{
    const char *p = field(msg, name);
    size_t n = strlen(want);
    return p && *p == '"' && strncmp(p + 1, want, n) == 0 && p[n + 1] == '"';
}

static int field_u64(const char *msg, const char *name, uint64_t *out)
{
    const char *p = field(msg, name);
    if (!p || *p < '0' || *p > '9')
        return -1;
    char *end;
    errno = 0;
    unsigned long long v = strtoull(p, &end, 10);
    if (errno || end == p)
        return -1;
    *out = v;
    return 0;
}

static void reply(int fd, const char *msg, int pass_fd)
{
    struct iovec iov = {.iov_base = (void *)msg, .iov_len = strlen(msg)};
    char control[CMSG_SPACE(sizeof(int))] = {0};
    struct msghdr mh = {.msg_iov = &iov, .msg_iovlen = 1};
    if (pass_fd >= 0) {
        mh.msg_control = control;
        mh.msg_controllen = sizeof control;
        struct cmsghdr *cm = CMSG_FIRSTHDR(&mh);
        cm->cmsg_level = SOL_SOCKET;
        cm->cmsg_type = SCM_RIGHTS;
        cm->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(cm), &pass_fd, sizeof(int));
    }
    if (sendmsg(fd, &mh, MSG_NOSIGNAL) < 0)
        logf_("send: %s", strerror(errno));
}

// Handles one request. Returns -1 when the connection should close.
static int handle(struct conn *c, char *msg)
{
    char out[512], st[256];
    if (!field_is(msg, "key", KEY)) {
        reply(c->fd, "{\"ok\": false, \"error\": \"missing or unknown key\"}", -1);
        return -1;
    }
    if (field_is(msg, "op", "info")) {
        stats(st, sizeof st);
        snprintf(out, sizeof out, "{%s}", st);
        reply(c->fd, out, -1);
        return 0;
    }
    if (!field_is(msg, "op", "alloc")) {
        reply(c->fd, "{\"ok\": false, \"error\": \"unknown op\"}", -1);
        return 0;
    }
    uint64_t size;
    if (field_u64(msg, "size", &size) || size == 0 || size > carveout_size) {
        reply(c->fd, "{\"ok\": false, \"error\": \"invalid size\"}", -1);
        return 0;
    }
    size = (size + GRAN - 1) / GRAN * GRAN;
    uint64_t start;
    if (carve(size, &start)) {
        stats(st, sizeof st);
        snprintf(out, sizeof out, "{\"ok\": false, \"error\": \"not enough free carveout\", %s}", st);
        reply(c->fd, out, -1);
        return 0;
    }
    if (c->nslices == c->cap) {
        size_t cap = c->cap ? c->cap * 2 : 8;
        struct slice *s = realloc(c->slices, cap * sizeof *s);
        if (!s) {
            release(start, size);
            reply(c->fd, "{\"ok\": false, \"error\": \"out of memory\"}", -1);
            return 0;
        }
        c->slices = s;
        c->cap = cap;
    }
    NvHandle h;
    int fd = rm_export_range(start, size, &h);
    if (fd < 0) {
        release(start, size);
        reply(c->fd, "{\"ok\": false, \"error\": \"RM export failed\"}", -1);
        return 0;
    }
    c->slices[c->nslices++] = (struct slice){start, size, h};
    snprintf(out, sizeof out, "{\"ok\": true, \"base\": %" PRIu64 ", \"size\": %" PRIu64 "}", start, size);
    reply(c->fd, out, fd);
    close(fd);
    logf_("lent 0x%" PRIx64 " + %" PRIu64 " MiB", start, size >> 20);
    return 0;
}

static int driver_matches(void)
{
    char line[256] = "";
    FILE *f = fopen("/proc/driver/nvidia/version", "r");
    if (f) {
        if (!fgets(line, sizeof line, f))
            line[0] = '\0';
        fclose(f);
    }
    line[strcspn(line, "\n")] = '\0';
    if (strstr(line, " " NVIDIA_VERSION " "))
        return 1;
    logf_("driver '%s' differs from %s, the release dispramd is built for; lending nothing",
          line[0] ? line : "not loaded", NVIDIA_VERSION);
    return 0;
}

int main(void)
{
    if (!driver_matches())
        return 3;
    if (rm_open())
        return 1;
    if (rm_display_frm(&carveout_base, &carveout_size)) {
        logf_("the RM reports no DISPLAY_FRM carveout");
        return 1;
    }
    free_ranges[0] = (struct range){carveout_base, carveout_base + carveout_size};
    nfree = 1;
    logf_("DISPLAY_FRM 0x%" PRIx64 " + %" PRIu64 " MiB", carveout_base, carveout_size >> 20);

    int srv = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    strncpy(addr.sun_path, SOCKET_PATH, sizeof addr.sun_path - 1);
    unlink(SOCKET_PATH);
    if (srv < 0 || bind(srv, (struct sockaddr *)&addr, sizeof addr) || chmod(SOCKET_PATH, 0666) ||
        listen(srv, 64)) {
        logf_("listen on %s: %s", SOCKET_PATH, strerror(errno));
        return 1;
    }

    int epfd = epoll_create1(EPOLL_CLOEXEC);
    struct epoll_event ev = {.events = EPOLLIN, .data.ptr = NULL};
    epoll_ctl(epfd, EPOLL_CTL_ADD, srv, &ev);
    struct epoll_event events[MAX_EVENTS];
    char msg[4097];

    for (;;) {
        int n = epoll_wait(epfd, events, MAX_EVENTS, -1);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            logf_("epoll_wait: %s", strerror(errno));
            return 1;
        }
        for (int i = 0; i < n; i++) {
            struct conn *c = events[i].data.ptr;
            if (!c) {
                int fd = accept4(srv, NULL, NULL, SOCK_CLOEXEC);
                if (fd < 0)
                    continue;
                c = calloc(1, sizeof *c);
                if (!c) {
                    close(fd);
                    continue;
                }
                c->fd = fd;
                c->next = conns;
                conns = c;
                struct epoll_event cev = {.events = EPOLLIN, .data.ptr = c};
                epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &cev);
                continue;
            }
            ssize_t len = recv(c->fd, msg, sizeof msg - 1, 0);
            if (len <= 0) {
                close_conn(epfd, c);
                continue;
            }
            msg[len] = '\0';
            if (handle(c, msg))
                close_conn(epfd, c);
        }
    }
}
