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

## Packaging Notes

- `CONFLICTS:=mwan3 luci-app-mwan3` remains the OpenWrt source-level conflict declaration. The current OpenWrt 25 SDK APK backend used here does not emit conflict metadata as a separate `Conflicts` APK field, so the local build maps `CONFLICTS` to APK-native negative dependencies (`!mwan3`, `!luci-app-mwan3`) to make `apk` reject co-installation. Remove `mwan3` and `luci-app-mwan3` before installing mwan4 on existing systems.
- Optional probe helpers `iputils-arping`, `httping`, and `nping` are listed as `SUGGESTS`. They are not published in this local repo; install them from the normal OpenWrt feeds when those health checks are needed.
- The local repo intentionally publishes only first-party APKs. Runtime dependencies should continue to resolve from the standard OpenWrt feeds.
