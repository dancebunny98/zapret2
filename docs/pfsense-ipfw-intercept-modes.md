# pfSense IPFW intercept modes for zapret2

File: `/usr/local/etc/zapret2/pfsense.conf`

## Mode 1: `minimal` (recommended)

Lower CPU load. Intercepts:

- outbound TCP/UDP target ports
- inbound TCP only for `SYN+ACK`, `FIN`, `RST`

```sh
IPFW_INTERCEPT_MODE=minimal
IFACE_WAN=vmx0
PORTS_TCP=80,443
PORTS_UDP=443
DIVERT_PORT=990
RULE_BASE=100
```

## Mode 2: `combo`

Balanced mode. Intercepts:

- outbound TCP/UDP target ports
- inbound TCP only for `SYN+ACK`, `FIN`, `RST`
- full inbound UDP on target ports

```sh
IPFW_INTERCEPT_MODE=combo
IFACE_WAN=vmx0
PORTS_TCP=80,443
PORTS_UDP=443
DIVERT_PORT=990
RULE_BASE=100
```

## Mode 3: `full`

Higher CPU load. Intercepts:

- outbound TCP/UDP target ports
- full inbound TCP and UDP flows on target ports

```sh
IPFW_INTERCEPT_MODE=full
IFACE_WAN=vmx0
PORTS_TCP=80,443
PORTS_UDP=443
DIVERT_PORT=990
RULE_BASE=100
```

## Apply changes

```sh
/usr/local/etc/rc.d/zapret2.sh restart
/usr/local/etc/rc.d/zapret2.sh status
```

`status` prints active mode and current divert rules.
