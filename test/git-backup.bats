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
    export GICKUP_BACKUP_GITHUB_ORG=org
    unset GICKUP_BACKUP_DRY_RUN GICKUP_BACKUP_MAX_AGE_DAYS STATE_DIRECTORY GICKUP_BACKUP_ASKPASS_TOKEN_FILE

    export FAKE_CURL_LOG_DIR="${BATS_TEST_TMPDIR}/curl-log"
    export FAKE_CURL_ROUTES="${BATS_TEST_TMPDIR}/routes"
    export FAKE_FIXTURES_DIR="${BATS_TEST_DIRNAME}/fixtures"
    export FAKE_ORIGIN_DIR="${BATS_TEST_TMPDIR}/origin"
    export PATH="${BATS_TEST_DIRNAME}/helpers:${PATH}"

    mkdir -p "${HOME}" "${CREDENTIALS_DIRECTORY}" "${FAKE_CURL_LOG_DIR}" "${FAKE_ORIGIN_DIR}"
    printf '%s\n' "${GITHUB_TOKEN}" > "${CREDENTIALS_DIRECTORY}/github-token"
    printf '%s\n' "${GITLAB_TOKEN}" > "${CREDENTIALS_DIRECTORY}/gitlab-token"
    printf 'not a real key\n' > "${CREDENTIALS_DIRECTORY}/id_github"

    for NAME in own-a star-b org-c org-archived gl-proj gl-star1 gl-star2; do
        make_origin "${NAME}"
    done

    write_routes \
        "${GITHUB_API}/user/repos?affiliation=owner&per_page=100&page=1" github-own.json \
        "${GITHUB_API}/user/starred?sort=created&per_page=100&page=1" github-starred.json \
        "${GITHUB_API}/orgs/org/repos?type=all&per_page=100&page=1" github-org.json \
        "${GITLAB_API}/projects?owned=true&simple=true&per_page=100&page=1" gitlab-owned.json \
        "${GITLAB_API}/projects?starred=true&simple=true&per_page=100&page=1" gitlab-starred-1.json \
        "${GITLAB_API}/projects?starred=true&simple=true&per_page=100&page=2" gitlab-starred-2.json
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
    for MIRROR in github.com/me/own-a.git github.com/other/star-b.git github.com/org/org-c.git \
        github.com/org/org-archived.git gitlab.com/me/group/sub-proj.git \
        gitlab.com/someone/gl-star1.git gitlab.com/someone/gl-star2.git; do
        [ "$(git -C "${GICKUP_BACKUP_DEST}/${MIRROR}" rev-parse --is-bare-repository)" = "true" ]
    done
    [ "$(mirror_head github.com/me/own-a.git)" = "$(git -C "${FAKE_ORIGIN_DIR}/own-a.git" rev-parse refs/heads/main)" ]
    git -C "${GICKUP_BACKUP_DEST}/github.com/me/own-a.git" rev-parse --verify --quiet refs/tags/v-own-a
}

@test "skips own and starred GitHub repositories that are unstarred, old or archived" {
    run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ ! -e "${GICKUP_BACKUP_DEST}/github.com/me/own-unstarred.git" ]
    [ ! -e "${GICKUP_BACKUP_DEST}/github.com/me/own-old.git" ]
    [ ! -e "${GICKUP_BACKUP_DEST}/github.com/me/own-archived.git" ]
}

@test "keeps archived organisation repositories but still applies the star and age filters" {
    run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ -d "${GICKUP_BACKUP_DEST}/github.com/org/org-archived.git" ]
    [ ! -e "${GICKUP_BACKUP_DEST}/github.com/org/org-unstarred.git" ]
    [ ! -e "${GICKUP_BACKUP_DEST}/github.com/org/org-old.git" ]
}

@test "the age filter follows GICKUP_BACKUP_MAX_AGE_DAYS" {
    export GICKUP_BACKUP_MAX_AGE_DAYS=100000
    run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ -d "${GICKUP_BACKUP_DEST}/github.com/me/own-old.git" ]
}

@test "uses the SSH URL for own and starred repositories and the HTTPS URL for the organisation" {
    run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ "$(git -C "${GICKUP_BACKUP_DEST}/github.com/other/star-b.git" config remote.origin.url)" = "file://${FAKE_ORIGIN_DIR}/star-b.git" ]
    [ "$(git -C "${GICKUP_BACKUP_DEST}/github.com/org/org-c.git" config remote.origin.url)" = "file://${FAKE_ORIGIN_DIR}/org-c.git" ]
}

@test "a repository listed twice is mirrored once, from the first listing" {
    run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ "$(grep -c 'Cloning github.com/me/own-a.git' <<< "${output}")" -eq 1 ]
    [ "$(git -C "${GICKUP_BACKUP_DEST}/github.com/me/own-a.git" config remote.origin.url)" = "file://${FAKE_ORIGIN_DIR}/own-a.git" ]
}

@test "pages through a listing until an empty page" {
    run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    grep -qxF "${GITLAB_API}/projects?starred=true&simple=true&per_page=100&page=3" "${FAKE_CURL_LOG_DIR}/urls"
    [ -s "${FAKE_CURL_LOG_DIR}/urls" ]
    run ! grep -qF "page=4" "${FAKE_CURL_LOG_DIR}/urls"
    [ -d "${GICKUP_BACKUP_DEST}/gitlab.com/someone/gl-star2.git" ]
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
    mkdir -p "${GICKUP_BACKUP_DEST}/github.com/me"
    git init --quiet --bare "${GICKUP_BACKUP_DEST}/github.com/me/gone.git"
    run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Not listed upstream, kept: github.com/me/gone.git"* ]]
    [ "$(grep -c 'Not listed upstream' <<< "${output}")" -eq 1 ]
    [ -d "${GICKUP_BACKUP_DEST}/github.com/me/gone.git" ]
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
    reroute "${GITLAB_API}/projects?starred=true&simple=true&per_page=100&page=2" FAIL
    run "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Listing failed: ${GITLAB_API}/projects?starred=true&simple=true"* ]]
    [ ! -e "${GICKUP_BACKUP_DEST}" ]
}

@test "a listing that is not a list stops the run" {
    reroute "${GITHUB_API}/user/repos?affiliation=owner&per_page=100&page=1" not-a-list.json
    run "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Listing did not return a list"* ]]
    [ ! -e "${GICKUP_BACKUP_DEST}" ]
}

@test "a repository that fails does not stop the others, and the run fails with the count" {
    rm -rf "${FAKE_ORIGIN_DIR}/star-b.git"
    run "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Failed to back up github.com/other/star-b.git"* ]]
    [[ "${output}" == *"1 of 7 repositories failed to back up"* ]]
    [ -d "${GICKUP_BACKUP_DEST}/gitlab.com/someone/gl-star2.git" ]
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

@test "invalid settings are refused" {
    GICKUP_BACKUP_MAX_AGE_DAYS=five run "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"GICKUP_BACKUP_MAX_AGE_DAYS must be a whole number"* ]]

    GICKUP_BACKUP_GITHUB_ORG='org/../x' run "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"GICKUP_BACKUP_GITHUB_ORG is not an organisation name"* ]]

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
    # shellcheck disable=SC2016 # expanded by the fake git, not here
    use_fake_git 'kill -INT "${PPID}"'
    run "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Stopped after 1 repositories, before the backup finished"* ]]
    [ "$(grep -c '^argv=' "${FAKE_GIT_LOG}")" -eq 1 ]
    [ -d "${GICKUP_BACKUP_DEST}/github.com/me/own-a.git" ]
    [ ! -e "${GICKUP_BACKUP_DEST}/github.com/other/star-b.git" ]
}
