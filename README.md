# mwan4

## Runtime Diagnostics

`mwan4 status`, `mwan4 diagnostics`, and `ubus call mwan4 status` report runtime warnings when mwan4 is configured but not active. The diagnostic checks for enabled interfaces, running service instances, health tracker processes, loaded nftables chains, and tunnel underlay warnings.

If mwan4 is configured but the service is inactive, trackers are missing, or nftables chains are absent, the status output includes warning-specific checks plus an ordered "what should I check next?" flow. The usual safe recovery action is:

```sh
/etc/init.d/mwan4 restart
mwan4 status
nft list table inet fw4
```

Use `ubus call mwan4 diagnostics '{"section":"counters"}'` or the LuCI Diagnostics / Counters view to check whether policy, strategy, and interface counters increase when matching traffic is sent.

The diagnostic only reports state. It does not change configuration, start services, or modify nftables by itself.

OpenWrt package for the nftables-based `mwan4` service.

## Rules

`config rule` sections are evaluated top to bottom in `/etc/config/mwan4` (first match wins). The generated `default_rule_v4` / `default_rule_v6` catch-alls always run last, wherever they sit in the file.

| Option | Meaning |
| --- | --- |
| `enabled` | `0` skips the rule (default `1`). |
| `label` | Free-text display name; section names stay `[A-Za-z0-9_]`, up to 15 characters. |
| `proto`, `src_port`, `dest_port`, `src_iface`, `sticky`, `timeout`, `logging`, `family` | As before. Ports need `tcp` or `udp`. |
| `src_ip`, `dest_ip` | Lists of IPs/CIDRs. Each family only emits the entries valid for it; a rule whose list has nothing for a family does not apply to that family. |
| `src_mac` | List of MAC addresses (`ether saddr`). |
| `dscp` | `1`-`63` (`ip dscp` / `ip6 dscp`). |
| `domain` | List of domain names (subdomains match). dnsmasq fills the per-rule sets `mwan4_dom_<rule>_ipv4` / `_ipv6`. |
| `local` | `1` also applies the rule to router-originated traffic (default `0`: forwarded traffic only). The `default_rule_*` catch-alls always apply to both. |
| `ipset` | Compatibility nft set name. Rules limited to one family use the name as is; dual-family rules use `<name>` for IPv4 and `<name>_ipv6` for IPv6. |
| `use_strategy` | Strategy, or `default` / `unreachable` / `blackhole`. |

All options of a rule must match (AND). `rpc validate` reports every invalid value; invalid list entries are never emitted into nftables.

Upgrade note: router-originated traffic used to traverse every rule. It now only traverses rules with `local '1'` plus the generated catch-alls, matching pbr's prerouting/output split.

### Domain rules and dnsmasq

mwan4 writes one file, `mwan4.conf`, into the conf-dir of every dnsmasq instance (`option confdir` of `config dnsmasq`, default `/tmp/dnsmasq.<instance>.d`) with `nftset=/dom1/dom2/4#inet#fw4#<set4>,6#inet#fw4#<set6>` lines. Domains shared by several rules are merged onto one line (dnsmasq only honours the first `nftset` line of a domain). dnsmasq is restarted only when the file changed; without domain rules the file is removed. After every successful nft reload (service start, reload, interface hotplug) mwan4 resolves each domain in the background through `127.0.0.1` so the sets fill without waiting for clients.

Domain rules need `dnsmasq-full` (nftset support, `SUGGESTS` in the package). Without it mwan4 never writes the file (dnsmasq would refuse to start), `ubus call mwan4 capabilities` reports `domains.dnsmasq_nftset: false`, and `validate` warns with `dnsmasqNftsetMissing`.

### Tunnel interfaces

An `interface` with `option type 'tunnel'` or `option default_route '1'` gets `default dev <device>` in its mwan4 table (per `family`), and its health checks are sent through the device with its own mark. This works for tunnels without a netifd default route (for example WireGuard with `defaultroute '0'`). A strategy that only contains such an interface with `last_resort 'unreachable'` fails closed: an IPv4-only tunnel has no IPv6 route, so IPv6 traffic is unreachable instead of leaking.

## Importing pbr policies

`ubus call mwan4 pbr_import '{"apply":false}'` previews, `'{"apply":true}'` writes the conversion of `/etc/config/pbr` into `/etc/config/mwan4`. `/etc/config/pbr` is never modified and pbr is not stopped.

Result:

```json
{
  "ok": true, "applied": false,
  "policies": [{ "pbr_section": "cfg...", "name": "youtube", "enabled": true, "action": "import",
                 "reason": "", "target": "wan_tim", "strategy": "tim_first",
                 "rule": "youtube", "rules": ["youtube"], "summary": "domain=youtube.com -> tim_first" }],
  "interfaces": ["wg_wan"], "strategies": ["tim_first", "wg_wan_only"],
  "warnings": ["dns_policy 'use' is not supported by mwan4"]
}
```

- `dest_addr` / `src_addr` tokens become `dest_ip` / `src_ip` (IPv4, IPv6, CIDR), `src_mac`, `src_iface` (`@iface` or a netifd interface name) or `domain` (anything hostname-like). Whitespace and duplicate tokens are dropped; domains are lower-cased. A policy mixing kinds becomes one rule per kind (`name_1`, `name_2`...) because the options of a rule are ANDed. `proto` lists (`tcp udp icmp`) and policies with ports but no protocol (pbr default `tcp udp`) become one rule per protocol. `chain output` sets `local '1'`.
- Disabled policies are imported with `enabled '0'`. Rules keep pbr order and are placed before the default catch-alls. Rule names are derived from the policy name (at most 11 characters plus a numeric suffix) and made unique; `label` keeps the full name.
- A plain WAN interface of mwan4 maps to the strategy `<wan>_first` (WAN name without `wan_`): that WAN and its IPv6 sibling (`<wan>6`) first, the other enabled WANs after it in their current route metric order, `last_resort 'unreachable'`. A netifd tunnel (`wireguard`, `gre`, ...) that is neither ignored nor unsupported in pbr gets an mwan4 `interface` (`type tunnel`, `default_route 1`, next free id/table/mark, `track_ip` from the tunnel dns or peer host address, families from its addresses; enabled only when an enabled policy uses it) and the fail-closed strategy `<tunnel>_only`. `interface 'ignore'` maps to `default` and `mwan4_strategy_<name>` to that strategy.
- Policies that cannot be mapped (unknown, ignored or unsupported interface, negated or unrecognised addresses, invalid ports/protocols, matching everything) are returned with `action: "skip"` and a `reason`. `dns_policy` and `include` sections and `*_dscp` options are returned in `warnings`.
- Applying saves the previous config to `/etc/config/mwan4.pre-pbr-import`. Rules, routes and strategies created by an import carry `option pbr_import '1'` and are replaced by the next import, so re-running never duplicates anything (remove the marker from anything edited by hand to keep it); tunnel interfaces are created once and kept.

## Packaging Notes

- `CONFLICTS:=mwan3 luci-app-mwan3` remains the OpenWrt source-level conflict declaration. The current OpenWrt 25 SDK APK backend used here does not emit conflict metadata as a separate `Conflicts` APK field, so the local build maps `CONFLICTS` to APK-native negative dependencies (`!mwan3`, `!luci-app-mwan3`) to make `apk` reject co-installation. Remove `mwan3` and `luci-app-mwan3` before installing mwan4 on existing systems.
- Optional probe helpers `iputils-arping`, `httping`, and `nping`, and `dnsmasq-full` (needed for domain rules), are listed as `SUGGESTS`. They are not published in this local repo; install them from the normal OpenWrt feeds when those health checks are needed.
- The local repo intentionally publishes only first-party APKs. Runtime dependencies should continue to resolve from the standard OpenWrt feeds.
