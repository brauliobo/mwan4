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
| `rule_id` | Managed by mwan4, see [Connection counting](#connection-counting). Do not edit. |

All options of a rule must match (AND). `rpc validate` reports every invalid value; invalid list entries are never emitted into nftables.

Upgrade note: router-originated traffic used to traverse every rule. It now only traverses rules with `local '1'` plus the generated catch-alls, matching pbr's prerouting/output split.

### Domain rules and dnsmasq

mwan4 writes one file, `mwan4.conf`, into the conf-dir of every dnsmasq instance (`option confdir` of `config dnsmasq`, default `/tmp/dnsmasq.<instance>.d`) with `nftset=/dom1/dom2/4#inet#fw4#<set4>,6#inet#fw4#<set6>` lines. Domains shared by several rules are merged onto one line (dnsmasq only honours the first `nftset` line of a domain). dnsmasq is restarted only when the file changed; without domain rules the file is removed. Every fw4 reload (service start, reload, interface hotplug) empties the domain sets, so after each successful one mwan4 resolves every domain through `127.0.0.1` so the sets fill without waiting for clients. The job is skipped while no WAN is online (DNS is dead; the `connected` reload of the recovering WAN refills the sets), runs detached with the hotplug lock fd closed (a stalled lookup cannot delay later hotplug events), is single-flight (`flock` on `/var/run/mwan4/prefetch.lock`) and stops starting lookups after 60 seconds.

Domain rules need `dnsmasq-full` (nftset support, `SUGGESTS` in the package). Without it mwan4 never writes the file (dnsmasq would refuse to start), `ubus call mwan4 capabilities` reports `domains.dnsmasq_nftset: false`, and `validate` warns with `dnsmasqNftsetMissing`.

### Tunnel interfaces

An `interface` with `option type 'tunnel'` or `option default_route '1'` gets `default dev <device>` in its mwan4 table (per `family`), and its health checks are sent through the device with its own mark. This works for tunnels without a netifd default route (for example WireGuard with `defaultroute '0'`). A strategy that only contains such an interface with `last_resort 'unreachable'` fails closed: an IPv4-only tunnel has no IPv6 route, so IPv6 traffic is unreachable instead of leaking.

### Connection counting

Every rule counts the connections it routes, and the active connections can be attributed to rule, WAN and strategy.

- **New connections** (`new_connections`): an nft counter `mwan4_counter_conn_<rule>_<family>` next to each rule counts `ct state new` matches. It is cumulative since the ruleset was loaded and is cleared by `reset_counters`. Forwarded and `local` traffic of a rule share one counter per family.
- **Active connections** (`active_connections`): the entries in the conntrack table, grouped by the rule and WAN recorded in their conntrack mark. Only connections carrying mwan4 WAN bits are counted; connections that mwan4 never saw (for example LAN to LAN) and connections made before mwan4 was loaded are ignored or fall under the catch-all.

When a rule matches it records its `rule_id` in the conntrack mark with constant same-register operations (`ct mark set ct mark & <~rule_mask> | <id bits>`). The WAN bits (`mmx_mask`) and every other owner's bits are untouched, mwan4 never copies the whole packet mark into the conntrack mark. The `default_rule_*` catch-alls clear the rule bits, so their connections have id 0 and show up as the catch-all (`rule` is empty in `connections`).

| Global option | Meaning |
| --- | --- |
| `rule_mask` | Conntrack mark bits that hold the rule id (default `0x00fc0000`: six bits, 63 rule ids). Must not overlap `mmx_mask`; an overlapping or invalid mask disables the rule bits (`validate` reports `ruleMaskOverlap` / `invalidRuleMask`), counters keep working. The mask may be non-contiguous. |

Default mask rationale: the default layouts of the other mark users cover all 32 bits (mwan4 `0x00003f00`, Tomato QoS class `0x000000ff`, DPI `0x0000c000` and rule `0xff000000`, pbr `0x00ff0000`). pbr is the only owner that never reads or writes conntrack marks (its marks live on the packet only and use the low bits of its mask first), so `rule_mask` takes the upper bits 18-23 of the pbr range. It cannot collide with mwan4 or Tomato QoS in either mark. The only way it can reach pbr is a router that runs pbr and Tomato QoS at the same time, because Tomato copies the whole conntrack mark into the packet mark; `validate` warns (`ruleMaskSharedMarks`) when `rule_mask` overlaps the masks of an enabled pbr or tomato-qos, and `rule_mask` can be moved to any bits those do not use.

`rule_id` is a persisted option of `config rule` sections: unique, `1` to the capacity of `rule_mask` (63 by default). mwan4 assigns the lowest free id to every rule that lacks a valid, unique one when the service starts or reloads and when `pbr_import` is applied (re-imported rules keep their id). Ids never change while the section exists, so reordering or editing rules keeps live connections attributed correctly; deleting a rule frees its id, and its remaining connections count under the catch-all. `validate` and `diagnostics connections` warn when the rules do not fit (`ruleIdCapacity`) or an id is invalid or duplicated (`invalidRuleId`, `duplicateRuleId`). A rule without an id is not attributed. The first start after an upgrade writes the ids into `/etc/config/mwan4`, so procd may run one extra reload.

The table is read in a single pass over `/proc/net/nf_conntrack` (no extra package) and the counts are cached for two seconds inside rpcd, so concurrent status polls share one scan.

#### Status fields

`ubus call mwan4 status` (also `{"section":"rules"}` for the rules alone) gains these fields; the existing ones are unchanged. Every `{ipv4, ipv6, total}` object has that shape.

```json
{
  "rules": {
    "youtube": {
      "id": 7, "label": "youtube", "enabled": true, "strategy": "tim_first",
      "new_connections":    { "ipv4": 12, "ipv6": 5, "total": 17 },
      "active_connections": { "ipv4": 3,  "ipv6": 0, "total": 3 }
    },
    "default_rule_v4": { "id": 0, "label": "default_rule_v4", "enabled": true, "strategy": "failover",
      "new_connections": { "ipv4": 40, "ipv6": 0, "total": 40 }, "active_connections": { "ipv4": 4, "ipv6": 0, "total": 4 } }
  },
  "interfaces": { "wan": { "...": "...", "active_connections": { "ipv4": 4, "ipv6": 0, "total": 4 } } },
  "strategy_status": { "ipv4": { "failover": { "...": "...", "active_connections": 5 } } }
}
```

- `rules.<name>` covers every rule including the catch-alls (`id` 0). The catch-alls also own connections whose rule id no rule claims.
- `interfaces.<name>.active_connections` counts the connections routed through that WAN (all rules); `diagnostics interfaces` shows the same under `runtime`.
- `strategy_status.<family>.<strategy>.active_connections` is a number for that family: the sum over the rules (and catch-alls) that use the strategy. The other strategy fields are unchanged.
- `ubus call mwan4 diagnostics '{"section":"counters"}'` adds `new_connections` / `active_connections` to `groups.rules.<name>` and a `connections` count to `summary` (connection counters are excluded from the packet and byte totals). `{"section":"connections"}` returns `accounting`, `rule_mask`, `rule_capacity`, `total`, `rules`, `interfaces`, `strategies`, `errors` and `warnings`. `{"section":"explain"}` rule entries gain `rule_id`, `new_connections` and `active_connections`.
- `capabilities.connections` reports `rule_mask`, `rule_capacity`, `limit_default`, `limit_max` and the supported `filters`.

#### `connections` RPC

`ubus call mwan4 connections '{"rule":"youtube","limit":50}'` lists the tracked connections (only those with mwan4 WAN bits).

| Argument | Meaning |
| --- | --- |
| `rule` | Rule section name; a catch-all name selects the connections without rule bits of its family. |
| `interface` | WAN interface name, or `default` / `blackhole` / `unreachable`. |
| `strategy` | Strategy name (`use_strategy` of the owning rule or catch-all). |
| `family`, `proto` | `ipv4` / `ipv6`; conntrack protocol name (`tcp`, `udp`, `icmp`, ...). |
| `search` | Case-insensitive substring over family, protocol, addresses, ports (also `addr:port`), state, rule, label, WAN and strategy. |
| `limit`, `offset` | Page size (default 200, clamped to 1-1000) and start index. |

All filters combine with AND. The result is sorted by bytes (conntrack accounting, `nf_conntrack_acct=1`) descending, then by the longest remaining timeout, so with accounting off it is the most recently active first.

```json
{
  "ok": true, "total": 3, "truncated": false, "accounting": true,
  "items": [
    { "family": "ipv4", "proto": "tcp", "src": "10.0.0.7", "sport": 44602, "dst": "205.237.105.139", "dport": 8080,
      "state": "ESTABLISHED", "timeout": 7439, "packets": 6954, "bytes": 4595854,
      "rule": "torrent", "rule_label": "BitTorrent", "interface": "wan", "strategy": "backup" }
  ]
}
```

`total` is the number of matching connections before paging and `truncated` is true when more than `offset + limit` match. `sport` / `dport` are `null` for protocols without ports, `state` is empty for stateless protocols, `packets` and `bytes` sum both directions and are `0` without accounting, IPv6 addresses are shortened, `rule` and `rule_label` are empty for connections that only matched a catch-all, and `strategy` is the strategy of the owning rule or catch-all.

CLI: `mwan4 rules` appends the rule id, active and new connections to each rule, `mwan4 interfaces` and `mwan4 strategies` show the active connection counts, and `mwan4 connections [rule=<name>] [interface=<wan>] [strategy=<name>] [family=ipv4|ipv6] [proto=<proto>] [search=<text>] [limit=<n>] [offset=<n>]` prints the list.

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
