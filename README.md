# 🗄️ `zfsbox`<br/> Run ZFS from userspace on macOS/Linux<br/><small>(without needing to install ZFS kernel modules / FUSE)</small>

> Magic `zpool` and `zfs` wrappers that make ZFS "just work" macOS, Linux, and Docker *without* needing the ZFS kernel module installed.

`zfsbox` works by running the actual ZFS kernel module inside a small linux VM, and exposing the mounts back to the host over NFSv4.

It allows you to run ZFS on macOS, Linux, or in Docker containers without having to mess around with FUSE, `/dev/zfs`, `dkms`, or `privileged: true`.

## ✨ Features

- Host-side `zpool` and `zfs` wrappers
- macOS-backed pools using block devices or files under `${HOME}`, `/Volumes`, or `/dev`
- Linux-backed pools using block devices or files anywhere under `/` or `/dev`.
- automatic host mounts at `/Volumes/<pool>` on macOS
- automatic mounts at `/mnt/<pool>` on Linux and inside the provided Docker service
- fully working `zfs send`, `zfs recv`, `zfs snapshot` + `.zfs/snapshot` dirs on host mounts, and more
- work inside Docker, Docker Compose, Docker Desktop, and Kubernetes as well (on Linux, macOS, and Windows hosts *without* needing ZFS installed in Docker VM)

## 🚀 Quick Start

### 1. Load the `zpool` and `zfs` command aliases (optional)

```bash
git clone https://github.com/pirate/zfsbox.git
cd zfsbox

source ./zfsbox.aliases.sh
```

This points `zfs` and `zpool` in the current shell to `./bin/zfsbox-zfs` and `./bin/zfsbox-zpool`.

(Not strictly necessary, you can also run `./bin/zfsbox-zpool ...` & `./bin/zfsbox-zfs ...` directly)

### 2. Create a backing file on the host (optional)

```bash
truncate -s 10G ~/Desktop/testpool.zpool
```

This is only needed if you want to use a file to store pool data (recommended) instead of a raw block device like `/dev/diskN`.

### 3. Create a pool

```bash
zpool create test ~/Desktop/testpool.zpool   # using a file to store the pool data
# or
zpool create test /dev/disk8 ...             # using real disk(s) for the pool vdevs
```

On macOS, the file-backed path above works with normal Lima releases. Raw host block devices like `/dev/diskN` or `/dev/rdiskN` need a `limactl` build that includes Lima PR [`#4866`](https://github.com/lima-vm/lima/pull/4866); see the macOS section below for the PATH-based install flow.

On macOS and Linux, the first run may request `sudo` permissions.
Root permissions are used to mount pool roots under `/Volumes` or `/mnt`; the `zpool` / `zfs` commands themselves stay rootless if you do not need host mounts.

### 4. Use it from the host

macOS:

```bash
ls -la /Volumes/test
echo hello > /Volumes/test/test.txt
cat /Volumes/test/test.txt
```

Linux:

```bash
ls -la /mnt/test
echo hello > /mnt/test/test.txt
cat /mnt/test/test.txt
```

## 🐳 Docker Usage

Use the provided [`docker-compose.yml`](./docker-compose.yml) in this repo as a template to modify.

Basic usage:

```bash
mkdir -p data mnt
truncate -s 10G ./data/test2.zpool

docker compose up -d --wait --wait-timeout 90
docker compose exec -T zfsbox zpool create test2 /data/test2.zpool
docker compose exec -T zfsbox sh -lc 'echo test > /mnt/test2/test.txt'
docker compose exec -T zfsbox cat /mnt/test2/test.txt
docker compose exec -T zfsbox zfs set snapdir=visible test2
docker compose exec -T zfsbox zfs snapshot test2@latest
docker compose exec -T zfsbox ls /mnt/test2/.zfs/snapshot/latest
docker compose exec -T zfsbox cat /mnt/test2/.zfs/snapshot/latest/test.txt

# optionally mount it on the host outside of docker
./bin/zfsbox-mount 127.0.0.1:12049 test2 ./mnt/test2
cat ./mnt/test2/test.txt
cat ./mnt/test2/.zfs/snapshot/latest/test.txt
```

Notes:

- The compose file pulls `ghcr.io/pirate/zfsbox:latest`, which is published for both `linux/amd64` and `linux/arm64`.
- `docker compose up -d --wait --wait-timeout 90` blocks until the inner guest is healthy and exits with an error if that does not happen before the timeout.
- The provided Compose service uses `CAP_SYS_ADMIN` so it can mount guest NFS exports at `/mnt/<pool>` inside the container. It does not require `privileged: true`.
- On Docker Desktop, the first cold `up --wait` usually takes tens of seconds because it boots an inner Linux guest before any ZFS command runs.
- If you are developing `zfsbox` itself locally, build your own image first and point compose at it:

```bash
docker build -t ghcr.io/pirate/zfsbox:dev .
ZFSBOX_IMAGE=ghcr.io/pirate/zfsbox:dev docker compose up -d
```

- Runtime state is stored automatically under `./data/.zfsbox/state`, so separate `docker compose run ...` and `docker compose up ...` invocations reuse the same known pools and datasets.
- Use <https://www.composerize.com/> if you prefer `docker run ...` instead of `docker compose ...`.

## 📸 Snapshots

Make snapshots visible under `.zfs`:

```bash
zfs set snapdir=visible test
```

Create a snapshot:

```bash
zfs snapshot test@one
```

Browse it from the host:

```bash
ls -la /Volumes/test/.zfs/snapshot   # macOS
ls -la /mnt/test/.zfs/snapshot       # Linux
```

## 🧪 Common Workflows

### Create another pool

```bash
truncate -s 20G ~/Desktop/media.zpool
zpool create media ~/Desktop/media.zpool
```

It should appear at:

```bash
/Volumes/media  # macOS
/mnt/media      # Linux
```

### Clone from a snapshot

```bash
zfs snapshot test@base
zfs clone test@base test/clone1
```

### Send / receive

```bash
zfs snapshot test@send1
zfs send test@send1 > /tmp/test.send
zfs receive restored < /tmp/test.send
```

### Destroy a pool

```bash
zpool destroy test
rm ~/Desktop/testpool.zpool   # dont forget to delete any backing file (if a file was used)
```

## 🛠 Commands

Use the wrappers directly:

```bash
./bin/zfsbox-zpool list
./bin/zfsbox-zfs list
```

Or use the aliases:

```bash
source ./zfsbox.aliases.sh
zpool status
zfs list
```

## Architecture

The sections below describe how each mode is actually implemented, what knobs exist, what the performance tradeoffs look like, and exactly when root permissions are used.

<details>
<summary><h3>How it works on macOS</h3></summary>

**Diagram**

```text
macOS `./bin/zfsbox-zpool`       (does not need to have ZFS installed)
  -> Lima Linux VM (vmType: vz, virtiofs, vzNAT)
    -> OpenZFS kernel module
    -> NFSv4 server to allow mounting /Volumes/<pool> on macOS host
```

**Details and tradeoffs**

This is the native macOS host path. `zfsbox` uses Lima directly with `vz`, `virtiofs`, and `vzNAT`, then runs ZFS and the export server inside that environment. Absolute host paths only work if they are visible inside the runtime; by default `zfsbox` exposes `${HOME}` and `/Volumes`, and `LIMA_VM_MOUNTS` can override that mount set.

The tradeoff is straightforward: this keeps the macOS host clean and avoids any host-side ZFS install, but it means backing files and visible paths have to live inside the mounted path set. Host-visible mounts are implemented by exporting guest mountpoints back to macOS and mounting them at `/Volumes/<pool>`, so mount reconciliation can trigger Touch ID or `sudo` re-auth when macOS needs to re-establish those mounts.

**Using Lima PR `#4866` for raw `/dev/diskN` passthrough**

Released Lima builds are enough for file-backed pools, but raw host block-device passthrough on macOS currently needs Lima PR [`#4866`](https://github.com/lima-vm/lima/pull/4866). That PR adds `limactl start --block-device=/dev/diskN` and the top-level `blockDevices:` config field for `vmType: vz`, and it exposes each attached device in the guest as a deterministic virtio block path like `/dev/disk/by-id/virtio-disk4`.

`zfsbox` does not hardcode any Lima path. It just runs `limactl` from `PATH`, so the easiest way to test that branch is to put your local PR build first in `PATH` before you run `zfsbox`:

```bash
git clone https://github.com/lima-vm/lima.git
cd lima
git fetch origin pull/4866/head:zfsbox-vz-block-device-sharing
git checkout zfsbox-vz-block-device-sharing
make native

export PATH="$PWD/_output/bin:$PATH"
limactl --version
cd /path/to/zfsbox
PATH="/path/to/lima/_output/bin:$PATH" ./bin/zfsbox-zpool create test /dev/disk4
```

Notes:

- `make native` builds `limactl`, the native guest agent, and the bundled templates that `zfsbox` expects.
- Keep the PATH override scoped to the shell or command if you still want Homebrew Lima installed side-by-side.
- Expect a narrow macOS `sudo` / Touch ID prompt when opening `/dev/diskN`; the PR keeps the main Lima VM process unprivileged and only escalates the helper that opens the block device.

**Mode-specific config**

- CLI flags: none. macOS mode is selected automatically on macOS hosts.
- Env vars:
  - `LIMA_INSTANCE_NAME`: name of the managed Lima instance.
  - `VM_MEMORY_MB`: memory budget.
  - `VM_VCPUS`: CPU count.
  - `LIMA_VM_RECREATE=true|false`: force the next run to delete and recreate the instance from scratch.
  - `LIMA_VM_MOUNTS=[...]`: JSON array of Lima mount objects. Each mount must resolve to the same guest path as its host `location`, and if `mountPoint` is omitted `zfsbox` fills it in automatically.
  - `ZFSBOX_STATE_DIR`: state root; macOS-specific state is kept under `.../macos-lima`.
- Compatibility fallback:
  - `INSTANCE_NAME` is accepted as a fallback source for the instance name when `LIMA_INSTANCE_NAME` is not set.

**Performance and tunables**

This is the best default path on macOS because it uses the native host hypervisor stack rather than a nested Docker workflow. First run is slower because the environment may need to install ZFS and NFS tooling before it is ready. After that, the main knobs are `VM_MEMORY_MB` and `VM_VCPUS`.

If you are working with large host trees, keeping `LIMA_VM_MOUNTS` tight helps reduce the exposed surface area. Putting `ZFSBOX_STATE_DIR` on a fast local disk also helps because it stores the persistent instance marker and related runtime state.

**When root is used**

`sudo` is never used on the macOS host to install ZFS or load any host kernel module. Host root is only used to create, mount, unmount, or clean up `/Volumes/<pool>` mountpoints. Inside the managed environment, root is used to install `zfsutils-linux` and `nfs-kernel-server`, run `modprobe zfs`, and manage guest exports. If you do not need host-visible mounts, the user-facing `zpool` / `zfs` commands stay rootless on the macOS host.

</details>

<details>
<summary><h3>How it works on Linux</h3></summary>

**Diagram**

```text
Linux `./bin/zfsbox-zpool`       (does not need to have ZFS installed)
  -> QEMU Linux VM (rootless, /dev/kvm when available)
    -> OpenZFS kernel module
    -> NFSv4 server to allow mounting /mnt/<pool> on Linux host
```

**Details and tradeoffs**

This is the native Linux host path. `zfsbox` starts a rootless QEMU guest, shares host `/` into it once, and rewrites absolute host paths to `${LINUX_QEMU_HOST_ROOT_MOUNT}` automatically so the guest can use normal host files and disks. Known pool paths are tracked under the Linux state directory, and the guest image, overlay, seed image, SSH key, and serial log all live under `state/linux-qemu` unless you override `ZFSBOX_STATE_DIR`.

The tradeoff here is that the guest itself stays rootless on the host, but host-visible mounts are still returned via guest-side NFS and mounted under `/mnt/<pool>`. `/dev/kvm` is optional for acceleration but not required for correctness. When it is missing or inaccessible, the guest falls back to software emulation and the whole stack becomes slower but still functional.

**Mode-specific config**

- CLI flags: none. Linux mode is selected automatically on Linux hosts.
- Env vars:
  - `LINUX_QEMU_VM_NAME`: guest name passed to QEMU.
  - `LINUX_QEMU_HOST_SHARE`: host path shared into the guest. Default is `/`.
  - `LINUX_QEMU_HOST_ROOT_MOUNT`: mountpoint inside the guest where the host share appears. Default is `/host`.
  - `VM_SSH_PORT`: forwarded localhost SSH port used to manage the guest.
  - `VM_NFS_PORT`: forwarded localhost NFS port used for host mounts.
  - `VM_MEMORY_MB`: memory budget.
  - `VM_VCPUS`: CPU count.
  - `GUEST_RELEASE`: Ubuntu cloud image release.
  - `LINUX_QEMU_WAIT_TIMEOUT`: guest readiness timeout in seconds.
  - `LINUX_QEMU_QEMU_BIN`: override the QEMU system binary.
  - `LINUX_QEMU_BUNDLED_BASE_IMAGE`: override the bundled cloud image path.
  - `LINUX_QEMU_ARM64_UEFI_FD`: override the ARM64 UEFI firmware path.
  - `ZFSBOX_STATE_DIR`: state root; Linux-specific state is kept under `.../linux-qemu`.
- Advanced/internal override:
  - `LINUX_QEMU_LAYOUT_VERSION` exists for layout invalidation and migration. You should not need to touch it in normal use.

**Performance and tunables**

With `/dev/kvm` available and accessible, this path is the fastest Linux configuration because QEMU can use hardware acceleration. Without KVM it falls back to `tcg`, which is correct but slower. First run is also slower because `zfsbox` may need to download the base Ubuntu cloud image, generate cloud-init data, and let the guest install `openssh-server`, `nfs-kernel-server`, and `zfsutils-linux`.

The main performance knobs are `VM_MEMORY_MB` and `VM_VCPUS`. `ZFSBOX_STATE_DIR` on a fast disk helps because the base image, overlay, seed image, and serial log live there. Narrowing `LINUX_QEMU_HOST_SHARE` from `/` to a smaller subtree can also reduce how much host filesystem surface is exposed into the guest.

**When root is used**

The QEMU guest itself is started rootlessly. `sudo` is never used on the Linux host to install ZFS or load a host kernel module. Host root is only used to create, mount, unmount, or clean up `/mnt/<pool>` mountpoints. Inside the guest, root is used to mount the host share at `${LINUX_QEMU_HOST_ROOT_MOUNT}`, manage ZFS, install guest packages, run `modprobe zfs`, and manage guest exports. If `ZFSBOX_SKIP_HOST_MOUNTS=1`, even the host-side mount step can be skipped.

</details>

<details>
<summary><h3>How it works in Docker</h3></summary>

**Diagram**

```text
Host OS                (does not need to have ZFS installed)
  -> Docker zfsbox container
    -> QEMU/KVM VM     (runs ZFS kernel module inside VM)
      -> OpenZFS kernel module
      -> NFSv4 server to allow mounting /mnt/<pool> inside/outside Docker
```

**Details and tradeoffs**

Docker mode wraps the Linux backend inside a long-lived container. The checked-in compose file binds `./data` to `/data`, so pool files, runtime state, and mount helper state all survive across `docker compose run ...`, `docker compose exec ...`, and `docker compose up ...` flows. `./bin/zfsbox-mount` can then mount the same exported pool on the outer host when port `12049` is published on `127.0.0.1`.

The tradeoff is that Docker mode is convenient and self-contained, but it adds another layer around the Linux backend. On a Linux Docker host, optional `/dev/kvm` passthrough can accelerate the guest substantially. On Docker Desktop or any environment without KVM passthrough, it falls back to software emulation and first boot is noticeably slower. The compose file is intentionally minimal and keeps the service alive with `sleep infinity` so you can use `docker compose exec ...` against a warm runtime.

**Mode-specific config**

- CLI flags: none. Use normal `docker compose ...` or `docker run ...` arguments around the container.
- Compose options in the checked-in `docker-compose.yml`:
  - `image: ${ZFSBOX_IMAGE:-ghcr.io/pirate/zfsbox:latest}`
  - `pull_policy: missing`
  - `cap_add: [SYS_ADMIN]`
  - `ports: ["127.0.0.1:12049:12049"]`
  - `command: ["sleep", "infinity"]`
  - `working_dir: /data`
  - `volumes: ["./data:/data"]`
- Env vars you can pass into the container:
  - All Linux backend vars apply here as well, including `GUEST_RELEASE`, `VM_MEMORY_MB`, `VM_VCPUS`, `VM_SSH_PORT`, `VM_NFS_PORT`, `LINUX_QEMU_VM_NAME`, `LINUX_QEMU_HOST_SHARE`, `LINUX_QEMU_HOST_ROOT_MOUNT`, `LINUX_QEMU_WAIT_TIMEOUT`, and `ZFSBOX_STATE_DIR`.
  - `ZFSBOX_SKIP_HOST_MOUNTS=1`: skip automatic mounts inside the container and just manage pools/datasets.
- Common optional YAML additions when you need them:
  - `/dev/kvm:/dev/kvm` on Linux Docker hosts for guest acceleration.
  - raw disk device mappings if you want to hand real block devices to `zpool create` instead of files.

**Performance and tunables**

The main performance knobs are still `VM_MEMORY_MB` and `VM_VCPUS`. Keeping `./data` on fast local storage helps because it holds both pool backing files and the persistent runtime state under `./data/.zfsbox/state`. On Linux hosts, adding `/dev/kvm` is the big acceleration switch. On Docker Desktop and similar environments without KVM passthrough, expect slower first boot because the guest is fully emulated and still has to provision its own packages on first run.

The published container image is built for both `linux/amd64` and `linux/arm64` with Docker Buildx and pushed to GHCR from GitHub Actions, so normal Docker users do not need to build locally before first use. `docker compose run --rm ...` and `docker compose up ...` still reuse the same persisted state as long as `./data` is the same bind mount, so repeated runs avoid reprovisioning once the runtime is warm.

**When root is used**

The container runs as root inside the container by default, but that does not mean `zfsbox` is installing ZFS on the outer host. `cap_add: SYS_ADMIN` is only needed so `zfsbox` can mount `/mnt/<pool>` inside the container. Without it, `zpool` / `zfs` commands still work and the export is still available; you just need to mount it elsewhere, either with `./bin/zfsbox-mount` on the outer host or with a manual mount or Docker NFS volume.

If you publish `127.0.0.1:12049:12049`, the outer host can mount the same pool through `./bin/zfsbox-mount`. On the outer host, root is only used for the actual mount command and mountpoint management; it is never used to install host ZFS or load a host ZFS kernel module.

</details>

## 📁 Important Files

- [`bin/zfsbox-zpool`](./bin/zfsbox-zpool): host-side `zpool` wrapper
- [`bin/zfsbox-zfs`](./bin/zfsbox-zfs): host-side `zfs` wrapper
- [`bin/zfsbox-guest-exec`](./bin/zfsbox-guest-exec): OS switchboard into the supported guest runner
- [`scripts/macos-lima-zfs-exec.sh`](./scripts/macos-lima-zfs-exec.sh): macOS execution path
- [`scripts/linux-qemu-zfs-exec.sh`](./scripts/linux-qemu-zfs-exec.sh): Linux execution path
- [`scripts/linux-qemu-common.sh`](./scripts/linux-qemu-common.sh): Linux guest lifecycle / cloud-init / SSH bootstrap
- [`scripts/reconcile-host-mounts.sh`](./scripts/reconcile-host-mounts.sh): mounts guest filesystems back onto the host
- [`zfsbox.aliases.sh`](./zfsbox.aliases.sh): shell aliases / functions

## 📚 References

- [Lima `vz` docs](https://lima-vm.io/docs/config/vmtype/vz/)
- [Lima networking docs](https://lima-vm.io/docs/config/network/)
- [QEMU invocation docs](https://www.qemu.org/docs/master/system/invocation.html)
- [OpenZFS documentation](https://openzfs.github.io/openzfs-docs/)
- [ZFS `snapdir` property](https://openzfs.github.io/openzfs-docs/man/master/7/zfsprops.7.html)
- https://docs.zfsbootmenu.org/en/v3.1.x/
- https://github.com/whoschek/bzfs
- https://github.com/jonmatifa/zfsmanager
- https://github.com/pirate/zfs.wizard

## 🗺 Roadmap

- improve the Linux guest share transport beyond the current rootless QEMU baseline
- improve stale mount cleanup and mount-state reporting
- support more explicit backing-store helpers for multi-pool workflows

## 🤝 Publishing

This repo is meant to be hackable. The implementation is intentionally shell-heavy and easy to trace:

```bash
./bin/zfsbox-zpool create demo ~/Desktop/demo.zpool
./scripts/reconcile-host-mounts.sh
```

If something goes wrong, the first places to inspect are:

macOS:

```bash
limactl list
mount | grep /Volumes
```

Linux:

```bash
ps -fp "$(cat state/linux-qemu/qemu.pid 2>/dev/null)"
mount | grep /mnt
```
