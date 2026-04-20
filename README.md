# 🗄️ `zfsbox`<br/> Run virtualized ZFS from userspace on macOS/Linux<br/><small>(without needing to install ZFS kernel modules!)</small>

> 🐚 Run ZFS in a Linux VM using any `/dev/diskN` or file on the host machine as the backing store. Exposes pools & datasets back to the host as normal volumes under `/mnt` or `/Volumes` (via NFSv4).

`zfsbox` is a host-side wrapper around a Linux ZFS environment.

- On **macOS**, it runs ZFS inside a **Lima `vz` guest** (using native macOS hypervisor framework) and mounts pool roots back onto the host at `/Volumes/<pool>`.
- On **Linux**, it runs a **rootless QEMU guest** with host path passthrough and automatic host mounts under `/mnt/<pool>`.

The current sweet spot is:

- create a sparse file on your host
- use it directly as a ZFS file vdev from inside the guest
- manage pools with `zpool` / `zfs` from your host shell
- access the mounted pool root on your host filesystem

## ✨ Features

- Host-side `zpool` and `zfs` wrappers
- macOS-backed pools using host files under `${HOME}` or `/Volumes`
- Linux-backed pools using arbitrary absolute host paths under `/`
- automatic host mounts at `/Volumes/<pool>` on macOS
- automatic host mounts at `/mnt/<pool>` on Linux
- visible `.zfs/snapshot` trees on host mounts
- snapshot / clone / send / receive workflows through real ZFS tooling
- no Docker required on macOS or Linux

## 🧭 Architecture

### macOS

```text
macOS
  -> Lima (vmType: vz, virtiofs, vzNAT)
    -> Ubuntu guest
      -> OpenZFS
        -> NFS export back to macOS
          -> /Volumes/<pool>
```

### Linux

```text
Linux
  -> QEMU (rootless, /dev/kvm when available)
    -> Ubuntu guest
      -> OpenZFS
        -> NFSv4 back to /mnt/<pool>
```

## 🚀 Quick Start

### 1. Load the aliases

```bash
cd /Users/squash/Local/Code/zfsbox
source ./zfsbox.aliases.sh
```

This overrides `zfs` and `zpool` in the current shell only.

### 2. Create a backing file on the host

```bash
truncate -s 10G ~/Desktop/testpool.zpool
```

### 3. Create a pool

```bash
zpool create test ~/Desktop/testpool.zpool
```

On macOS, the first mutating command may ask for Touch ID because `zfsbox` mounts pool roots under `/Volumes`.
On Linux, `zfsbox` keeps the VM itself rootless and only uses `sudo` when it needs to prepare `/mnt/<pool>`.

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
rm ~/Desktop/testpool.zpool
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

## 📁 Important Files

- [`bin/zfsbox-zpool`](./bin/zfsbox-zpool): host-side `zpool` wrapper
- [`bin/zfsbox-zfs`](./bin/zfsbox-zfs): host-side `zfs` wrapper
- [`scripts/macos-lima-zfs-exec.sh`](./scripts/macos-lima-zfs-exec.sh): macOS Lima execution path
- [`scripts/linux-qemu-zfs-exec.sh`](./scripts/linux-qemu-zfs-exec.sh): Linux rootless QEMU execution path
- [`scripts/reconcile-host-mounts.sh`](./scripts/reconcile-host-mounts.sh): mounts guest filesystems back onto the host
- [`zfsbox.aliases.sh`](./zfsbox.aliases.sh): shell aliases / functions

## ⚠️ Notes

- macOS currently uses **Lima directly**, not Firecracker, because Firecracker requires a Linux/KVM path and this machine rejected nested virtualization for the old macOS route.
- Host-backed file vdevs must live under paths mounted into the guest. The current macOS wrapper exposes `${HOME}` and `/Volumes`.
- The current Linux wrapper shares host `/` into the guest once and rewrites absolute host paths to `/host/...` automatically.
- Host-visible pool mounts are implemented with **guest-side NFS** on macOS and **guest-side NFSv4 over localhost port forwarding** on Linux.
- macOS host mountpoints under `/Volumes/<pool>` may require re-auth with Touch ID when reconciling mounts.
- On Linux, `/dev/kvm` is optional for acceleration but not required for correctness; `/mnt/<pool>` preparation is the only step that needs `sudo`.
- The current rootless Linux runner is implemented for `x86_64` hosts first and expects `qemu-system-x86_64`, `qemu-img`, one cloud-init seed-image builder, and host NFS client tools.

## 📚 References

- [Lima `vz` docs](https://lima-vm.io/docs/config/vmtype/vz/)
- [Lima networking docs](https://lima-vm.io/docs/config/network/)
- [Firecracker](https://github.com/firecracker-microvm/firecracker)
- [QEMU invocation docs](https://www.qemu.org/docs/master/system/invocation.html)
- [OpenZFS documentation](https://openzfs.github.io/openzfs-docs/)
- [ZFS `snapdir` property](https://openzfs.github.io/openzfs-docs/man/master/7/zfsprops.7.html)

## 🗺 Roadmap

- improve the Linux guest share transport beyond the current rootless QEMU baseline
- improve stale mount cleanup and mount-state reporting
- support more explicit backing-store helpers for multi-pool workflows
- revisit Firecracker on macOS only if a host-compatible Linux/KVM substrate is consistently available

## 🤝 Publishing

This repo is meant to be hackable. The implementation is intentionally shell-heavy and easy to trace:

```bash
./bin/zfsbox-zpool create demo ~/Desktop/demo.zpool
./scripts/reconcile-host-mounts.sh
```

If something goes wrong, the first places to inspect are:

```bash
limactl list
mount | grep /Volumes
zpool status
zfs list
```
