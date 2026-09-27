# homelab-runners

Self-hosted GitHub Actions runner images and deployment files for a single
home server (Arch Linux, rootless Podman 6, quadlets).

- **Ephemeral:** each container registers one [just-in-time (JIT) runner],
  runs at most one job and exits. systemd starts a fresh container for the
  next job.
- **Rootless all the way down:** the runners run in rootless Podman under a
  dedicated user, and jobs can build and run containers with rootless
  podman/buildah nested inside the runner container. No Docker daemon, no
  Podman socket, no `--privileged`.
- **GitHub App authentication:** the runner registers itself with a
  short-lived, repository-scoped installation token. No personal access token.

The images are built on GitHub-hosted runners and published to GHCR:

| Runner type | Image | Contents |
|---|---|---|
| `build` | `ghcr.io/gidw/homelab-runners/build` | [`ghcr.io/actions/actions-runner`] (Ubuntu 24.04) + podman, buildah, fuse-overlayfs, uidmap, passt, slirp4netns |

Tags: `latest` and `<runner version>` (e.g. `2.337.0`) from `main`,
`sha-<commit>`, and `YYYYMMDD` from the weekly rebuild.

[just-in-time (JIT) runner]: https://docs.github.com/en/rest/actions/self-hosted-runners#create-configuration-for-a-just-in-time-runner-for-a-repository
[`ghcr.io/actions/actions-runner`]: https://github.com/actions/runner/pkgs/container/actions-runner

## Layout

```
build/Containerfile                    the `build` runner image
common/entrypoint.sh                   GitHub App auth + JIT registration (all runner types)
common/containers.conf, storage.conf   nested rootless podman configuration
deploy/quadlet/github-runner@.container  quadlet template, instance = repository
deploy/quadlet/gh-runner.network       network for the runners
deploy/env/example.env                 per-repository settings
deploy/host/ghrunner-egress.nft        nftables egress filter (no LAN access)
```

## Security model

**Only attach these runners to private repositories that only you (or people
you trust with a shell on the server) can push to.** A job runs whatever the
workflow says, with network access, on your hardware.

- **Never use them for public repositories.** Anyone can open a pull request
  against a public repository, and GitHub's own guidance is that self-hosted
  runners should almost never be used for public repositories. The same goes
  for private repositories where untrusted people can open pull requests.
  This repository is itself public, so its own workflow always runs on
  `ubuntu-latest`.
- **Isolation is Linux namespaces, not a VM.** Container root is an
  unprivileged sub-UID of the `ghrunner` host user. The kernel is shared, so
  a kernel exploit escapes; keep the host kernel updated.
- **Separate host user.** `ghrunner` owns nothing but the runners: its own
  container storage, podman secrets and sub-UID range. Don't run the runners
  as the user that runs your other services.
- **No host mounts, no Podman socket.** A job can't see host files or control
  other containers. Nested containers live inside the runner container.
- **Ephemeral.** Nothing (workspace, caches, credentials, background
  processes, nested images) survives into the next job. The container and its
  anonymous storage volume are removed after every job.
- **No LAN access.** `deploy/host/ghrunner-egress.nft` drops traffic from the
  `ghrunner` user to private (RFC 1918), CGNAT/Tailscale (`100.64.0.0/10`),
  loopback, link-local and multicast addresses, and to IPv6 ULA/link-local;
  only the host's DNS resolver stays reachable on port 53. The public
  internet is allowed. A future `deploy` runner type that needs the LAN will
  get its own user or rules.
- **Resource limits.** Memory, CPU and PID limits per container and a low
  `CPUWeight` so a build doesn't starve other services.
- **The App key is not readable by jobs.** The entrypoint starts as root,
  reads the key (mounted as uid 0, mode 0400), gets a JIT config, revokes the
  installation token, clears its variables and drops to the `runner` user.
  The image has **no sudo and no setuid binaries**, so jobs can't become root
  in the container to read the key. What a job can do is limited to what the
  workflow's `GITHUB_TOKEN` and secrets allow, as on GitHub-hosted runners.

### GitHub App instead of a personal access token

A GitHub App with one repository permission (Administration: write) is used to
create runners. Compared with a PAT:

- The key is not tied to your user account and grants nothing you didn't
  select. A classic PAT needs the `repo` scope, which is full access to all
  your repositories.
- Installation tokens expire after an hour. The entrypoint also narrows each
  token to the one repository it registers for and revokes it right after
  use.
- You choose which repositories the App is installed on, and can revoke the
  key or uninstall the App in one place.

The App private key is still sensitive: anyone with it can create runners (and
change settings) on every repository the App is installed on. Keep it only in
the podman secret.

## GitHub App setup

On a personal account (no organisation), runners can only be registered per
repository, so the App is installed on each repository that uses the runners.

1. **Settings → Developer settings → GitHub Apps → New GitHub App.**
   - Name: anything unique, e.g. `gidw-homelab-runners`.
   - Homepage URL: this repository.
   - **Webhook: untick "Active"** (not needed).
   - **Repository permissions → Administration: Read and write.** Nothing
     else (Metadata: Read-only is added automatically).
   - No organisation or account permissions, no events.
   - **Where can this GitHub App be installed: Only on this account.**
2. Create the App and note its **App ID** (or Client ID, both work).
3. **Generate a private key** and download the `.pem`.
4. **Install App → Only select repositories** → pick the private
   repositories that should use the runners. You can add repositories later
   under the installation's settings.

## Host setup

Run as root unless noted. The examples use a sub-ID range starting at
2,000,000; pick one that doesn't overlap existing entries in
`/etc/subuid`/`/etc/subgid`.

```sh
# Dedicated user, no password login
useradd --create-home ghrunner
passwd --lock ghrunner

# Sub-IDs: at least 165,536 are needed (runner container + nested podman),
# 1,000,000 leaves room
usermod --add-subuids 2000000-2999999 --add-subgids 2000000-2999999 ghrunner

# Keep the user's systemd running without a login
loginctl enable-linger ghrunner

# Egress filter (persist: include "/etc/nftables.d/*.nft" in /etc/nftables.conf)
install -D -m 0644 deploy/host/ghrunner-egress.nft /etc/nftables.d/ghrunner-egress.nft
$EDITOR /etc/nftables.d/ghrunner-egress.nft   # set dns4/dns6 to the host's resolvers
nft -f /etc/nftables.d/ghrunner-egress.nft
```

Consider putting `~ghrunner/.local/share/containers` on its own filesystem or
subvolume with a quota, so a runaway build can't fill the disk.

Then as `ghrunner` (`machinectl shell ghrunner@` gives a proper user session):

```sh
mkdir -p ~/.config/containers/systemd ~/.config/homelab-runners
cp deploy/quadlet/github-runner@.container deploy/quadlet/gh-runner.network \
   ~/.config/containers/systemd/

# The App private key, as a podman secret; then delete the downloaded file
podman secret create github-app-key ./gidw-homelab-runners.private-key.pem
shred -u ./gidw-homelab-runners.private-key.pem
```

If `ghrunner` used podman before its sub-ID range was set, run
`podman system migrate` once.

Adjust `Memory=`, `PodmanArgs=--cpus=` and `PidsLimit=` in the template to the
machine. Each enabled repository holds one runner container at all times, so
the limits apply per repository.

## Adding a repository

The repository must be private and the App must be installed on it. As
`ghrunner`:

```sh
repo=media-gallery
cp deploy/env/example.env ~/.config/homelab-runners/$repo.env
$EDITOR ~/.config/homelab-runners/$repo.env        # GITHUB_APP_ID, RUNNER_REPOSITORY

cd ~/.config/containers/systemd
ln -s github-runner@.container github-runner@$repo.container
systemctl --user daemon-reload
systemctl --user start github-runner@$repo          # enabled via [Install]
journalctl --user -u github-runner@$repo -f
```

The runner appears under the repository's **Settings → Actions → Runners**
with a new name for every job. To remove a repository, stop the unit and
delete the symlink and env file; its last idle runner is removed by GitHub
after a day offline.

Settings in the env file (`podman --env-file` format: no quotes):

| Variable | Default | |
|---|---|---|
| `GITHUB_APP_ID` | *(required)* | App ID or Client ID |
| `RUNNER_REPOSITORY` | *(required)* | `owner/repo` |
| `RUNNER_LABELS` | `self-hosted,Linux,<X64\|ARM64>,home` | JIT runners get only the labels you pass |
| `RUNNER_GROUP_ID` | `1` | the default runner group |
| `RUNNER_NAME_PREFIX` | `home-<repo>` | a timestamp and random suffix are added |
| `RUNNER_FAIL_DELAY` | `30` | seconds to wait before exiting on error, to avoid a tight restart loop |
| `GITHUB_APP_KEY_FILE` | `/run/secrets/github-app-key` | |
| `GITHUB_API_URL` | `https://api.github.com` | |

## Using the runner in a workflow

```yaml
jobs:
  image:
    runs-on: [self-hosted, home]
    steps:
      - uses: actions/checkout@v7
      - uses: redhat-actions/buildah-build@v3
        with:
          containerfiles: Containerfile
          tags: ghcr.io/you/app:latest
```

What's different from `ubuntu-latest`:

- **No sudo** (see the security model). Tools the jobs need go into the image.
- **No Docker daemon**, so no `container:` jobs, `services:` or
  `docker/build-push-action`. Use `redhat-actions/buildah-build`,
  `push-to-registry` and `podman-login`, and `podman run` instead of
  `docker run`. These work the same on `ubuntu-latest`, which has podman and
  buildah preinstalled.
- Podman 4.9 and Buildah 1.33 (Ubuntu 24.04), like `ubuntu-latest`. Nested
  containers share the runner container's network, and builds use
  `BUILDAH_ISOLATION=chroot`.
- **Ephemeral: no local caches.** Use `actions/cache` or a registry layer
  cache.

## How nested rootless podman works here

- The host user `ghrunner` has ≥ 165,536 sub-IDs, so the runner container has
  uids 0–165,535 (and more) mapped.
- Inside, `runner` (uid 1001) has `runner:100000:65536` in `/etc/subuid` and
  `/etc/subgid`. Nested podman/buildah use them through `newuidmap` and
  `newgidmap`.
- `newuidmap`/`newgidmap` carry the file capabilities `cap_setuid=ep` /
  `cap_setgid=ep` (as on Fedora and in `quay.io/podman/stable`) instead of
  being setuid root. That needs `SETUID`/`SETGID` in the container's bounding
  set and `NoNewPrivileges` off, because the kernel ignores file capabilities
  under no-new-privileges.
- `SYS_CHROOT` is kept because Podman's default seccomp profile allows
  `chroot(2)` only with it, and buildah's chroot isolation uses it.
- Storage is overlay through `fuse-overlayfs` (`/dev/fuse` is passed in) on an
  anonymous volume. `containers.conf` (from `quay.io/podman/stable`) makes
  nested containers share the runner's network and other namespaces, disables
  cgroups for them and bind-mounts `/proc`, so no extra privileges or
  unmasked paths are needed.
- Everything else uses the defaults: default seccomp profile, masked paths,
  no `--privileged`.

## Runner version and updates

- The image pins `ghcr.io/actions/actions-runner:<version>@<digest>`.
  Renovate opens a PR when a new runner is released; merging it rebuilds and
  pushes the image, and every new container starts with `Pull=newer`, so the
  new version arrives with the next job.
- **Auto-update can't be disabled for JIT runners.** `--disableupdate` is a
  `config.sh` flag. `run.sh --jitconfig` only accepts `--once`,
  `--jitconfig` and `--startuptype` (`src/Runner.Listener/CommandSettings.cs`
  in actions/runner), and the JIT config API has no such field. So a JIT
  runner behind the latest release updates itself when it gets a job, which
  costs time on every job until the image is rebuilt.
- GitHub requires runners with auto-update disabled to be updated within
  30 days of a new release and stops queueing jobs to them after that. That
  rule targets `--disableupdate` runners, but keeping the image current
  avoids both problems: merge the Renovate runner PRs promptly.
- The weekly scheduled build picks up Ubuntu security updates. GitHub
  disables scheduled workflows in public repositories after 60 days without
  activity; Renovate PRs usually keep the repository active.

## Image signing

If the repository secrets `COSIGN_PRIVATE_KEY` and `COSIGN_PASSWORD` are set,
CI signs each pushed digest with that key (`cosign generate-key-pair`). The
host can then enforce signatures in `/etc/containers/policy.json`
(`sigstoreSigned` with `keyPath`, plus `use-sigstore-attachments: true` in
`registries.d`).

## GitHub API reference

Checked against docs.github.com (REST API version `2022-11-28`) and the
actions/runner source on 2026-09-28.

| Step | Request | Auth | Response |
|---|---|---|---|
| JWT | RS256; claims `iat` (60 s in the past), `exp` (≤ 10 min ahead), `iss` = Client ID or App ID | App private key | |
| Find the installation | `GET /repos/{owner}/{repo}/installation` | JWT | `200`, installation object (`id`) |
| Installation token | `POST /app/installations/{installation_id}/access_tokens`, body `{"repositories": [...], "permissions": {...}}` (both optional, narrow the token) | JWT | `201`, `token`, `expires_at` (1 h) |
| JIT config | `POST /repos/{owner}/{repo}/actions/runners/generate-jitconfig`, body `name`, `runner_group_id`, `labels` (1–100) required, `work_folder` optional (`_work`) | installation token | `201`, `runner` (object with `id`), `encoded_jit_config`; `409` name exists; `422` validation or rate limit |
| Revoke token | `DELETE /installation/token` | installation token | `204` |

- Permission: `generate-jitconfig` (and the other repository runner
  endpoints) need the repository permission **Administration: write**
  (docs: "Permissions required for GitHub Apps", section *Repository
  permissions for "Administration"*). Organisation runners would need the
  organisation permission *Self-hosted runners* instead.
- A JIT runner does at most one job and is then removed; an ephemeral runner
  that doesn't connect for a day is removed automatically.
- Sources: [self-hosted runner REST API], [GitHub App REST API],
  [generating a JWT], [permissions for GitHub Apps], [self-hosted runner
  reference] (auto-update, 30-day rule), [secure use reference] (public
  repositories), [removing runners] (automatic removal).

[self-hosted runner REST API]: https://docs.github.com/en/rest/actions/self-hosted-runners
[GitHub App REST API]: https://docs.github.com/en/rest/apps/apps
[generating a JWT]: https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app
[permissions for GitHub Apps]: https://docs.github.com/en/rest/authentication/permissions-required-for-github-apps
[self-hosted runner reference]: https://docs.github.com/en/actions/reference/runners/self-hosted-runners
[secure use reference]: https://docs.github.com/en/actions/reference/security/secure-use
[removing runners]: https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/remove-runners

## Verify on the host

Tested so far in a Podman 6.1.2 machine (Fedora CoreOS, kernel 7.1, rootless,
SELinux enforcing), not yet on the Arch server:

- nested `podman run` and `buildah build` as `runner` with exactly
  `DropCapability=ALL` + `SETUID SETGID SYS_CHROOT`, `/dev/fuse`, default
  seccomp. SELinux also required `SecurityLabelDisable=true`, which doesn't
  apply on Arch;
- the file capabilities surviving a rootless `buildah`/`podman build`;
- the nftables rules matching pasta's traffic by `meta skuid` (LAN blocked,
  DNS and internet working);
- the entrypoint against the real API up to authentication, and the whole
  flow against a mock API.

Still to check on the server:

- [ ] End-to-end with the real App: registration, a job, exit, restart.
- [ ] Nested podman/buildah on the Arch kernel with the quadlet settings.
- [ ] Native overlay instead of fuse-overlayfs in `storage.conf` (faster), if
      the kernel allows it.
- [ ] `nft` rules: DNS resolver addresses in `dns4`/`dns6`; runners can reach
      GitHub and GHCR but not the LAN, the tailnet or `host.containers.internal`.
- [ ] cgroup delegation for `ghrunner` includes `memory pids cpu`
      (`cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers`),
      so `Memory=`, `PidsLimit=`, `--cpus` and `CPUWeight=` take effect.
- [ ] `Pull=newer` when GHCR is unreachable: the container should still start
      from the local image.
- [ ] `RUNNER_GROUP_ID=1` accepted for repository runners.
- [ ] The runner shows the labels `self-hosted, Linux, X64, home` and a job
      with `runs-on: [self-hosted, home]` is picked up.
- [ ] `Memory=6g`, `--cpus=3` and `PidsLimit=4096` fit the machine and the
      builds; the sub-ID range doesn't overlap other users.
- [ ] All pushed tags resolve to the same digest (`skopeo inspect`), so the
      signature covers them.
