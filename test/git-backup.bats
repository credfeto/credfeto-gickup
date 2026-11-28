#!/usr/bin/env bats

# Tests backup/git-backup against a fake curl (test/helpers/curl) serving the
# JSON fixtures in test/fixtures, with local bare repositories standing in for
# GitHub and gitlab.com.

bats_require_minimum_version 1.5.0

GITHUB_TOKEN="dummy-github-token-for-tests"
GITLAB_TOKEN="dummy-gitlab-token-for-tests"
GITHUB_API="https://api.test/github"
GITLAB_API="https://api.test/gitlab"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    SCRIPT="${REPO_ROOT}/backup/git-backup"

    export GIT_CONFIG_GLOBAL=/dev/null
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_ALLOW_PROTOCOL=file
    export HOME="${BATS_TEST_TMPDIR}/home"
    export CREDENTIALS_DIRECTORY="${BATS_TEST_TMPDIR}/credentials"
    export GICKUP_BACKUP_DEST="${BATS_TEST_TMPDIR}/dest"
    export GICKUP_BACKUP_GITHUB_API="${GITHUB_API}"
    export GICKUP_BACKUP_GITLAB_API="${GITLAB_API}"
    export GICKUP_BACKUP_GITHUB_OWNERS="me org other"
    unset GICKUP_BACKUP_DRY_RUN STATE_DIRECTORY GICKUP_BACKUP_ASKPASS_TOKEN_FILE

    export FAKE_CURL_LOG_DIR="${BATS_TEST_TMPDIR}/curl-log"
    export FAKE_CURL_ROUTES="${BATS_TEST_TMPDIR}/routes"
    export FAKE_FIXTURES_DIR="${BATS_TEST_DIRNAME}/fixtures"
    export FAKE_ORIGIN_DIR="${BATS_TEST_TMPDIR}/origin"
    export PATH="${BATS_TEST_DIRNAME}/helpers:${PATH}"

    mkdir -p "${HOME}" "${CREDENTIALS_DIRECTORY}" "${FAKE_CURL_LOG_DIR}" "${FAKE_ORIGIN_DIR}"
    printf '%s\n' "${GITHUB_TOKEN}" > "${CREDENTIALS_DIRECTORY}/github-token"
    printf '%s\n' "${GITLAB_TOKEN}" > "${CREDENTIALS_DIRECTORY}/gitlab-token"
    printf 'not a real key\n' > "${CREDENTIALS_DIRECTORY}/id_github"

    for NAME in own-a own-archived own-fork org-c org-archived other-d gl-proj; do
        make_origin "${NAME}"
    done

    write_routes \
        "${GITHUB_API}/user" github-user.json \
        "${GITHUB_API}/users/org" github-users-org.json \
        "${GITHUB_API}/users/other" github-users-other.json \
        "${GITHUB_API}/user/repos?affiliation=owner&per_page=100&page=1" github-own.json \
        "${GITHUB_API}/orgs/org/repos?type=all&per_page=100&page=1" github-org-1.json \
        "${GITHUB_API}/orgs/org/repos?type=all&per_page=100&page=2" github-org-2.json \
        "${GITHUB_API}/users/other/repos?type=owner&per_page=100&page=1" github-other.json \
        "${GITLAB_API}/projects?owned=true&simple=true&per_page=100&page=1" gitlab-owned.json
}

# Pairs of URL and fixture name.
write_routes() {
    : > "${FAKE_CURL_ROUTES}"
    while [ "$#" -ge 2 ]; do
        printf '%s\t%s\n' "$1" "$2" >> "${FAKE_CURL_ROUTES}"
        shift 2
    done
}

# Replaces the fixture a route answers with.
reroute() {
    awk -F '\t' -v OFS='\t' -v url="$1" -v fixture="$2" \
        '$1 == url { $2 = fixture } { print }' "${FAKE_CURL_ROUTES}" > "${FAKE_CURL_ROUTES}.new"
    mv "${FAKE_CURL_ROUTES}.new" "${FAKE_CURL_ROUTES}"
}

make_origin() {
    WORKTREE="${BATS_TEST_TMPDIR}/work/$1"
    git init --quiet --initial-branch=main "${WORKTREE}"
    commit_to "$1" "first"
    git clone --quiet --bare "${WORKTREE}" "${FAKE_ORIGIN_DIR}/$1.git"
    git -C "${WORKTREE}" remote add origin "${FAKE_ORIGIN_DIR}/$1.git"
    git -C "${WORKTREE}" tag "v-$1"
    git -C "${WORKTREE}" push --quiet origin "v-$1"
}

# $1 origin name, $2 message
commit_to() {
    git -C "${BATS_TEST_TMPDIR}/work/$1" -c user.name=Test -c user.email=test@example.invalid \
        commit --quiet --allow-empty -m "$2"
}

mirror_head() {
    git -C "${GICKUP_BACKUP_DEST}/$1" rev-parse refs/heads/main
}

@test "mirrors the listed repositories as bare repositories in the structured layout" {
    run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Backup complete: 7 repositories"* ]]
    for MIRROR in github.com/me/own-a.git github.com/me/own-archived.git github.com/me/own-fork.git \
        github.com/org/org-c.git github.com/org/org-archived.git github.com/other/other-d.git \
        gitlab.com/me/group/sub-proj.git; do
        [ "$(git -C "${GICKUP_BACKUP_DEST}/${MIRROR}" rev-parse --is-bare-repository)" = "true" ]
    done
    [ "$(mirror_head github.com/me/own-a.git)" = "$(git -C "${FAKE_ORIGIN_DIR}/own-a.git" rev-parse refs/heads/main)" ]
    git -C "${GICKUP_BACKUP_DEST}/github.com/me/own-a.git" rev-parse --verify --quiet refs/tags/v-own-a
}

remote_url() {
    git -C "${GICKUP_BACKUP_DEST}/$1" config remote.origin.url
}

@test "the token owner's repositories are listed through /user/repos and fetched over SSH" {
    run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    grep -qxF "${GITHUB_API}/user/repos?affiliation=owner&per_page=100&page=1" "${FAKE_CURL_LOG_DIR}/urls"
    run ! grep -qF "${GITHUB_API}/users/me" "${FAKE_CURL_LOG_DIR}/urls"
    [ "$(remote_url github.com/me/own-a.git)" = "file://${FAKE_ORIGIN_DIR}/own-a.git" ]
    [ "$(remote_url github.com/me/own-fork.git)" = "file://${FAKE_ORIGIN_DIR}/own-fork.git" ]
}

@test "the token owner is matched whatever the case of the setting" {
    GICKUP_BACKUP_GITHUB_OWNERS="ME" run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ "$(remote_url github.com/me/own-a.git)" = "file://${FAKE_ORIGIN_DIR}/own-a.git" ]
    run ! grep -qF "${GITHUB_API}/users/" "${FAKE_CURL_LOG_DIR}/urls"
}

@test "an organisation's repositories are listed through /orgs and fetched over HTTPS" {
    run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    grep -qxF "${GITHUB_API}/users/org" "${FAKE_CURL_LOG_DIR}/urls"
    grep -qxF "${GITHUB_API}/orgs/org/repos?type=all&per_page=100&page=1" "${FAKE_CURL_LOG_DIR}/urls"
    [ "$(remote_url github.com/org/org-c.git)" = "file://${FAKE_ORIGIN_DIR}/org-c.git" ]
}

@test "another user's repositories are listed through /users and fetched over HTTPS" {
    run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    grep -qxF "${GITHUB_API}/users/other/repos?type=owner&per_page=100&page=1" "${FAKE_CURL_LOG_DIR}/urls"
    [ "$(remote_url github.com/other/other-d.git)" = "file://${FAKE_ORIGIN_DIR}/other-d.git" ]
}

@test "an entry owned by someone other than the owner it was listed for is dropped" {
    run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ ! -e "${GICKUP_BACKUP_DEST}/github.com/someone" ]
    [ ! -e "${GICKUP_BACKUP_DEST}/github.com/intruder" ]
    [[ "${output}" != *"someone/collab"* ]]
    [[ "${output}" != *"intruder/planted"* ]]
}

@test "archived and forked repositories are included, with no star or age filter" {
    run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    # own-a and org-c have no stars and were last pushed to in 2001.
    for MIRROR in github.com/me/own-a.git github.com/me/own-archived.git github.com/me/own-fork.git \
        github.com/org/org-c.git github.com/org/org-archived.git github.com/other/other-d.git; do
        [ -d "${GICKUP_BACKUP_DEST}/${MIRROR}" ]
    done
}

@test "the default owners are used when GICKUP_BACKUP_GITHUB_OWNERS is unset" {
    unset GICKUP_BACKUP_GITHUB_OWNERS
    export FAKE_FIXTURES_DIR="${BATS_TEST_TMPDIR}/fixtures"
    cp -R "${BATS_TEST_DIRNAME}/fixtures" "${FAKE_FIXTURES_DIR}"
    printf '{"login": "credfeto", "type": "User"}\n' > "${FAKE_FIXTURES_DIR}/token-owner.json"
    printf '{"type": "Organization"}\n' > "${FAKE_FIXTURES_DIR}/organisation.json"
    printf '{"type": "User"}\n' > "${FAKE_FIXTURES_DIR}/user.json"
    write_routes \
        "${GITHUB_API}/user" token-owner.json \
        "${GITHUB_API}/users/funfair-tech" organisation.json \
        "${GITHUB_API}/users/dnyw4l3n13" user.json \
        "${GITHUB_API}/users/steward-warden" user.json \
        "${GITHUB_API}/users/prpixie" user.json \
        "${GITLAB_API}/projects?owned=true&simple=true&per_page=100&page=1" gitlab-owned.json
    run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    for URL in "user/repos?affiliation=owner" "orgs/funfair-tech/repos?type=all" \
        "users/dnyw4l3n13/repos?type=owner" "users/steward-warden/repos?type=owner" \
        "users/prpixie/repos?type=owner"; do
        grep -qxF "${GITHUB_API}/${URL}&per_page=100&page=1" "${FAKE_CURL_LOG_DIR}/urls"
    done
    run ! grep -qF "${GITHUB_API}/users/credfeto" "${FAKE_CURL_LOG_DIR}/urls"
    [ "$(grep -c "${GITHUB_API}/.*repos" "${FAKE_CURL_LOG_DIR}/urls")" -eq 5 ]
}

@test "an owner named twice is listed and mirrored once" {
    GICKUP_BACKUP_GITHUB_OWNERS="me org ME other org" run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ "$(grep -c 'Cloning github.com/me/own-a.git' <<< "${output}")" -eq 1 ]
    [ "$(grep -cxF "${GITHUB_API}/user/repos?affiliation=owner&per_page=100&page=1" "${FAKE_CURL_LOG_DIR}/urls")" -eq 1 ]
    [ "$(grep -cxF "${GITHUB_API}/users/org" "${FAKE_CURL_LOG_DIR}/urls")" -eq 1 ]
    [[ "${output}" == *"Backup complete: 7 repositories"* ]]
}

@test "only the listed GitHub owners are mirrored, and GitLab projects still are" {
    GICKUP_BACKUP_GITHUB_OWNERS="org" run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ -d "${GICKUP_BACKUP_DEST}/gitlab.com/me/group/sub-proj.git" ]
    [ ! -e "${GICKUP_BACKUP_DEST}/github.com/me" ]
    [[ "${output}" == *"Backup complete: 3 repositories"* ]]
}

@test "pages through a listing until an empty page" {
    run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    grep -qxF "${GITHUB_API}/orgs/org/repos?type=all&per_page=100&page=3" "${FAKE_CURL_LOG_DIR}/urls"
    run ! grep -qF "page=4" "${FAKE_CURL_LOG_DIR}/urls"
    [ -d "${GICKUP_BACKUP_DEST}/github.com/org/org-archived.git" ]
}

@test "a second run fetches new commits and tags into the existing mirrors" {
    run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    commit_to own-a "second"
    git -C "${BATS_TEST_TMPDIR}/work/own-a" tag v-second
    git -C "${BATS_TEST_TMPDIR}/work/own-a" push --quiet origin main v-second

    run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Fetching github.com/me/own-a.git"* ]]
    [[ "${output}" != *"Cloning"* ]]
    [ "$(mirror_head github.com/me/own-a.git)" = "$(git -C "${FAKE_ORIGIN_DIR}/own-a.git" rev-parse refs/heads/main)" ]
    git -C "${GICKUP_BACKUP_DEST}/github.com/me/own-a.git" rev-parse --verify --quiet refs/tags/v-second
}

@test "reports a mirror that is no longer listed and keeps it" {
    for MIRROR in github.com/me/gone.git github.com/Org/renamed.git gitlab.com/me/gone.git; do
        git init --quiet --bare "${GICKUP_BACKUP_DEST}/${MIRROR}"
    done
    run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Not listed upstream, kept: github.com/me/gone.git"* ]]
    [[ "${output}" == *"Not listed upstream, kept: github.com/Org/renamed.git"* ]]
    [[ "${output}" == *"Not listed upstream, kept: gitlab.com/me/gone.git"* ]]
    [ "$(grep -c 'Not listed upstream' <<< "${output}")" -eq 3 ]
    [[ "${output}" != *"Not in GICKUP_BACKUP_GITHUB_OWNERS"* ]]
    [ -d "${GICKUP_BACKUP_DEST}/github.com/me/gone.git" ]
}

@test "reports a mirror of an owner outside the owner list separately and keeps it" {
    for MIRROR in github.com/FFmpeg/FFmpeg.git github.com/me/gone.git; do
        git init --quiet --bare "${GICKUP_BACKUP_DEST}/${MIRROR}"
    done
    run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Not in GICKUP_BACKUP_GITHUB_OWNERS, kept: github.com/FFmpeg/FFmpeg.git"* ]]
    [ "$(grep -c 'Not in GICKUP_BACKUP_GITHUB_OWNERS' <<< "${output}")" -eq 1 ]
    [[ "${output}" == *"Not listed upstream, kept: github.com/me/gone.git"* ]]
    [ "$(grep -c 'Not listed upstream' <<< "${output}")" -eq 1 ]
    [ "$(git -C "${GICKUP_BACKUP_DEST}/github.com/FFmpeg/FFmpeg.git" rev-parse --is-bare-repository)" = "true" ]
}

@test "a dry run reports what it would do and writes nothing" {
    run "${SCRIPT}" --dry-run
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Cloning github.com/me/own-a.git (dry run, nothing written)"* ]]
    [[ "${output}" == *"Dry run complete: 7 repositories listed, nothing written"* ]]
    [ ! -e "${GICKUP_BACKUP_DEST}" ]
}

@test "GICKUP_BACKUP_DRY_RUN=true is a dry run, and an existing mirror would be fetched" {
    run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    BEFORE="$(mirror_head github.com/me/own-a.git)"
    commit_to own-a "second"
    git -C "${BATS_TEST_TMPDIR}/work/own-a" push --quiet origin main

    GICKUP_BACKUP_DRY_RUN=true run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Fetching github.com/me/own-a.git (dry run, nothing written)"* ]]
    [ "$(mirror_head github.com/me/own-a.git)" = "${BEFORE}" ]
}

@test "the tokens reach no command line, output or mirror config" {
    run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"${GITHUB_TOKEN}"* ]]
    [[ "${output}" != *"${GITLAB_TOKEN}"* ]]
    [ -s "${FAKE_CURL_LOG_DIR}/argv" ]
    [ -d "${GICKUP_BACKUP_DEST}/github.com/me/own-a.git" ]
    run ! grep -qF -e "${GITHUB_TOKEN}" -e "${GITLAB_TOKEN}" "${FAKE_CURL_LOG_DIR}/argv"
    run ! grep -rqF -e "${GITHUB_TOKEN}" -e "${GITLAB_TOKEN}" "${GICKUP_BACKUP_DEST}"
    grep -qxF "header = \"Authorization: Bearer ${GITHUB_TOKEN}\"" "${FAKE_CURL_LOG_DIR}/config"
    grep -qxF "header = \"Authorization: Bearer ${GITLAB_TOKEN}\"" "${FAKE_CURL_LOG_DIR}/config"
}

@test "curl is restricted to HTTPS and fails on HTTP errors" {
    run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    while IFS= read -r ARGV; do
        [[ "${ARGV}" == *"--proto =https"* ]]
        [[ "${ARGV}" == *"--fail"* ]]
    done < "${FAKE_CURL_LOG_DIR}/argv"
}

@test "a failed listing stops the run before any repository is touched" {
    reroute "${GITHUB_API}/orgs/org/repos?type=all&per_page=100&page=2" FAIL
    run "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Listing failed: ${GITHUB_API}/orgs/org/repos?type=all"* ]]
    [ ! -e "${GICKUP_BACKUP_DEST}" ]
}

@test "a failed owner lookup stops the run before any repository is touched" {
    reroute "${GITHUB_API}/users/other" FAIL
    run "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Lookup failed: ${GITHUB_API}/users/other"* ]]
    [ ! -e "${GICKUP_BACKUP_DEST}" ]
}

@test "an owner that is neither a user nor an organisation stops the run" {
    reroute "${GITHUB_API}/users/other" not-a-list.json
    run "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"GitHub owner other is neither a user nor an organisation"* ]]
    [ ! -e "${GICKUP_BACKUP_DEST}" ]
}

@test "a token owner lookup without a login stops the run" {
    reroute "${GITHUB_API}/user" not-a-list.json
    run "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Could not read the token owner's login"* ]]
    [ ! -e "${GICKUP_BACKUP_DEST}" ]

    reroute "${GITHUB_API}/user" github-own.json
    run "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Lookup did not return an object: ${GITHUB_API}/user"* ]]
}

@test "a listing that is not a list stops the run" {
    reroute "${GITHUB_API}/user/repos?affiliation=owner&per_page=100&page=1" not-a-list.json
    run "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Listing did not return a list"* ]]
    [ ! -e "${GICKUP_BACKUP_DEST}" ]
}

@test "a repository that fails does not stop the others, and the run fails with the count" {
    rm -rf "${FAKE_ORIGIN_DIR}/other-d.git"
    run "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to back up github.com/other/other-d.git"* ]]
    [[ "${output}" == *"1 of 7 repositories failed to back up"* ]]
    [ -d "${GICKUP_BACKUP_DEST}/gitlab.com/me/group/sub-proj.git" ]
}

@test "a listed path that could reach outside the destination is skipped" {
    reroute "${GITLAB_API}/projects?owned=true&simple=true&per_page=100&page=1" bad-path.json
    run "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Skipping an unexpected listing entry: gitlab.com/me/../../escape.git"* ]]
    [ ! -e "${BATS_TEST_TMPDIR}/escape.git" ]
    [ ! -e "${GICKUP_BACKUP_DEST}/escape.git" ]
}

@test "an unknown argument is refused" {
    run "${SCRIPT}" --bogus
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Unknown argument: --bogus"* ]]
}

@test "a missing credential is refused" {
    rm "${CREDENTIALS_DIRECTORY}/gitlab-token"
    run "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Missing credential: ${CREDENTIALS_DIRECTORY}/gitlab-token"* ]]
}

@test "a token with unexpected characters is refused" {
    printf 'abc"\nurl = "https://elsewhere.invalid/"\n' > "${CREDENTIALS_DIRECTORY}/github-token"
    run "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"has unexpected characters"* ]]
    [ ! -e "${FAKE_CURL_LOG_DIR}/argv" ]
}

@test "an invalid owner name is refused before anything is listed" {
    for OWNERS in "me org/../x" "me .." "me *" "me o%2fx"; do
        GICKUP_BACKUP_GITHUB_OWNERS="${OWNERS}" run "${SCRIPT}"
        [ "${status}" -ne 0 ]
        [[ "${output}" == *"GICKUP_BACKUP_GITHUB_OWNERS has an entry that is not a GitHub owner name: ${OWNERS#me }"* ]]
    done
    GICKUP_BACKUP_GITHUB_OWNERS="  " run "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"GICKUP_BACKUP_GITHUB_OWNERS lists no GitHub owners"* ]]
    [ ! -e "${FAKE_CURL_LOG_DIR}/argv" ]
}

@test "invalid settings are refused" {

    GICKUP_BACKUP_DEST=relative/dest run "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"GICKUP_BACKUP_DEST must be an absolute path"* ]]
}

@test "as git's askpass helper it answers the username and the token" {
    GICKUP_BACKUP_ASKPASS_TOKEN_FILE="${CREDENTIALS_DIRECTORY}/github-token" \
        GICKUP_BACKUP_ASKPASS_USER=x-access-token \
        run "${SCRIPT}" "Username for 'https://github.com': "
    [ "${status}" -eq 0 ]
    [ "${output}" = "x-access-token" ]

    GICKUP_BACKUP_ASKPASS_TOKEN_FILE="${CREDENTIALS_DIRECTORY}/gitlab-token" \
        GICKUP_BACKUP_ASKPASS_USER=oauth2 \
        run "${SCRIPT}" "Password for 'https://oauth2@gitlab.com': "
    [ "${status}" -eq 0 ]
    [ "${output}" = "${GITLAB_TOKEN}" ]
}

# Puts a fake git, which logs what the real script hands it and then creates
# the clone's target directory, ahead of the real one on PATH. $1 is extra
# shell to run after logging.
use_fake_git() {
    FAKE_GIT_DIR="${BATS_TEST_TMPDIR}/fake-git"
    export FAKE_GIT_LOG="${BATS_TEST_TMPDIR}/git-log"
    mkdir -p "${FAKE_GIT_DIR}"
    {
        cat << 'EOF'
#!/bin/sh
case " $* " in
    *" clone "*)
        {
            printf 'user=%s\n' "$("${GIT_ASKPASS}" "Username for 'https://host': ")"
            printf 'pass=%s\n' "$("${GIT_ASKPASS}" "Password for 'https://user@host': ")"
            printf 'argv=%s\n' "$*"
            printf 'ssh=%s\n' "${GIT_SSH_COMMAND}"
        } >> "${FAKE_GIT_LOG}"
        for LAST in "$@"; do :; done
        mkdir -p "${LAST}"
EOF
        printf '%s\n' "${1:-}"
        printf '        ;;\nesac\n'
    } > "${FAKE_GIT_DIR}/git"
    chmod +x "${FAKE_GIT_DIR}/git"
    export PATH="${FAKE_GIT_DIR}:${PATH}"
}

@test "git gets the token through askpass when the remote asks for credentials" {
    use_fake_git
    run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    grep -qxF "user=x-access-token" "${FAKE_GIT_LOG}"
    grep -qxF "pass=${GITHUB_TOKEN}" "${FAKE_GIT_LOG}"
    grep -qxF "user=oauth2" "${FAKE_GIT_LOG}"
    grep -qxF "pass=${GITLAB_TOKEN}" "${FAKE_GIT_LOG}"
    GIT_ARGV="$(grep '^argv=' "${FAKE_GIT_LOG}")"
    [[ "${GIT_ARGV}" != *"${GITHUB_TOKEN}"* ]]
    [[ "${GIT_ARGV}" != *"${GITLAB_TOKEN}"* ]]
    [[ "${GIT_ARGV}" == *"-c credential.helper= clone --bare"* ]]
}

@test "git uses the SSH key credential and pins host keys in the state directory" {
    use_fake_git
    run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    SSH_COMMAND="$(grep -m 1 '^ssh=' "${FAKE_GIT_LOG}")"
    [[ "${SSH_COMMAND}" == *"-i '${CREDENTIALS_DIRECTORY}/id_github'"* ]]
    [[ "${SSH_COMMAND}" == *"-o IdentitiesOnly=yes"* ]]
    [[ "${SSH_COMMAND}" == *"-o BatchMode=yes"* ]]
    [[ "${SSH_COMMAND}" == *"-o StrictHostKeyChecking=accept-new"* ]]
    [[ "${SSH_COMMAND}" == *"-o 'UserKnownHostsFile=${HOME}/known_hosts'" ]]
}

@test "a known_hosts credential is trusted alongside the pinned keys, under STATE_DIRECTORY" {
    printf 'github.com ssh-ed25519 AAAA\n' > "${CREDENTIALS_DIRECTORY}/known_hosts"
    STATE="${BATS_TEST_TMPDIR}/state"
    use_fake_git
    STATE_DIRECTORY="${STATE}" run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    SSH_COMMAND="$(grep -m 1 '^ssh=' "${FAKE_GIT_LOG}")"
    [[ "${SSH_COMMAND}" == *"-o 'UserKnownHostsFile=${STATE}/known_hosts ${CREDENTIALS_DIRECTORY}/known_hosts'" ]]
}

@test "a credential or state path with a single quote is refused" {
    STATE_DIRECTORY="${BATS_TEST_TMPDIR}/it's" run "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"must not contain a single quote"* ]]
}

@test "a stop request finishes the current repository and skips the rest" {
    # SIGTERM rather than systemd's SIGINT: under bats --jobs each test runs as
    # a background job, which starts with SIGINT ignored, and a shell cannot
    # trap a signal ignored on entry. The script traps both the same way.
    # shellcheck disable=SC2016 # expanded by the fake git, not here
    use_fake_git 'kill -TERM "${PPID}"'
    run "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Stopped after 1 repositories, before the backup finished"* ]]
    [ "$(grep -c '^argv=' "${FAKE_GIT_LOG}")" -eq 1 ]
    [ -d "${GICKUP_BACKUP_DEST}/github.com/me/own-a.git" ]
    [ ! -e "${GICKUP_BACKUP_DEST}/github.com/me/own-archived.git" ]
}
