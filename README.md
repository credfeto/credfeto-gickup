# credfeto-gickup

## Watchtower schedule

The `watchtower` service checks for updated images on a cron schedule rather than a fixed poll interval.

- Default schedule: `0 24 * * * *`, which runs hourly at minute 24.
- The schedule uses Watchtower's 6-field cron format, with seconds first: `seconds minutes hours day-of-month month day-of-week`.
- Old images are removed after an update, because `WATCHTOWER_CLEANUP` is set to `true`.

### Overriding the schedule

Copy `example.env` to `.env` in the same directory as `docker-compose.yml`, then change `WATCHTOWER_SCHEDULE`:

```sh
cp example.env .env
```

Docker Compose reads `.env` automatically. The `.env` file is git-ignored, so local settings are never committed.

## Host firewall

`update` runs `firewall/configure`, which locks the gickup host's egress down with firewalld policies, the same way as the DNS servers:

| Policy              | Traffic                     | Allowed                                                                                                                                                                       |
|---------------------|-----------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `gku-egress`        | host -> anywhere            | DNS to the fleet's DNS servers, NTP to the router, HTTPS to the proxies, journald uploads to monitoring, GitHub, ghcr.io, Docker Hub, Cloudflare, chaotic-aur, pkgstats, the Arch WKD, ICMP |
| `gku-egress-docker` | containers -> outside world | DNS, HTTPS to the proxies, GitHub over SSH and HTTPS, gitlab.com, Docker Hub and Cloudflare (Watchtower)                                                                    |

Ingress needs nothing extra: the containers publish no ports, and SSH is left to the host's base configuration.

Two timers keep it current:

* `gickup-egress-refresh.timer` (every 10 minutes) refreshes the firewalld ipsets for destinations without a stable address: names resolved from DNS, plus GitHub's and Cloudflare's published ranges (`firewall/github-egress-ranges` and `firewall/cloudflare-egress-ranges`).
* `gickup-firewall-sync.timer` (every 15 minutes) pulls the checkout and re-runs `firewall/configure` when anything under `firewall/` changed since the commit it last applied. Container changes still wait for `update`.

The `Repo: Update egress ranges` workflow regenerates the two range files daily and commits any change to main, refusing a list that has shrunk by more than a fifth.

`GICKUP_FIREWALL_ENFORCE` in `.env` is the only switch. Unset or anything other than `true` is observation mode: every rule is in place, but traffic that matches none of them still flows and is logged with the prefix `gku-egress-unmatched:` or `gku-egress-docker-unmatched:` (rate-limited to 30 a minute). Run in observation mode through at least one nightly backup (`cron` in `conf.yml`) and check the journal for anything legitimate that is not covered:

```sh
sudo journalctl -k --since -1d | grep -E 'gku-egress(-docker)?-unmatched'
```

then set `GICKUP_FIREWALL_ENFORCE=true` and run `./update`.
