# Investigation: replacing gickup with a PAT-based bare git clone/fetch script

This document records whether the nightly gickup backup can be replaced by a small shell script that lists repositories through the provider REST APIs with a personal access token (PAT) and then runs plain `git clone` / `git fetch` on bare repositories.

> **Implemented** as `backup/git-backup`, run by a systemd timer on the host (the first option in [Scheduling and runtime](#6-scheduling-and-runtime)); gickup, Watchtower, `docker-compose.yml` and `conf.yml` are gone. The layout on the host was confirmed as `<site>/<owner>/<repo>.git` under `/data/gickup`. Unlike the sketch below, the token owner's own GitHub repositories are still fetched over SSH, as gickup did. Since then (#19), starred repositories (GitHub and gitlab.com) and the star and age filters were dropped: GitHub backup is every repository of the owners in `GICKUP_BACKUP_GITHUB_OWNERS`. See README.md, "Backup service". The rest of this document is the investigation as written.

## Recommendation

**Adopt**, subject to one precondition: the host measurement in [Memory footprint](#2-memory-footprint) must confirm that gickup's peak memory is materially higher than the script's on the same repository set. Memory could not be measured in the environment this investigation was written in, so that comparison is still outstanding.

Reasons:

- Everything the current configuration backs up is repository content, and every part of it can be reproduced with the GitHub and GitLab REST APIs, `jq` and the `git` CLI.
- The one gickup feature the script cannot reproduce with plain git is the GitLab `issues: true` backup. The repository owner has confirmed that only repository content matters, not issues or pull requests, so dropping it is acceptable.
- The existing mirrors under `/data/gickup` can be reused by `git fetch` rather than re-cloned, provided the on-disk layout is confirmed on the host first (see [Layout compatibility](#5-layout-compatibility)).

The follow-up implementation issue is raised separately; this document does not change `docker-compose.yml`, `conf.yml`, `update` or `README.md`.

## What gickup does today

The facts below are taken from the files in this repository.

- `docker-compose.yml` runs the `buddyspencer/gickup:latest` image as the `backup` service (`container_name: gickup-backup`) with `restart: always`, `stop_signal: SIGINT` and `stop_grace_period: 500s`. It mounts `conf.yml` read-only, `auth/` read-only as `/root/.auth`, `ssh/` as `/root/.ssh` and the external `gickup_data` volume as `/data`.
- `update` creates `/data/gickup` if missing, runs `git pull`, creates the `gickup_data` volume as a bind mount of `/data/gickup` and runs `docker compose pull` and `docker compose up -d`.
- A `watchtower` service updates pulled images on `WATCHTOWER_SCHEDULE` (default `0 24 * * * *`) and removes old images.
- `conf.yml` sets `cron: 27 3 * * *`, so gickup stays resident and runs at 03:27 every night.

`conf.yml` sources:

| Source | Transport | Repositories | Filter |
| --- | --- | --- | --- |
| GitHub, first entry | SSH (`ssh: true`, `sshkey: /root/.ssh/id_github`), token from `github.token` | the token owner's repositories plus starred repositories | `stars: 1`, `lastactivity: 5y`, `excludearchived: true`, `excludeforks: false` |
| GitHub, second entry | HTTPS with the token (no `ssh` key set) | `includeorgs: funfair-tech`, `starred: false` | `stars: 1`, `lastactivity: 5y`, `excludearchived: false`, `excludeforks: false` |
| GitLab | HTTPS with the token (`ssh` commented out), `url: https://gitlab.com` | owned plus starred projects, `issues: true` | none |

Two details the issue text glosses over:

- The `funfair-tech` entry has `excludearchived: false`, so archived `funfair-tech` repositories are backed up today. Only the first GitHub entry excludes archived repositories.
- The GitLab entry has no `filter` block, so every owned and starred GitLab project is backed up regardless of stars or activity.

`wiki`, `gists` and GitHub `issues` are `false` everywhere. The destination is `local` at `/data` with `structured: true` (commented in `conf.yml` as "checks repos out like hoster/site/user|organization/repo"), `bare: true`, `mirror: true`, `zip: false` and `lfs: false`.

## 1. Can a shell script reproduce the behaviour?

Yes. The [script sketch](#script-sketch) at the end of this document shows the whole flow:

- **Listing**: GitHub `/user/repos?affiliation=owner`, `/user/starred` and `/orgs/funfair-tech/repos`; GitLab `/api/v4/projects?owned=true` and `?starred=true`. Each is paginated with `per_page=100` until an empty page is returned.
- **Filtering** with `jq`: `stargazers_count >= 1`, `pushed_at` within the last 5 years (`MAX_AGE_DAYS=1826`) and `archived == false` for the user and starred listings only, matching the two GitHub entries above. GitLab is not filtered, matching today's configuration.
- **Mirroring**: `git clone --bare` when the target directory does not exist, otherwise `git fetch --prune` with explicit `refs/heads/*` and `refs/tags/*` refspecs against the HTTPS URL.

The fetch passes the URL and refspecs explicitly rather than running `git remote update`, because the existing gickup mirrors from the first GitHub entry were cloned over SSH and their stored remote URL may be an SSH URL. Fetching an explicit HTTPS URL works whatever the stored remote is, and does not rewrite the mirror's config.

Points to confirm against gickup's behaviour before implementation, because the gickup source was not inspected for this investigation:

- whether gickup's `lastactivity` compares against `pushed_at` or `updated_at`;
- whether gickup's own-repository listing includes collaborator and organisation-member repositories (the GitHub API default affiliation) or only owned ones. The sketch uses `affiliation=owner`; the stale-mirror report described in [point 7](#7-renamed-deleted-and-archived-repositories) shows any directory the new listing no longer covers, which is the check for this;
- whether gickup's `mirror: true` also stored refs outside `refs/heads` and `refs/tags` (for example GitHub's `refs/pull/*`). The sketch backs up branches and tags only, which matches the owner's "content only" scope, and `--prune` only removes refs matching the refspecs, so any existing extra refs are left untouched.

## 2. Memory footprint

**Not measured.** The environment this investigation was written in has no Docker or Podman, no `/usr/bin/time`, no gickup binary, no access to the backup host and no PAT (`auth/` only contains its `.gitignore`), so neither gickup nor the script could be run against the real repository set. No figures are given here, because any number would be invented.

Why the script is expected to use less memory (reasoning, not measurement):

- gickup is a single long-lived process (`restart: always`, resident between nightly runs because of `cron:`) that holds the whole repository listing. If it performs clones and fetches with an in-process git library rather than by running the `git` binary (the gickup source was not inspected to confirm which), that work also accumulates in the same process.
- The script's long-lived part is only `sh`, `curl` and `jq` while listing. Each `git` process handles one repository and exits, so peak memory is bounded by the largest single repository's fetch, and nothing stays resident between runs except the scheduler.

How to measure on the backup host, on the same repository set:

1. gickup, during the 03:27 run, sampling every few seconds:

   ```sh
   sudo docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' gickup-backup
   ```

   For the true peak rather than a sample, read the container cgroup's peak counter after the run (cgroup v2):

   ```sh
   cid=$(sudo docker inspect --format '{{.Id}}' gickup-backup)
   sudo cat "/sys/fs/cgroup/system.slice/docker-${cid}.scope/memory.peak"
   ```

   The cgroup path depends on the cgroup driver; `find /sys/fs/cgroup -name "*${cid}*"` locates it.

2. The script, run once against a copy of `/data/gickup` (so the run is fetch-only, like the nightly run), with GNU time installed (`apt install time` or `apk add time`):

   ```sh
   /usr/bin/time -v ./git-backup.sh 2>time.txt
   grep 'Maximum resident set size' time.txt
   ```

   `time -v` reports the largest single process's peak, which for the script is the largest `git` process. Running the script inside a container and reading its `memory.peak` as in step 1 gives a whole-run figure comparable with gickup's.

3. Record both peaks and the idle resident memory between runs (gickup's `docker stats` figure at midday; zero for a systemd timer, or the size of the idle loop container) in the follow-up issue.

## 3. Coverage gaps

| Feature in `conf.yml` | Script | Notes |
| --- | --- | --- |
| GitHub own repositories | Kept | `/user/repos?affiliation=owner` |
| GitHub starred repositories | Kept | `/user/starred` |
| `funfair-tech` organisation | Kept | `/orgs/funfair-tech/repos?type=all` |
| `stars: 1` | Kept | `stargazers_count >= 1` |
| `lastactivity: 5y` | Kept | `pushed_at` within 1826 days; confirm gickup's field (see point 1) |
| `excludearchived` | Kept | excluded for own and starred, included for `funfair-tech`, as today |
| `excludeforks: false` | Kept | forks are not filtered out |
| GitLab owned and starred projects | Kept | GitLab API `owned=true` and `starred=true`, no filter |
| GitLab `issues: true` | **Dropped** | plain git cannot back up issues. An API dump to JSON is possible but the owner only wants repository content, so it is out of scope |
| Wiki, gists, GitHub issues | Not needed | `false` in `conf.yml` today |
| LFS, zip, `keep` | Not needed | `lfs: false`, `zip: false`, `keep` commented out |
| Log time format, file logging | Replaced | the script writes plain progress lines to stdout, collected by `docker logs` or the systemd journal |

GitLab subgroups produce paths deeper than `gitlab.com/<namespace>/<project>`; the sketch's stale-mirror report only looks three levels deep, which the implementation must widen if any subgroup projects exist.

## 4. Authentication

Recommendation: PAT over HTTPS for every source, using a `GIT_ASKPASS` helper.

- The PAT is read from the existing token files (`/root/.auth/github.token`, `/root/.auth/gitlab.token`) only when git asks for credentials. The sketch is its own askpass helper: when `BACKUP_ASKPASS_TOKEN_FILE` is set it answers git's `Username` prompt with `x-access-token` (GitHub) or `oauth2` (GitLab) and the password prompt with the token file's contents.
- The token is never written into a repository's `config`: clone and fetch URLs contain no credentials, and `-c credential.helper=` clears any configured helper so the credential is not stored by one either.
- The token is never on a command line, so it does not appear in `ps` output or `/proc/<pid>/cmdline`. API calls pass the `Authorization` header to `curl` through `--config -` on stdin rather than `-H`.
- `GIT_TERMINAL_PROMPT=0` makes a rejected token fail immediately instead of hanging on a prompt.
- The script never prints the token or the header; progress lines only name the repository path.

Alternatives considered:

- `git -c http.extraHeader="Authorization: ..."` works, but puts the token in the `git` process's argv, which any local user can read. The same value can be passed through `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_0`/`GIT_CONFIG_VALUE_0` (git 2.31 or later) to keep it off argv, but it is then in the process environment for the whole fetch. The askpass form exposes only the token file's path.
- Keeping the SSH key for the first GitHub entry is possible (it needs `openssh-client` and the `ssh/` mount), but it means two credentials for one provider. With HTTPS everywhere the `ssh/` mount and `id_github` key can be retired once the replacement is live.

## 5. Layout compatibility

The script must write to exactly the paths gickup already uses so that the existing mirrors are fetched, not re-cloned. The sketch assumes `structured: true` produces `<hoster>/<owner>/<repo>` under `/data`, for example `github.com/credfeto/credfeto-gickup`, as the `conf.yml` comment describes.

**Not verified.** `/data/gickup` is not accessible from this environment, so the exact form (host name versus a short provider name, and whether bare repositories carry a `.git` suffix) has not been checked. Before implementation, list the existing layout on the host:

```sh
sudo find /data/gickup -mindepth 1 -maxdepth 3 -type d | sort | head -n 20
```

and adjust the path built in the `jq` filters (`"github.com/" + .full_name`, `"gitlab.com/" + .path_with_namespace`) to match. Then confirm reuse with a dry run against a copy:

1. Copy `/data/gickup` to a scratch directory and point `DEST` at it.
2. Run the script and check that every listed repository logs `Fetching`, not `Cloning`, for repositories that already exist.
3. Check that no mirror's `config` gained a token: `grep -rl x-access-token --include=config <copy>` must print nothing, and nor must a search for the token value.

## 6. Scheduling and runtime

| Option | Scheduling | Watchtower / `update` flow | Notes |
| --- | --- | --- | --- |
| Systemd timer on the host | `OnCalendar=*-*-* 03:27:00 Europe/London`, `Persistent=true` | `update` only needs `git pull`; no image to update, watchtower keeps updating its own image | Uses the host's `git`, `curl` and `jq`. Nothing is resident between runs. `TimeoutStopSec=500` on the service matches today's grace period |
| Stock image with the script mounted (for example `alpine` running `apk add git curl jq` then a loop or `crond`) | busybox `crond` or a `sleep` loop in the container | Works unchanged: watchtower pulls the stock image, `update` runs `docker compose pull` and `up -d` | Installs packages on every container start, so start-up needs network access. `alpine/git` is built around `git` (its entrypoint is `git`, so it must be overridden), so `curl` and `jq` still need installing unless the image is checked and found to include them |
| Image built from a Dockerfile in this repository | as above | Watchtower only updates images it can pull from a registry, so a locally built image is never updated by it; the image must be published (for example to GHCR by a workflow) for the flow to keep working | Most moving parts; only worth it if the package install on start-up is a problem |

Whichever runs the loop must let an in-progress `git fetch` finish on shutdown, the equivalent of today's `stop_signal: SIGINT` and `stop_grace_period: 500s`. For a container, the script should run as a child of a shell that forwards the signal, or under `tini`, with the same `stop_grace_period`.

The systemd timer is the simplest option with the lowest idle memory, and it removes the backup container entirely; the stock-image option is the closest drop-in replacement for the current Compose setup.

## 7. Renamed, deleted and archived repositories

The script never deletes a mirror. A backup that removes data when the upstream disappears defeats its purpose.

- **Deleted upstream**: the repository drops out of the listing, so its mirror is no longer fetched and stays as the last good copy. The script reports it as `Not listed upstream, kept: <path>` at the end of each run.
- **Renamed upstream**: the listing returns the new name, so a fresh clone is made at the new path and the old path is reported as not listed. The old mirror is kept; it can be removed by hand once the new one is confirmed. Storing each repository's numeric API `id` in its mirror config (for example `git config backup.id <id>`) would let a later version detect a rename and move the directory instead of re-cloning; that is optional.
- **Archived upstream**: for own and starred repositories the `excludearchived` filter drops it from the listing, so the mirror is kept as is and reported as not listed. Because an archived repository is read-only, the kept mirror stays complete. `funfair-tech` repositories keep being fetched after they are archived, as today.
- **Filtered out** (stars dropped to 0, no push for 5 years, unstarred): treated like deleted; the mirror is kept and reported.

This matches what gickup does today as far as can be told from its configuration: there is no option in `conf.yml` that prunes mirrors.

## Script sketch

This is a sketch for the follow-up implementation, not production code, and it is not committed as a script. It passes `shellcheck -s sh` and `checkbashisms`. It has not been run: there was no PAT and no backup data in the environment it was written in.

Configuration is through environment variables: `DEST`, `GITHUB_TOKEN_FILE`, `GITLAB_TOKEN_FILE`, `GITHUB_ORG` and `MAX_AGE_DAYS`.

```sh
#!/bin/sh
set -eu

DEST="${DEST:-/data}"
GITHUB_TOKEN_FILE="${GITHUB_TOKEN_FILE:-/root/.auth/github.token}"
GITLAB_TOKEN_FILE="${GITLAB_TOKEN_FILE:-/root/.auth/gitlab.token}"
GITHUB_ORG="${GITHUB_ORG:-funfair-tech}"
MAX_AGE_DAYS="${MAX_AGE_DAYS:-1826}"

# The script doubles as its own GIT_ASKPASS helper so the PAT is read from
# the token file at prompt time and never appears in argv, the environment
# or the repository config.
if [ -n "${BACKUP_ASKPASS_TOKEN_FILE:-}" ]; then
    case "${1:-}" in
        Username*) printf '%s\n' "${BACKUP_ASKPASS_USER}" ;;
        *) cat "${BACKUP_ASKPASS_TOKEN_FILE}" ;;
    esac
    exit 0
fi

die() {
    printf '\n✗ %s\n' "$*" >&2
    exit 1
}

info() {
    printf '\n→ %s\n' "$*"
}

success() {
    printf '\n✓ %s\n' "$*"
}

SELF=$(readlink -f "$0")
CUTOFF=$(($(date +%s) - MAX_AGE_DAYS * 86400))
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

# curl reads its config from stdin so the Authorization header stays off argv.
api_get() {
    {
        printf 'header = "Authorization: Bearer %s"\n' "$(cat "$1")"
        printf 'url = "%s"\n' "$2"
    } | curl --config - --fail --silent --show-error --location
}

# $1 token file, $2 base url ending in per_page=100, $3 jq filter, $4 provider
list_paginated() {
    page=1
    while :; do
        api_get "$1" "$2&page=${page}" >"${WORK}/page.json" || die "API request failed: $2"
        [ "$(jq 'length' <"${WORK}/page.json")" -gt 0 ] || break
        jq -r --argjson cutoff "${CUTOFF}" --arg provider "$4" "$3" <"${WORK}/page.json"
        page=$((page + 1))
    done
}

# shellcheck disable=SC2016 # $cutoff and $provider are jq variables
GITHUB_FILTER='.[]
  | select(.stargazers_count >= 1 and (.pushed_at | fromdateiso8601) >= $cutoff)
  | select($provider == "github-org" or (.archived | not))
  | [.clone_url, "github.com/" + .full_name, "github"] | @tsv'

GITLAB_FILTER='.[] | [.http_url_to_repo, "gitlab.com/" + .path_with_namespace, "gitlab"] | @tsv'

# $1 clone url, $2 path relative to DEST, $3 provider
mirror() {
    case "$3" in
        github) token_file="${GITHUB_TOKEN_FILE}" user=x-access-token ;;
        gitlab) token_file="${GITLAB_TOKEN_FILE}" user=oauth2 ;;
        *) die "Unknown provider: $3" ;;
    esac
    target="${DEST}/$2"
    if [ -d "${target}" ]; then
        info "Fetching $2"
        set -- fetch --prune "$1" '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'
        set -- -C "${target}" "$@"
    else
        info "Cloning $2"
        mkdir -p "$(dirname "${target}")"
        set -- clone --bare "$1" "${target}"
    fi
    BACKUP_ASKPASS_TOKEN_FILE="${token_file}" BACKUP_ASKPASS_USER="${user}" \
        GIT_ASKPASS="${SELF}" GIT_TERMINAL_PROMPT=0 \
        git -c credential.helper= "$@"
}

{
    list_paginated "${GITHUB_TOKEN_FILE}" 'https://api.github.com/user/repos?affiliation=owner&per_page=100' "${GITHUB_FILTER}" github
    list_paginated "${GITHUB_TOKEN_FILE}" 'https://api.github.com/user/starred?per_page=100' "${GITHUB_FILTER}" github
    list_paginated "${GITHUB_TOKEN_FILE}" "https://api.github.com/orgs/${GITHUB_ORG}/repos?type=all&per_page=100" "${GITHUB_FILTER}" github-org
    list_paginated "${GITLAB_TOKEN_FILE}" 'https://gitlab.com/api/v4/projects?owned=true&per_page=100' "${GITLAB_FILTER}" gitlab
    list_paginated "${GITLAB_TOKEN_FILE}" 'https://gitlab.com/api/v4/projects?starred=true&per_page=100' "${GITLAB_FILTER}" gitlab
} >"${WORK}/listed.tsv"
sort -u "${WORK}/listed.tsv" >"${WORK}/repos.tsv"
: >"${WORK}/seen.txt"

failures=0
tab=$(printf '\t')
while IFS="${tab}" read -r url path provider; do
    printf '%s\n' "${path}" >>"${WORK}/seen.txt"
    mirror "${url}" "${path}" "${provider}" </dev/null || failures=$((failures + 1))
done <"${WORK}/repos.tsv"

# Mirrors that are no longer listed (deleted, renamed, archived or filtered out
# upstream) are reported and kept, never removed.
find "${DEST}" -mindepth 3 -maxdepth 3 -type d | sed "s|^${DEST}/||" | sort >"${WORK}/disk.txt"
sort -u "${WORK}/seen.txt" | comm -23 "${WORK}/disk.txt" - | while IFS= read -r stale; do
    info "Not listed upstream, kept: ${stale}"
done

[ "${failures}" -eq 0 ] || die "${failures} repositories failed to back up"
success "Backup complete"
```

Design notes:

- The listing is written to a file inside the current shell rather than piped, because `#!/bin/sh` has no `pipefail`: a failed API call must stop the run instead of producing a partial list that would then report every unlisted mirror as stale.
- One failing repository does not stop the others; the run exits non-zero at the end with the failure count.
- `git` reads `/dev/null` as stdin so it cannot consume the repository list being read by the loop.
