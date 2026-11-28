# credfeto-gickup

## Backup service

`update` installs `backup/git-backup` as a systemd service, `gickup-backup.service`, run nightly at 03:27 (Europe/London) by `gickup-backup.timer`. A run missed while the host was off happens at the next boot. It mirrors, as bare repositories laid out as `<site>/<owner>/<repo>.git` under `/data/gickup`:

- the token owner's own and starred GitHub repositories, over SSH, with at least one star, pushed to within the last five years and not archived;
- the `funfair-tech` organisation's repositories, over HTTPS, with the same star and age filters, archived ones included;
- the token owner's own and starred gitlab.com projects, over HTTPS, unfiltered.

Only branches and tags are fetched. A mirror is never deleted: one that is no longer listed upstream (deleted, renamed, archived or filtered out) is kept and reported as `Not listed upstream, kept: <path>` at the end of the run. One repository failing does not stop the others; the run fails at the end with the count.

The service runs as the `gickup-backup` system user, which `update` creates and hands the mirrors to. The host needs `git`, `openssh`, `curl` and `jq`.

### Credentials

These files in the checkout are git-ignored, and the service reads them through systemd credentials:

| File                | Used for                                                                                             |
|---------------------|------------------------------------------------------------------------------------------------------|
| `auth/github.token` | GitHub personal access token: the API listing, and HTTPS fetches of the organisation's repositories  |
| `auth/gitlab.token` | gitlab.com personal access token (`read_api` and `read_repository`)                                  |
| `ssh/id_github`     | SSH key for fetching the token owner's own and starred GitHub repositories                           |
| `ssh/known_hosts`   | Optional: GitHub's host keys. Without it, the key seen on the first connection is pinned             |

The tokens never reach a command line, the environment or a mirror's config.

### Settings

Set in `.env` in the checkout's root:

| Variable                     | Default        | Meaning                                                  |
|------------------------------|----------------|----------------------------------------------------------|
| `GICKUP_BACKUP_DEST`         | `/data/gickup` | Where the mirrors live; run `./update` after changing it |
| `GICKUP_BACKUP_MAX_AGE_DAYS` | `1826`         | GitHub repositories not pushed to for longer are skipped |
| `GICKUP_BACKUP_GITHUB_ORG`   | `funfair-tech` | The GitHub organisation to mirror                        |

### Running it

Run a backup now, and read its log:

```sh
sudo systemctl start gickup-backup
sudo journalctl -u gickup-backup --since today
```

A dry run lists what would be cloned, fetched and reported, and writes nothing:

```sh
sudo systemctl set-environment GICKUP_BACKUP_DRY_RUN=true
sudo systemctl start gickup-backup
sudo systemctl unset-environment GICKUP_BACKUP_DRY_RUN
```

Stopping the service (`sudo systemctl stop gickup-backup`) lets the repository being fetched finish, for up to 500 seconds, then stops before the next one.

## Host firewall

`update` runs `firewall/configure`, which locks the gickup host's egress down with one nftables table, `inet gku_egress`, built and loaded by `firewall/egress`:

| Chain      | Traffic          | Allowed                                                                                                                                                                                                         |
|------------|------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `host_out` | host -> anywhere | DNS to the fleet's DNS servers, NTP to the router, HTTPS to the proxies, journald uploads to monitoring, GitHub over SSH and HTTPS, gitlab.com, Cloudflare, chaotic-aur, pkgstats, the Arch WKD, ICMP           |

Ingress needs nothing extra: nothing on the host listens apart from SSH, which is left to the host's base configuration.

The whole table, address sets included, is replaced in a single `nft -f` transaction: a refresh never makes firewalld reload, and a ruleset that fails to load leaves the previous one in place. firewalld keeps the host's base zones and never sees this table.

Two timers keep it current:

- `gickup-egress-refresh.timer` (30 seconds after boot, then every 10 minutes) rebuilds the table's address sets for destinations without a stable address: names resolved from DNS (a name that does not resolve keeps its last good addresses), plus GitHub's and Cloudflare's published ranges (`firewall/github-egress-ranges` and `firewall/cloudflare-egress-ranges`). It only loads the table when it differs from the loaded one.
- `gickup-firewall-sync.timer` (every 15 minutes) pulls the checkout and re-runs `firewall/configure` when anything under `firewall/` changed since the commit it last applied. Backup service changes still wait for `update`.

The `Repo: Update egress ranges` workflow regenerates the two range files daily and commits any change to main, refusing a list that has shrunk by more than a fifth.

`GICKUP_FIREWALL_ENFORCE` in `.env` is the only switch. Unset or anything other than `true` is observation mode: every rule is in place, but traffic that matches none of them still flows and is logged with the prefix `gku-egress-unmatched:` (rate-limited to 30 a minute). Run in observation mode through at least one nightly backup (`gickup-backup.timer`) and check the journal for anything legitimate that is not covered:

```sh
sudo journalctl -k --since -1d | grep 'gku-egress-unmatched'
```

then set `GICKUP_FIREWALL_ENFORCE=true` and run `./update`. To see the live egress rules:

```sh
sudo nft list table inet gku_egress
```
