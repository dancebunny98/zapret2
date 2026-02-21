# pfSense: Routing selected domains/IP via WireGuard OPT4

This setup uses one editable list and generates a pfSense alias list for policy routing through `OPT4` (WireGuard).

## 1) Prepare unified list

Create the file on pfSense:

`/usr/local/etc/zapret2/ipset/vpn-opt4.list`

Use one item per line:

- domain: `modrinth.com`
- IPv4/IPv6: `104.26.12.34`
- CIDR: `104.26.12.0/24`

Example:

```txt
modrinth.com
api.modrinth.com
104.26.12.0/24
```

Notes:

- `modrinth.com` in this list means root domain.
- Subdomains are expanded automatically through `crt.sh` in the generator script.

## 2) Build alias list from the unified list

Run:

```sh
cd /usr/local/etc/zapret2
sh ipset/build_vpn_opt4_list.sh \
  ipset/vpn-opt4.list \
  /usr/local/www/vpn-opt4-alias.txt \
  ipset/vpn-opt4-hosts.txt
```

Result files:

- `/usr/local/www/vpn-opt4-alias.txt` - IP/CIDR list for pfSense URL Table alias
- `ipset/vpn-opt4-hosts.txt` - resolved domain/subdomain inventory (for audit)

## 3) Create pfSense Alias

In pfSense Web UI:

`Firewall -> Aliases -> Add`

- Type: `URL Table (IPs)`
- Name: `VPN_OPT4_TARGETS`
- URL: `http://127.0.0.1/vpn-opt4-alias.txt`
- Update Frequency: `1` day (or lower if needed)

Save and Apply.

## 4) Create policy routing rule to WireGuard gateway

In pfSense Web UI:

`Firewall -> Rules -> LAN` (or source interface)

Create rule near top:

- Action: `Pass`
- Protocol: `Any`
- Source: your LAN net
- Destination: `Single host or alias` -> `VPN_OPT4_TARGETS`
- Advanced -> Gateway: select your WireGuard gateway on `OPT4`

Save and Apply.

## 5) Auto-update list

Create cron task (package `cron`):

```sh
cd /usr/local/etc/zapret2 && sh ipset/build_vpn_opt4_list.sh ipset/vpn-opt4.list /usr/local/www/vpn-opt4-alias.txt ipset/vpn-opt4-hosts.txt
```

Recommended schedule: every 30-60 minutes.

## 6) Add new domain (example modrinth.com)

1. Add line to `/usr/local/etc/zapret2/ipset/vpn-opt4.list`:
   `modrinth.com`
2. Rebuild list:
   `sh /usr/local/etc/zapret2/ipset/build_vpn_opt4_list.sh /usr/local/etc/zapret2/ipset/vpn-opt4.list /usr/local/www/vpn-opt4-alias.txt /usr/local/etc/zapret2/ipset/vpn-opt4-hosts.txt`
3. In pfSense Aliases click `Reload` for `VPN_OPT4_TARGETS`.

After that, IPs of root domain + discovered subdomains + manual IP/CIDR entries are routed via `OPT4/WireGuard`.
