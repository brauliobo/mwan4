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

## Unstable WAN handling

A flaky WAN used to flap between online and offline every few seconds, each flap reloading the firewall and flushing every flow on that WAN, and a recovered preferred WAN pulled traffic back at once. These options keep such a link from disturbing the others. All of them live in `config globals` as defaults and can be overridden in an `interface` section with the same name; legacy behaviour is `flap_damping '0'`, `recovery_hold '0'` and `flush_grace '0'`.

| Option | Default | Meaning |
| --- | --- | --- |
| `flap_damping` | `1` | Hold a link out of the strategies while it flaps. |
| `flap_threshold` | `3` | Online to offline transitions inside `flap_window` that count as flapping (at least 2). |
| `flap_window` | `300` | Seconds the flaps are counted over (at least 30). |
| `flap_holddown` | `120` | Seconds a flapping link must stay healthy before it rejoins. |
| `recovery_hold` | `30` | Seconds a recovered link must stay healthy before it rejoins; `0` disables. |
| `flush_grace` | `10` | Seconds an offline WAN keeps its established flows (see below); `0` flushes at once. |
| `quality_hold` | `30` | Seconds a degraded link must stay under 80% of the limits before it is used again. |
| strategy `max_latency` | unset | Milliseconds; links measured slower are skipped by that strategy. |
| strategy `max_loss` | unset | Percent (0-100); links losing more are skipped by that strategy. |

Invalid values are reported by `validate` and ignored at runtime (the global, then the default, applies).

- **Holds.** A link that is held stays `online` for the tracker but is left out of the strategies (`health_state` `held`, reason `flapping` or `recovering`). The hold only starts for a recovery (offline to online) after mwan4 is running: a link that is healthy when mwan4 starts or restarts joins at once, and so does one that is validated for the first time after `initial_state 'offline'`. A failure during a hold drops it, and the next recovery starts a new one. Established connections are never moved by a failback, only new ones follow. Flapping outranks the recovery hold.
- **Last usable link.** Holds and quality skips never empty a strategy: when every online route of a strategy is held the holds are lifted for it, and when every candidate is degraded the least bad one stays. Strategies are only rebuilt when the set really changes.
- **Selective flush.** The `flush_conntrack` triggers (`ifup`, `ifdown`, `connected`, `disconnected`) no longer drop every flow of the WAN at once. Flows without a reply (`conntrack -D -m <mark>/<mask> -u UNSET`, TCP `SYN_SENT` and `SYN_RECV`) go immediately; after `flush_grace` seconds a detached job (it does not hold the hotplug lock) deletes the remaining flows of that WAN only if it is still offline. A recovery cancels the job, a repeated trigger only moves its deadline.
- **Quality steering.** With `option check_quality '1'` on the interface the tracker keeps a moving average of the last three checks (latency over the probes that answered, loss over all probes). A strategy with `max_latency` or `max_loss` skips a link whose average is above a limit (`degraded_for` in the status, the link stays `online` for every other strategy) and takes it back after `quality_hold` seconds below 80% of the limits. Loss is only fine grained with `count` above 1 per check. `validate` warns with `qualityNeedsCheckQuality` when a limit is set over a link without `check_quality`.
- **Probes.** The default config tracks two targets per interface (`1.1.1.1`, `8.8.8.8` and their IPv6 counterparts) with `reliability '1'`: the link is up while any target answers, so one lost probe or one dead target no longer flaps it. `validate` warns with `singleTrackTarget` for an enabled interface with a single `track_ip`.

Worked example, an unstable DSL primary with LTE as backup:

```
config globals 'globals'
	option flap_threshold '3'
	option flap_window '600'
	option flap_holddown '300'
	option recovery_hold '60'

config interface 'dsl'
	option enabled '1'
	list track_ip '1.1.1.1'
	list track_ip '8.8.8.8'
	option reliability '1'
	option count '3'
	option check_quality '1'
	list flush_conntrack 'disconnected'

config route 'dsl_m1'
	option interface 'dsl'
	option metric '1'

config route 'lte_m2'
	option interface 'lte'
	option metric '2'

config strategy 'voice'
	list use_route 'dsl_m1'
	list use_route 'lte_m2'
	option max_latency '150'
	option max_loss '3'
```

DSL that drops three times in ten minutes is held out for five minutes of stable operation, a DSL that is back after one outage waits 60 seconds before new connections use it again, and calls started through `voice` leave DSL while it measures above 150 ms or 3% loss. When DSL goes offline its dead flows go at once and its remaining ones after 10 seconds, unless it comes back first.

### Status and history

`ubus call mwan4 status '{"section":"interfaces"}'` adds to every interface:

```json
{
  "health_state": "held",
  "flaps": { "count_window": 3, "total": 7 },
  "availability": { "pct_1h": 91.7, "pct_24h": 98.2 },
  "held": { "active": true, "reason": "flapping", "until": 1793188400, "remaining": 87 },
  "degraded_for": ["voice"]
}
```

`flaps.total` and `availability` come from the transition log, `/var/run/mwan4/history/<iface>` (one `epoch state reason` line per event, the last 200 kept, replaced atomically; it survives `mwan4 reload`/`restart` but not a reboot). States are `online` (`start`, `recovered`), `offline` (`probe`, `ifdown`), `held` (`flapping`, `recovering`), `released`, `degraded` (strategy names) and `restored`; availability counts `held` as up. `ubus call mwan4 link_history '{"interface":"wan","since":1793180000,"limit":50}'` (all arguments optional, `limit` at most 200) returns the events oldest first:

```json
{ "ok": true, "interfaces": { "wan": {
  "events": [{ "time": 1793188300, "state": "offline", "reason": "probe" },
             { "time": 1793188313, "state": "online", "reason": "recovered" },
             { "time": 1793188313, "state": "held", "reason": "flapping" }],
  "flaps": { "count_window": 3, "total": 7 },
  "availability": { "pct_1h": 91.7, "pct_24h": 98.2 },
  "held": { "active": true, "reason": "flapping", "until": 1793188400, "remaining": 87 },
  "degraded_for": [] } } }
```

`capabilities` reports `stability.link_history` and the built-in defaults. CLI: `mwan4 history [iface]` prints the events, `mwan4 interfaces` appends hold, degradation, flap and availability notes.

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

### Fallback marks and conntrack

While every route of a strategy is offline its chain falls back per packet: `oifname` rules send traffic whose main-table route already leaves through one of the offline links to the main table (`default` mark, so health probes and handshakes can still use that link; they never move traffic to another interface), and everything else gets the `last_resort` mark (`unreachable`, `blackhole` or `default`). These marks are not saved in the conntrack mark. Only WAN marks are saved by the shared tail of `mwan4_prerouting`/`mwan4_output`; the lasting `default` marks (destination or source in the `connected`/`custom`/`dynamic` sets, a rule with `use_strategy 'default'`, `'unreachable'` or `'blackhole'`) save themselves where they are assigned. A flow that keeps itself alive during an outage (WireGuard keepalives, DNS retries) is therefore evaluated again on its next packet and leaves through the recovered WAN instead of staying on the dead link. Flows already pinned by an earlier release stay pinned until they expire or are flushed (`conntrack -D --mark 0x3f00/0x3f00`).

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
