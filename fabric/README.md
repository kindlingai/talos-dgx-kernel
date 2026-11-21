# sparkos-fabric

`sparkos-fabric` gives every ConnectX netdev the fabric address of whatever its cable reaches,
with no per-box setup. It is the C form of the
[kindling-spark-os](https://github.com/kindlingai/kindling-spark-os) `sparkos-fabric` daemon, and
works out the same addresses, so a Talos box and a kindling-spark-os box agree over a direct cable.
It runs as the `sparkos-fabric` Talos extension service from the `sparkos-fabric` system extension,
which every installer includes. The service stays off until a node's machine config turns it on.

Each physical ConnectX port shows up as one netdev per PCI root. Every netdev gets an address on its
own root's subnet, so one cable carries both roots:

| The cable reaches | Root 1 | Root 2 |
|---|---|---|
| the switch | `10.100.H.L/16` | `10.101.H.L/16` |
| another box running `sparkos-fabric` | a `/31` in `10.110.0.0/16` | a `/31` in `10.111.0.0/16` |

`H.L` is the box's id: the last two bytes of its LAN port's (`r8169`) MAC, the same digits as a
`gx10-XXXX` name, so `gx10-9722` is `10.100.151.34`. A direct cable's `/31` is placed by a hash of
the two ids, so both ends work out the same subnet, and the lower id takes the even address.

## How it works

- Talos has no lldpd, so `sparkos-fabric` sends and receives LLDP on the ConnectX netdevs itself.
  It advertises the LAN port's MAC as its chassis ID, `sparkos-fabric XXXX` (its id) as its system
  description, and the Station capability. It sends every 30 seconds with a 120-second TTL, and at
  once when a port gains carrier or hears a new neighbour.
- A neighbour advertising `sparkos-fabric XXXX` is a peer box. A neighbour that advertises bridging,
  and not the Station capability every Linux lldpd lists, is the switch. A box that runs neither
  daemon gets no address on a direct cable to it.
- An address goes on only after an ARP probe (RFC 5227) finds nobody using it. A netdev keeps its
  address through a carrier drop. It loses it when LLDP shows the cable reaching something else, or
  when another netdev now wants that address. Addresses outside the fabric subnets are left alone.
- It brings the ConnectX netdevs up and sets their MTU (9000 by default).

## Turning it on

Add an `ExtensionServiceConfig` named `sparkos-fabric` to the node's machine config. Talos requires
at least one entry, so set any of the overrides below, even to its default:

```yaml
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: sparkos-fabric
environment:
  - FABRIC_MTU=9000
```

| Variable | Default | Meaning |
|---|---|---|
| `FABRIC_ID` | LAN port MAC | the id, in hex, such as `9722` |
| `FABRIC_HOST` | the id | host number on the switch subnets instead of the id |
| `FABRIC_SUBNETS` | `10.100.0.0/16 10.101.0.0/16` | switch subnets, root 1 then root 2 |
| `FABRIC_LINK_SUBNETS` | `10.110.0.0/16 10.111.0.0/16` | ranges the per-link `/31`s come from, root 1 then root 2 |
| `FABRIC_SWITCH` | any bridge | the switch's LLDP system name |
| `FABRIC_MTU` | `9000` | MTU for every ConnectX netdev |

An invalid value stops the service with a log line naming it.

Talos brings up and runs DHCP on every physical link its machine config does not mention. Keep it
off the ConnectX ports, as kindling-spark-os keeps NetworkManager off them, by listing them without
addresses. Leave `mtu` unset here, or equal to `FABRIC_MTU`, so the two do not fight over it:

```yaml
machine:
  network:
    interfaces:
      - deviceSelector:
          driver: mlx5_core
```

Talos sees the fabric addresses like any other. Pin Kubernetes to the LAN so the kubelet and etcd do
not pick one, using the LAN's subnet:

```yaml
machine:
  kubelet:
    nodeIP:
      validSubnets:
        - 192.168.1.0/24
cluster:
  etcd:
    advertisedSubnets:
      - 192.168.1.0/24
```

## Checking it

```sh
talosctl --nodes <node> service ext-sparkos-fabric
talosctl --nodes <node> logs ext-sparkos-fabric   # "enp1s0f0np0: hears ...", "enp1s0f0np0: added 10.100.151.34/16"
talosctl --nodes <node> get addresses
```

The log names every neighbour each netdev hears or loses, and every address it adds or removes.

## Differences from the kindling-spark-os daemon

- It speaks LLDP itself rather than through lldpd, so there is no `lldpctl`; the log shows what each
  port hears. There is no `--dry-run`.
- The id comes from the LAN port's (`r8169`) MAC, which kindling-spark-os's lldpd advertises as the
  chassis ID. Without an `r8169` netdev it waits, even with `FABRIC_ID` set.
- Overrides come from the `ExtensionServiceConfig` environment rather than `/etc/spark/fabric.conf`.

## License

AGPL-3.0 (`LICENSE`), as kindling-spark-os.
