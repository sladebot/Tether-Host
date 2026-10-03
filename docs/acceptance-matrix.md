# Release acceptance matrix

Automated checks are necessary but do not replace these live checks. Record the
commit, host/guest OS versions, installer version, observed result and sanitized
evidence for each run. A blank row is unverified, not a pass. Use disposable guest
data and a test tailnet; never record tokens or screenshots containing credentials.

| Scenario | Required result | Current evidence |
| --- | --- | --- |
| Fresh Apple-silicon Mac and clean guest | Install from IPSW, complete guest setup, then test authenticated connection from a physical iPhone | Pending live run |
| Concurrent lifecycle actions | Repeated Start and attempted deletion during startup produce one VM instance and preserve the disk | Automated coordinator regression; live UI run pending |
| Installer media replacement fails | Previous image is preserved; existing guest can boot; status explains unavailable setup media | Automated media regression; live fault injection pending |
| Model returns incorrect completion | Retry creates a fresh check; pending/ambiguous requests preserve their admission identity | Automated guest regression |
| Gateway stops after verification | Backend readiness expires and cannot remain indefinitely successful | Automated freshness regression; live gateway run pending |
| VM shutdown / host restart | Fresh readiness required; exact VM and disk identity retained | Pending live run |
| Permissions denied or revoked | Setup explains failure and can resume; no false computer-use success | Parser regressions; interactive OS prompts pending |
| Offline networking | No network device attached; VM retains local display and storage access | Preference persistence regression; live packet verification pending |
| Internet networking | Tailscale/model access works; UI states this is ordinary NAT without host/LAN containment | Pending live run |
| External containment | Deny host/LAN/tailnet/public-host destinations under IPv4/IPv6, spoofing, restart and policy failure; preserve authorized phone/model traffic | Not implemented; production blocker |
| Upgrade from legacy provider preferences | External packages remain untouched; app exposes only Apple virtualization | Automated preference regression; upgrade run pending |
| Developer ID distribution | Every executable has expected identity, hardened runtime and secure timestamp; final DMG notarized/stapled; clean Mac accepts download | Local ad-hoc checks only; production signing pending |

Do not mark external containment complete using a guest firewall or NAT status.
The offline mode is a disconnected boundary, not an Internet-enabled containment
solution. See [architecture](tether-host-architecture.md) for the missing enforcement
components and [distribution](tether-host-distribution.md) for release procedures.
