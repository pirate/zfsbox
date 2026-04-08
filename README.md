# zfsbox

> 🐚 Run ZFS in a Linux guest, keep the backing storage on the host, and surface pools back to the host as normal volumes.

`zfsbox` is a host-side wrapper around a Linux ZFS environment.

- On **macOS**, it currently runs ZFS inside a **Lima `vz` guest** and mounts pool roots back onto the host at `/Volumes/<pool>`.
- On **Linux**, the repo still contains the original **Firecracker + Docker** scaffold and guest-control tooling.

The current sweet spot is:

- create a sparse file on your host
- use it directly as a ZFS file vdev from inside the guest
- manage pools with `zpool` / `zfs` from your host shell
- access the mounted pool root on your host filesystem

## ✨ Features

- Host-side `zpool` and `zfs` wrappers
- macOS-backed pools using host files under `${HOME}` or `/Volumes`
- automatic host mounts at `/Volumes/<pool>` on macOS
- visible `.zfs/snapshot` trees on host mounts
- snapshot / clone / send / receive workflows through real ZFS tooling
- no Docker required on macOS

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
  -> Docker
    -> Firecracker scaffold
      -> Ubuntu guest
        -> OpenZFS
```

The macOS path is the most complete path in this repo right now.

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

### 4. Use it from the host

```bash
ls -la /Volumes/test
echo hello > /Volumes/test/test.txt
cat /Volumes/test/test.txt
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

Browse it from macOS:

```bash
ls -la /Volumes/test/.zfs/snapshot
ls -la /Volumes/test/.zfs/snapshot/one
cat /Volumes/test/.zfs/snapshot/one/test.txt
```

## 🧪 Common Workflows

### Create another pool

```bash
truncate -s 20G ~/Desktop/media.zpool
zpool create media ~/Desktop/media.zpool
```

It should appear at:

```bash
/Volumes/media
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
- [`scripts/reconcile-host-mounts.sh`](./scripts/reconcile-host-mounts.sh): exports guest filesystems and mounts them on the host
- [`zfsbox.aliases.sh`](./zfsbox.aliases.sh): shell aliases / functions

## ⚠️ Notes

- macOS currently uses **Lima directly**, not Firecracker, because Firecracker requires a Linux/KVM path and this machine rejected nested virtualization for the old macOS route.
- Host-backed file vdevs must live under paths mounted into the guest. The current macOS wrapper exposes `${HOME}` and `/Volumes`.
- Host-visible pool mounts are implemented with **guest-side NFS**.
- macOS host mountpoints under `/Volumes/<pool>` may require re-auth with Touch ID when reconciling mounts.
- The Linux Firecracker scaffold is still in the repo, but the macOS Lima path is the tested one.

## 📚 References

- [Lima `vz` docs](https://lima-vm.io/docs/config/vmtype/vz/)
- [Lima networking docs](https://lima-vm.io/docs/config/network/)
- [Firecracker](https://github.com/firecracker-microvm/firecracker)
- [OpenZFS documentation](https://openzfs.github.io/openzfs-docs/)
- [ZFS `snapdir` property](https://openzfs.github.io/openzfs-docs/man/master/7/zfsprops.7.html)

## 🗺 Roadmap

- make Linux host mounts mirror the macOS `/Volumes/<pool>` experience under `/mnt/<pool>`
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
