// sparkos-fabric gives every ConnectX netdev the fabric address of whatever its cable reaches, with
// no setup. It is the C form of kindling-spark-os's sparkos-fabric, and a box running either one
// works out the same addresses as the box at the other end of a direct cable.
//
// Each physical ConnectX port shows up as one netdev per PCI root. Every netdev gets an address on a
// subnet of its own root, so one cable carries both roots, and LLDP tells what the cable reaches:
//
// - the switch: 10.100.H.L/16 on root 1 and 10.101.H.L/16 on root 2, where H.L is the box's id
// - another box running sparkos-fabric: a /31 per root at 10.110.x.y and 10.111.x.y, placed by a
//   hash of the two ids, so both ends work out the same subnet. The lower id takes the even address.
//
// The id is the last two bytes of the LAN port's MAC (the r8169 netdev), the same digits as a
// gx10-XXXX hostname. Talos has no lldpd, so sparkos-fabric speaks LLDP on the ConnectX netdevs
// itself, with that MAC as the chassis ID and `sparkos-fabric XXXX` as the system description. That
// is how a peer box is told apart from the switch, since both advertise bridging. A neighbour
// without it that advertises bridging, and not the Station capability every Linux lldpd lists, is
// the switch. A box that does not run sparkos-fabric gets no address on a direct cable to it.
//
// An address is added only after IPv4 duplicate detection (an ARP probe) finds nobody on it. A
// netdev keeps its address through a carrier drop. It loses it when LLDP shows the cable reaching
// something else, or when the address moves to another netdev. Addresses outside the fabric subnets
// are left alone.
//
// The environment (the sparkos-fabric ExtensionServiceConfig) overrides:
//   FABRIC_ID=9722                      the id, in hex
//   FABRIC_HOST=36                      host number on the switch subnets instead of the id
//   FABRIC_SUBNETS=A/16 B/16            switch subnets, root 1 then root 2
//   FABRIC_LINK_SUBNETS=C/16 D/16       ranges the per-link /31s come from, root 1 then root 2
//   FABRIC_SWITCH=crs812                the switch's LLDP system name, instead of "any bridge"
//   FABRIC_MTU=9000                     MTU for every ConnectX netdev
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <net/if.h>
#include <netpacket/packet.h>
#include <poll.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define TAG "sparkos-fabric"
#define MAX_DEVS 16
#define MAX_NEIGHBOURS 4    // per netdev, lldpd's default max-neighbors
#define MAX_ADDRS 1024
#define STEP 5.0            // seconds between passes
#define TX_INTERVAL 30.0    // lldpd's default tx-interval
#define TX_TTL 120          // lldpd's default: tx-interval times tx-hold
#define LLDP_ETHERTYPE 0x88cc
#define ARP_ETHERTYPE 0x0806
#define CAP_BRIDGE 0x0004
#define CAP_STATION 0x0080

static const uint8_t lldp_group[6] = {0x01, 0x80, 0xc2, 0x00, 0x00, 0x0e};

struct net {
    uint32_t base;    // host byte order
    int prefix;
};

struct want {
    int set;
    uint32_t ip;
    int prefix;
};

struct neighbour {
    uint8_t chassis[256], port[256];    // chassis and port ID with subtype: LLDP's neighbour identity
    int chassis_len, port_len;
    char name[256], descr[256];
    int bridge;
    double expires;
};

struct dev {
    char name[IF_NAMESIZE];
    int ifindex, root, fd, carrier;
    uint8_t mac[6];
    double next_tx;
    struct neighbour nb[MAX_NEIGHBOURS];
    int nnb;
    char note[192], noted[192];    // what this pass would log, and what was last logged
};

struct addr {
    int ifindex;
    uint32_t ip;
    int prefix;
};

static struct net subnets[2], links[2];
static unsigned long fabric_id, fabric_host;
static int have_fabric_id, have_fabric_host, fabric_mtu = 9000;
static const char *fabric_switch;

static struct dev devs[MAX_DEVS], next_devs[MAX_DEVS];
static int ndevs;
static struct addr have[MAX_ADDRS];
static int nhave;
static uint8_t chassis[6];
static int have_chassis;
static unsigned long me;
static char descr[64];
static int ctl = -1, nl = -1;
static uint32_t nl_seq;

static void logf_(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fputs(TAG ": ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

static void note(struct dev *d, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(d->note, sizeof d->note, fmt, ap);
    va_end(ap);
}

static double now_(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static const char *ipstr(char buf[24], uint32_t ip, int prefix)
{
    snprintf(buf, 24, "%u.%u.%u.%u/%d", ip >> 24, ip >> 16 & 255, ip >> 8 & 255, ip & 255, prefix);
    return buf;
}

static uint64_t net_size(struct net n)
{
    return 1ULL << (32 - n.prefix);
}

static int in_net(uint32_t ip, struct net n)
{
    return n.prefix == 0 || ip >> (32 - n.prefix) == n.base >> (32 - n.prefix);
}

// SHA-256 (FIPS 180-4), for the /31 placement kindling-spark-os derives from it

static uint32_t ror(uint32_t x, int n)
{
    return x >> n | x << (32 - n);
}

static void sha256_block(uint32_t h[8], const uint8_t *b)
{
    static const uint32_t k[64] = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    };
    uint32_t w[64], v[8];
    for (int i = 0; i < 16; i++)
        w[i] = (uint32_t)b[4 * i] << 24 | (uint32_t)b[4 * i + 1] << 16 | (uint32_t)b[4 * i + 2] << 8 | b[4 * i + 3];
    for (int i = 16; i < 64; i++)
        w[i] = w[i - 16] + (ror(w[i - 15], 7) ^ ror(w[i - 15], 18) ^ w[i - 15] >> 3) + w[i - 7] +
               (ror(w[i - 2], 17) ^ ror(w[i - 2], 19) ^ w[i - 2] >> 10);
    memcpy(v, h, sizeof v);
    for (int i = 0; i < 64; i++) {
        uint32_t t1 = v[7] + (ror(v[4], 6) ^ ror(v[4], 11) ^ ror(v[4], 25)) + ((v[4] & v[5]) ^ (~v[4] & v[6])) + k[i] + w[i];
        uint32_t t2 = (ror(v[0], 2) ^ ror(v[0], 13) ^ ror(v[0], 22)) + ((v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]));
        memmove(v + 1, v, 7 * sizeof v[0]);
        v[4] += t1;
        v[0] = t1 + t2;
    }
    for (int i = 0; i < 8; i++)
        h[i] += v[i];
}

static void sha256(const void *data, size_t len, uint8_t out[32])
{
    uint32_t h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    const uint8_t *p = data;
    uint8_t tail[128] = {0};
    size_t n = len;
    for (; n >= 64; p += 64, n -= 64)
        sha256_block(h, p);
    memcpy(tail, p, n);
    tail[n] = 0x80;
    size_t blocks = n + 9 > 64 ? 2 : 1;
    for (int i = 0; i < 8; i++)
        tail[blocks * 64 - 1 - i] = (uint8_t)((uint64_t)len * 8 >> 8 * i);
    for (size_t i = 0; i < blocks; i++)
        sha256_block(h, tail + 64 * i);
    for (int i = 0; i < 32; i++)
        out[i] = (uint8_t)(h[i / 4] >> (24 - 8 * (i % 4)));
}

// The /31 of the link between ids ME and PEER in N, the same one kindling-spark-os's link_addr()
// works out: a hash of "lo:hi" picks the pair, and the lower id takes the even address.
static struct want link_addr(struct net n, unsigned long self, unsigned long peer)
{
    unsigned long lo = self < peer ? self : peer, hi = self < peer ? peer : self;
    char s[48];
    uint8_t h[32];
    int len = snprintf(s, sizeof s, "%04lx:%04lx", lo, hi);
    sha256(s, (size_t)len, h);
    uint32_t pick = (uint32_t)h[0] << 24 | (uint32_t)h[1] << 16 | (uint32_t)h[2] << 8 | h[3];
    uint32_t slot = (uint32_t)(pick % (net_size(n) / 2));
    return (struct want){1, n.base + 2 * slot + (self == lo ? 0 : 1), 31};
}

// Configuration

static int parse_hex(const char *s, unsigned long *out)
{
    char *end;
    if (!isxdigit((unsigned char)*s))
        return -1;
    errno = 0;
    *out = strtoul(s, &end, 16);
    return errno || *end ? -1 : 0;
}

static int parse_nets(const char *key, const char *fallback, int max_prefix, struct net out[2])
{
    const char *value = getenv(key);
    char buf[256], *save, *tok;
    int n = 0;
    snprintf(buf, sizeof buf, "%s", value ? value : fallback);
    for (tok = strtok_r(buf, " \t", &save); tok; tok = strtok_r(NULL, " \t", &save)) {
        char *slash = strchr(tok, '/'), *end;
        struct in_addr a;
        if (n == 2 || !slash)
            goto bad;
        *slash = '\0';
        long prefix = strtol(slash + 1, &end, 10);
        if (inet_pton(AF_INET, tok, &a) != 1 || end == slash + 1 || *end || prefix < 0 || prefix > max_prefix)
            goto bad;
        out[n] = (struct net){ntohl(a.s_addr), (int)prefix};
        if (prefix && out[n].base << prefix)
            goto bad;    // host bits set
        n++;
    }
    if (n == 2)
        return 0;
bad:
    logf_("%s=%s is not two networks, root 1 then root 2, of at most /%d", key, value ? value : fallback, max_prefix);
    return -1;
}

static int configure(void)
{
    const char *v;
    char *end;
    if (parse_nets("FABRIC_SUBNETS", "10.100.0.0/16 10.101.0.0/16", 32, subnets) ||
        parse_nets("FABRIC_LINK_SUBNETS", "10.110.0.0/16 10.111.0.0/16", 31, links))
        return -1;
    if ((v = getenv("FABRIC_ID"))) {
        if (parse_hex(v, &fabric_id)) {
            logf_("FABRIC_ID=%s is not a hex id", v);
            return -1;
        }
        have_fabric_id = 1;
    }
    if ((v = getenv("FABRIC_HOST"))) {
        errno = 0;
        fabric_host = strtoul(v, &end, 10);
        if (!isdigit((unsigned char)*v) || *end || errno) {
            logf_("FABRIC_HOST=%s is not a host number", v);
            return -1;
        }
        have_fabric_host = 1;
    }
    if ((v = getenv("FABRIC_MTU"))) {
        errno = 0;
        long mtu = strtol(v, &end, 10);
        if (!isdigit((unsigned char)*v) || *end || errno || mtu < 68 || mtu > 65535) {
            logf_("FABRIC_MTU=%s is not an MTU", v);
            return -1;
        }
        fabric_mtu = (int)mtu;
    }
    fabric_switch = getenv("FABRIC_SWITCH");
    return 0;
}

// Netdevs

static int read_sys(const char *name, const char *attr, char *buf, size_t len)
{
    char path[PATH_MAX];
    snprintf(path, sizeof path, "/sys/class/net/%s/%s", name, attr);
    FILE *f = fopen(path, "re");
    if (!f)
        return -1;
    int ok = fgets(buf, (int)len, f) != NULL;
    fclose(f);
    buf[ok ? strcspn(buf, "\n") : 0] = '\0';
    return ok ? 0 : -1;
}

// The last component of where /sys/class/net/NAME/ATTR leads: the driver, or the PCI address.
static int sys_target(const char *name, const char *attr, char *buf, size_t len)
{
    char path[PATH_MAX], real[PATH_MAX];
    snprintf(path, sizeof path, "/sys/class/net/%s/%s", name, attr);
    if (!realpath(path, real))
        return -1;
    snprintf(buf, len, "%s", strrchr(real, '/') + 1);
    return 0;
}

static int sys_mac(const char *name, uint8_t mac[6])
{
    char buf[64];
    return read_sys(name, "address", buf, sizeof buf) ||
                   sscanf(buf, "%hhx:%hhx:%hhx:%hhx:%hhx:%hhx", &mac[0], &mac[1], &mac[2], &mac[3], &mac[4], &mac[5]) != 6
               ? -1
               : 0;
}

static int open_lldp(const struct dev *d)
{
    int fd = socket(AF_PACKET, SOCK_RAW | SOCK_NONBLOCK | SOCK_CLOEXEC, htons(LLDP_ETHERTYPE));
    struct sockaddr_ll sll = {.sll_family = AF_PACKET, .sll_protocol = htons(LLDP_ETHERTYPE), .sll_ifindex = d->ifindex};
    struct packet_mreq mr = {.mr_ifindex = d->ifindex, .mr_type = PACKET_MR_MULTICAST, .mr_alen = 6};
    memcpy(mr.mr_address, lldp_group, 6);
    if (fd < 0 || bind(fd, (struct sockaddr *)&sll, sizeof sll) ||
        setsockopt(fd, SOL_PACKET, PACKET_ADD_MEMBERSHIP, &mr, sizeof mr)) {
        logf_("%s: LLDP socket: %s", d->name, strerror(errno));
        if (fd >= 0)
            close(fd);
        return -1;
    }
    return fd;
}

static void forget(struct dev *d, int i, const char *why)
{
    logf_("%s: lost \"%s\" (%s)", d->name, d->nb[i].name, why);
    memmove(&d->nb[i], &d->nb[i + 1], (size_t)(d->nnb - i - 1) * sizeof d->nb[0]);
    d->nnb--;
}

static int by_name(const void *a, const void *b)
{
    return strcmp(((const struct dev *)a)->name, ((const struct dev *)b)->name);
}

static void link_up(const struct dev *d)
{
    struct ifreq ifr = {0};
    memcpy(ifr.ifr_name, d->name, sizeof d->name);    // both IFNAMSIZ, NUL-terminated
    if (!ioctl(ctl, SIOCGIFFLAGS, &ifr) && !(ifr.ifr_flags & IFF_UP)) {
        ifr.ifr_flags |= IFF_UP;
        if (ioctl(ctl, SIOCSIFFLAGS, &ifr))
            logf_("%s: setting it up: %s", d->name, strerror(errno));
    }
    if (!ioctl(ctl, SIOCGIFMTU, &ifr) && ifr.ifr_mtu != fabric_mtu) {
        ifr.ifr_mtu = fabric_mtu;
        if (ioctl(ctl, SIOCSIFMTU, &ifr))
            logf_("%s: setting MTU %d: %s", d->name, fabric_mtu, strerror(errno));
    }
}

// ConnectX netdevs, root 1 or 2 by PCI domain order, and the LAN port's MAC for the chassis ID.
// Netdevs are matched by ifindex, so a udev rename keeps the socket and the neighbours.
static void scan(double now)
{
    char domain[MAX_DEVS][64], lan[IF_NAMESIZE] = "";
    int n = 0;
    DIR *dir = opendir("/sys/class/net");
    if (!dir) {
        logf_("/sys/class/net: %s", strerror(errno));
        return;
    }
    for (struct dirent *e; (e = readdir(dir));) {
        char drv[64];
        struct dev *d = &next_devs[n];
        if (e->d_name[0] == '.' || strlen(e->d_name) >= IF_NAMESIZE || sys_target(e->d_name, "device/driver", drv, sizeof drv))
            continue;
        if (!strcmp(drv, "r8169") && (!lan[0] || strcmp(e->d_name, lan) < 0))
            strcpy(lan, e->d_name);
        if (strcmp(drv, "mlx5_core") || n == MAX_DEVS || sys_target(e->d_name, "device", domain[n], sizeof domain[n]))
            continue;
        domain[n][strcspn(domain[n], ":")] = '\0';
        memset(d, 0, sizeof *d);
        strcpy(d->name, e->d_name);
        d->ifindex = (int)if_nametoindex(d->name);
        n++;
    }
    closedir(dir);

    int m = 0;
    for (int i = 0; i < n; i++) {
        // root = 1 + the number of distinct PCI domains ordered before this netdev's
        int root = 1;
        for (int j = 0; j < n; j++) {
            int first = 1;
            for (int k = 0; k < j; k++)
                first &= strcmp(domain[k], domain[j]) != 0;
            root += first && strcmp(domain[j], domain[i]) < 0;
        }
        if (root > 2 || !next_devs[i].ifindex)
            continue;
        struct dev d = next_devs[i];
        int j = 0;
        while (j < ndevs && devs[j].ifindex != d.ifindex)
            j++;
        if (j < ndevs) {
            strcpy(devs[j].name, d.name);
            d = devs[j];
            devs[j].ifindex = 0;    // carried over
        } else {
            d.fd = -1;
        }
        d.root = root;
        link_up(&d);    // before the socket: binding to a down netdev leaves ENETDOWN pending on it
        if (d.fd < 0)
            d.fd = open_lldp(&d);
        sys_mac(d.name, d.mac);
        char buf[8];
        int carrier = !read_sys(d.name, "carrier", buf, sizeof buf) && !strcmp(buf, "1");
        if (carrier && !d.carrier)
            d.next_tx = now;    // newly cabled: tell the far end at once
        if (!carrier && d.carrier)
            while (d.nnb)
                forget(&d, d.nnb - 1, "carrier lost");
        d.carrier = carrier;
        next_devs[m++] = d;
    }
    for (int j = 0; j < ndevs; j++)
        if (devs[j].ifindex && devs[j].fd >= 0)
            close(devs[j].fd);
    memcpy(devs, next_devs, (size_t)m * sizeof devs[0]);
    ndevs = m;
    qsort(devs, (size_t)ndevs, sizeof devs[0], by_name);

    have_chassis = lan[0] && !sys_mac(lan, chassis);
}

// LLDP

static size_t put_tlv(uint8_t *t, int type, const void *v, size_t len)
{
    t[0] = (uint8_t)(type << 1 | (int)(len >> 8));
    t[1] = (uint8_t)len;
    if (len)
        memcpy(t + 2, v, len);
    return len + 2;
}

static void send_lldp(struct dev *d, double now)
{
    uint8_t f[1024], *t = f + 14, id[7];
    char host[256] = "";
    gethostname(host, sizeof host - 1);
    memcpy(f, lldp_group, 6);
    memcpy(f + 6, d->mac, 6);
    f[12] = LLDP_ETHERTYPE >> 8;
    f[13] = LLDP_ETHERTYPE & 255;
    id[0] = 4;    // chassis ID: MAC address
    memcpy(id + 1, chassis, 6);
    t += put_tlv(t, 1, id, 7);
    id[0] = 3;    // port ID: MAC address
    memcpy(id + 1, d->mac, 6);
    t += put_tlv(t, 2, id, 7);
    t += put_tlv(t, 3, (uint8_t[]){TX_TTL >> 8, TX_TTL & 255}, 2);
    t += put_tlv(t, 4, d->name, strlen(d->name));
    if (host[0])
        t += put_tlv(t, 5, host, strlen(host));
    t += put_tlv(t, 6, descr, strlen(descr));
    t += put_tlv(t, 7, (uint8_t[]){0, CAP_STATION, 0, CAP_STATION}, 4);
    t += put_tlv(t, 0, NULL, 0);
    struct sockaddr_ll to = {.sll_family = AF_PACKET, .sll_ifindex = d->ifindex, .sll_halen = 6};
    memcpy(to.sll_addr, lldp_group, 6);
    if (sendto(d->fd, f, (size_t)(t - f), 0, (struct sockaddr *)&to, sizeof to) < 0) {
        logf_("%s: sending LLDP: %s", d->name, strerror(errno));
        d->next_tx = now + STEP;
        return;
    }
    d->next_tx = now + TX_INTERVAL;
}

// One received LLDPDU: 0 when nothing the plan depends on changed, 1 when something did, 2 when it
// comes from a new neighbour.
static int receive(struct dev *d, const uint8_t *f, size_t n, double now)
{
    const uint8_t *c = NULL, *p = NULL, *t = f + 14, *end = f + n;
    int clen = 0, plen = 0, ttl = -1, caps = 0, enabled = 0;
    char name[256] = "", desc[256] = "";
    if (n < 14 || f[12] != LLDP_ETHERTYPE >> 8 || f[13] != (LLDP_ETHERTYPE & 255))
        return 0;
    while (t + 2 <= end) {
        int type = t[0] >> 1, len = (t[0] & 1) << 8 | t[1];
        const uint8_t *v = t + 2;
        if (len > end - v)
            return 0;
        if (type == 0)
            break;
        if (type == 1)
            c = v, clen = len;
        else if (type == 2)
            p = v, plen = len;
        else if (type == 3 && len >= 2)
            ttl = v[0] << 8 | v[1];
        else if (type == 5)
            snprintf(name, sizeof name, "%.*s", len, (const char *)v);
        else if (type == 6)
            snprintf(desc, sizeof desc, "%.*s", len, (const char *)v);
        else if (type == 7 && len >= 4)
            caps = v[0] << 8 | v[1], enabled = v[2] << 8 | v[3];
        t = v + len;
    }
    if (!c || !p || clen < 2 || clen > 256 || plen < 2 || plen > 256 || ttl < 0)
        return 0;
    if (have_chassis && clen == 7 && c[0] == 4 && !memcmp(c + 1, chassis, 6))
        return 0;    // this box, heard through its other root on the same cable

    int i = 0;
    while (i < d->nnb && !(d->nb[i].chassis_len == clen && d->nb[i].port_len == plen &&
                           !memcmp(d->nb[i].chassis, c, (size_t)clen) && !memcmp(d->nb[i].port, p, (size_t)plen)))
        i++;
    if (ttl == 0) {
        if (i == d->nnb)
            return 0;
        forget(d, i, "shut down");
        return 1;
    }
    struct neighbour nb = {.chassis_len = clen, .port_len = plen, .expires = now + ttl};
    memcpy(nb.chassis, c, (size_t)clen);
    memcpy(nb.port, p, (size_t)plen);
    strcpy(nb.name, name);
    strcpy(nb.descr, desc);
    // lldpd on a Linux host lists Station even when it is off. A switch lists Bridge alone.
    nb.bridge = (caps & enabled & CAP_BRIDGE) && !(caps & CAP_STATION);
    int fresh = i == d->nnb;
    if (!fresh && !strcmp(d->nb[i].name, name) && !strcmp(d->nb[i].descr, desc) && d->nb[i].bridge == nb.bridge) {
        d->nb[i].expires = nb.expires;
        return 0;
    }
    if (fresh && d->nnb == MAX_NEIGHBOURS) {
        int k = 0;
        for (int j = 1; j < d->nnb; j++)
            if (d->nb[j].expires < d->nb[k].expires)
                k = j;
        forget(d, k, "replaced");
        i = d->nnb;
    }
    d->nb[i] = nb;
    d->nnb += fresh;
    logf_("%s: hears \"%s\", \"%s\"%s", d->name, name, desc, nb.bridge ? ", a bridge" : "");
    return fresh ? 2 : 1;
}

// The id in a `sparkos-fabric XXXX` system description.
static int peer_id(const char *s, unsigned long *id)
{
    char tag[32], hex[32], extra;
    if (sscanf(s, "%31s %31s %c", tag, hex, &extra) != 2 || strcmp(tag, TAG))
        return -1;
    return parse_hex(hex, id);
}

// IPv4 duplicate detection (RFC 5227 probe): 1 if nobody answers for IP on the netdev, 0 if someone
// does, -1 if the probe could not be sent.
static int probe_free(const struct dev *d, uint32_t ip)
{
    uint8_t f[42], r[64], addr[4] = {ip >> 24, ip >> 16 & 255, ip >> 8 & 255, ip & 255};
    int fd = socket(AF_PACKET, SOCK_RAW | SOCK_CLOEXEC, htons(ARP_ETHERTYPE));
    struct sockaddr_ll sll = {.sll_family = AF_PACKET, .sll_protocol = htons(ARP_ETHERTYPE), .sll_ifindex = d->ifindex};
    // who-has IP, from 0.0.0.0, so a probe can never update anyone's ARP cache
    memset(f, 0xff, 6);
    memcpy(f + 6, d->mac, 6);
    memcpy(f + 12, (uint8_t[]){0x08, 0x06, 0, 1, 0x08, 0, 6, 4, 0, 1}, 10);
    memcpy(f + 22, d->mac, 6);
    memset(f + 28, 0, 10);
    memcpy(f + 38, addr, 4);
    if (fd < 0 || bind(fd, (struct sockaddr *)&sll, sizeof sll) || send(fd, f, sizeof f, 0) < 0) {
        logf_("%s: ARP probe: %s", d->name, strerror(errno));
        if (fd >= 0)
            close(fd);
        return -1;
    }
    int taken = 0;
    for (double end = now_() + 1.0, left; !taken && (left = end - now_()) > 0;) {
        struct pollfd pfd = {.fd = fd, .events = POLLIN};
        if (poll(&pfd, 1, (int)(left * 1000) + 1) <= 0)
            break;
        // an ARP packet from another host claiming IP as its sender address
        ssize_t len = recv(fd, r, sizeof r, 0);
        taken = len >= 42 && memcmp(r + 22, d->mac, 6) && !memcmp(r + 28, addr, 4);
    }
    close(fd);
    return !taken;
}

// rtnetlink: one request, its replies passed to EACH, until the kernel's ack or end of dump.
static int nl_talk(struct nlmsghdr *req, void (*each)(const struct nlmsghdr *))
{
    static union {
        struct nlmsghdr h;
        char buf[65536];
    } in;
    struct sockaddr_nl kernel = {.nl_family = AF_NETLINK};
    req->nlmsg_seq = ++nl_seq;
    if (sendto(nl, req, req->nlmsg_len, 0, (struct sockaddr *)&kernel, sizeof kernel) < 0)
        return -errno;
    for (;;) {
        ssize_t n = recv(nl, in.buf, sizeof in.buf, 0);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return -errno;
        }
        for (size_t off = 0; off + sizeof(struct nlmsghdr) <= (size_t)n;) {
            const struct nlmsghdr *h = (const struct nlmsghdr *)(in.buf + off);
            if (h->nlmsg_len < sizeof *h || off + h->nlmsg_len > (size_t)n)
                break;
            off += NLMSG_ALIGN(h->nlmsg_len);
            if (h->nlmsg_seq != req->nlmsg_seq)
                continue;
            if (h->nlmsg_type == NLMSG_DONE)
                return 0;
            if (h->nlmsg_type == NLMSG_ERROR)
                return ((const struct nlmsgerr *)NLMSG_DATA(h))->error;
            if (each)
                each(h);
        }
    }
}

static void on_addr(const struct nlmsghdr *h)
{
    const struct ifaddrmsg *a = NLMSG_DATA(h);
    const char *p = (const char *)a + NLMSG_ALIGN(sizeof *a), *end = (const char *)h + h->nlmsg_len;
    uint32_t local = 0, address = 0;
    int have_local = 0, have_address = 0;
    if (h->nlmsg_type != RTM_NEWADDR || a->ifa_family != AF_INET || nhave == MAX_ADDRS)
        return;
    while (p + sizeof(struct rtattr) <= end) {
        const struct rtattr *rta = (const struct rtattr *)p;
        if (rta->rta_len < sizeof *rta || p + rta->rta_len > end)
            break;
        if (rta->rta_len >= RTA_LENGTH(4) && rta->rta_type == IFA_LOCAL)
            memcpy(&local, RTA_DATA(rta), 4), have_local = 1;
        if (rta->rta_len >= RTA_LENGTH(4) && rta->rta_type == IFA_ADDRESS)
            memcpy(&address, RTA_DATA(rta), 4), have_address = 1;
        p += RTA_ALIGN(rta->rta_len);
    }
    if (have_local || have_address)
        have[nhave++] = (struct addr){(int)a->ifa_index, ntohl(have_local ? local : address), a->ifa_prefixlen};
}

static int dump_addrs(void)
{
    struct {
        struct nlmsghdr h;
        struct ifaddrmsg a;
    } req = {
        .h = {.nlmsg_len = sizeof req, .nlmsg_type = RTM_GETADDR, .nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP},
        .a = {.ifa_family = AF_INET},
    };
    nhave = 0;
    return nl_talk(&req.h, on_addr);
}

static int change_addr(int type, const struct dev *d, uint32_t ip, int prefix)
{
    struct {
        struct nlmsghdr h;
        struct ifaddrmsg a;
        struct rtattr local_attr;
        uint32_t local;
        struct rtattr address_attr;
        uint32_t address;
    } req = {
        .h = {.nlmsg_len = sizeof req, .nlmsg_type = (uint16_t)type,
              .nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK | (type == RTM_NEWADDR ? NLM_F_CREATE | NLM_F_EXCL : 0)},
        .a = {.ifa_family = AF_INET, .ifa_prefixlen = (uint8_t)prefix, .ifa_index = (uint32_t)d->ifindex},
        .local_attr = {.rta_len = RTA_LENGTH(4), .rta_type = IFA_LOCAL},
        .local = htonl(ip),
        .address_attr = {.rta_len = RTA_LENGTH(4), .rta_type = IFA_ADDRESS},
        .address = htonl(ip),
    };
    return nl_talk(&req.h, NULL);
}

// One pass

static int managed(uint32_t ip)
{
    return in_net(ip, subnets[0]) || in_net(ip, subnets[1]) || in_net(ip, links[0]) || in_net(ip, links[1]);
}

static void step(double now)
{
    static int waiting;    // logged that there is no chassis ID yet
    scan(now);
    if (!have_chassis) {
        if (!waiting)
            logf_("no r8169 LAN port for the LLDP chassis ID, waiting");
        waiting = 1;
        return;
    }
    waiting = 0;
    char id[sizeof descr];
    me = have_fabric_id ? fabric_id : (unsigned long)chassis[4] << 8 | chassis[5];
    snprintf(id, sizeof id, TAG " %04lx", me);
    if (strcmp(id, descr)) {
        snprintf(descr, sizeof descr, "%s", id);
        logf_("id %04lx, chassis %02x:%02x:%02x:%02x:%02x:%02x", me, chassis[0], chassis[1], chassis[2], chassis[3],
              chassis[4], chassis[5]);
        for (int i = 0; i < ndevs; i++)
            devs[i].next_tx = now;
    }

    // {netdev: address} for the cabling LLDP shows now, one netdev per (root, role)
    struct want want[MAX_DEVS] = {{0}};
    struct {
        int root, kind;
        unsigned long peer;
        int dev;
    } taken[MAX_DEVS];
    int ntaken = 0;
    for (int i = 0; i < ndevs; i++) {
        struct dev *d = &devs[i];
        int kind = 0;    // 1 the switch, 2 a peer box
        unsigned long peer = 0, pid;
        d->note[0] = '\0';
        for (int j = d->nnb - 1; j >= 0; j--)
            if (d->nb[j].expires <= now)
                forget(d, j, "expired");
        if (!d->carrier)
            continue;
        for (int j = 0; j < d->nnb; j++) {
            if (!peer_id(d->nb[j].descr, &pid)) {
                if (pid != me)
                    kind = 2, peer = pid;
            } else if (fabric_switch ? !strcmp(d->nb[j].name, fabric_switch) : d->nb[j].bridge) {
                kind = 1, peer = 0;
            }
        }
        if (!kind)
            continue;
        int t = 0;
        while (t < ntaken && !(taken[t].root == d->root && taken[t].kind == kind && taken[t].peer == peer))
            t++;
        if (t < ntaken) {
            note(d, kind == 1 ? "also reaches the switch on root %d, already on %s, left bare"
                              : "also reaches the same box on root %d, already on %s, left bare",
                 d->root, devs[taken[t].dev].name);
            continue;
        }
        taken[ntaken].root = d->root;
        taken[ntaken].kind = kind;
        taken[ntaken].peer = peer;
        taken[ntaken++].dev = i;
        if (kind == 2) {
            want[i] = link_addr(links[d->root - 1], me, peer);
            continue;
        }
        struct net n = subnets[d->root - 1];
        unsigned long host = have_fabric_host ? fabric_host : me;
        char buf[24];
        if (host == 0 || host >= net_size(n) - 1) {
            note(d, "host %lu is not a host address in %s, set FABRIC_ID or FABRIC_HOST", host, ipstr(buf, n.base, n.prefix));
            continue;
        }
        want[i] = (struct want){1, n.base + (uint32_t)host, n.prefix};
    }

    int err = dump_addrs();
    if (err) {
        logf_("listing addresses: %s", strerror(-err));
        return;
    }
    // A netdev keeps its address through a carrier drop or an LLDP gap. It loses it only when LLDP
    // shows it reaching something else, or when another netdev now wants that address (the cable moved).
    for (int k = 0; k < nhave; k++) {
        const struct addr *a = &have[k];
        int i = 0, elsewhere = 0;
        while (i < ndevs && devs[i].ifindex != a->ifindex)
            i++;
        if (i == ndevs || !managed(a->ip))
            continue;
        for (int j = 0; j < ndevs; j++)
            elsewhere |= j != i && want[j].set && want[j].ip == a->ip && want[j].prefix == a->prefix;
        if (want[i].set ? want[i].ip == a->ip && want[i].prefix == a->prefix : !elsewhere)
            continue;
        char buf[24];
        if ((err = change_addr(RTM_DELADDR, &devs[i], a->ip, a->prefix)))
            logf_("%s: removing %s: %s", devs[i].name, ipstr(buf, a->ip, a->prefix), strerror(-err));
        else
            logf_("%s: removed %s", devs[i].name, ipstr(buf, a->ip, a->prefix));
    }
    for (int i = 0; i < ndevs; i++) {
        struct dev *d = &devs[i];
        int present = 0;
        char buf[24];
        if (!want[i].set)
            continue;
        for (int k = 0; k < nhave; k++)
            present |= have[k].ifindex == d->ifindex && have[k].ip == want[i].ip && have[k].prefix == want[i].prefix;
        if (present)
            continue;
        ipstr(buf, want[i].ip, want[i].prefix);
        int free_ = probe_free(d, want[i].ip);
        if (free_ <= 0) {
            if (!free_)
                note(d, "%s is already in use on this link, not added", buf);
            continue;
        }
        if ((err = change_addr(RTM_NEWADDR, d, want[i].ip, want[i].prefix)))
            logf_("%s: adding %s: %s", d->name, buf, strerror(-err));
        else
            logf_("%s: added %s", d->name, buf);
    }
    for (int i = 0; i < ndevs; i++) {
        struct dev *d = &devs[i];
        if (strcmp(d->note, d->noted)) {
            if (d->note[0])
                logf_("%s: %s", d->name, d->note);
            strcpy(d->noted, d->note);
        }
    }
}

int main(void)
{
    // Both ends of a direct cable must pick the same /31, so the placement has to match
    // kindling-spark-os's: link_addr(10.110.0.0/16, 0x9722, 0x1234) there is 10.110.43.75/31.
    struct net check = {0x0a6e0000, 16};
    if (link_addr(check, 0x9722, 0x1234).ip != 0x0a6e2b4b || link_addr(check, 0x1234, 0x9722).ip != 0x0a6e2b4a) {
        logf_("the /31 placement differs from kindling-spark-os's");
        return 1;
    }
    if (configure())
        return 2;
    ctl = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    nl = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);
    if (ctl < 0 || nl < 0) {
        logf_("sockets: %s", strerror(errno));
        return 1;
    }

    static uint8_t frame[9216];
    double next_step = 0;
    for (;;) {
        double now = now_();
        if (now >= next_step) {
            step(now);
            now = now_();
            next_step = now + STEP;
        }
        double wake = next_step;
        struct pollfd pfd[MAX_DEVS];
        for (int i = 0; i < ndevs; i++) {
            struct dev *d = &devs[i];
            pfd[i] = (struct pollfd){.fd = d->fd, .events = POLLIN};
            if (d->fd < 0 || !d->carrier || !descr[0])
                continue;
            if (d->next_tx <= now)
                send_lldp(d, now);
            if (d->next_tx < wake)
                wake = d->next_tx;
        }
        int ms = (int)((wake - now) * 1000) + 1;
        if (poll(pfd, (nfds_t)ndevs, ms < 0 ? 0 : ms) < 0 && errno != EINTR) {
            logf_("poll: %s", strerror(errno));
            return 1;
        }
        now = now_();
        for (int i = 0; i < ndevs; i++) {
            struct sockaddr_ll from;
            socklen_t fromlen = sizeof from;
            ssize_t n;
            if (!(pfd[i].revents & POLLIN))
                continue;
            while ((n = recvfrom(devs[i].fd, frame, sizeof frame, 0, (struct sockaddr *)&from, &fromlen)) >= 0) {
                fromlen = sizeof from;
                if (from.sll_pkttype == PACKET_OUTGOING)
                    continue;
                int r = receive(&devs[i], frame, (size_t)n, now);
                if (r)
                    next_step = now;    // replan now rather than at the next pass
                if (r == 2)
                    devs[i].next_tx = now;    // a new neighbour hears this box at once
            }
        }
    }
}
