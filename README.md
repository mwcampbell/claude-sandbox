# claude-sandbox

Runs the Claude Code TUI with `--dangerously-skip-permissions` inside a
[smolvm](https://github.com/smol-machines/smolvm) microVM, so the guardrails
come from a VM boundary (its own kernel, behind a KVM/Hypervisor.framework
VMM) rather than from per-action permission prompts. Docker Engine runs inside
the VM, so the agent can build and run containers without any access to the
host's Docker.

It's set up for blind users. Claude Code starts in screen reader mode
(`--ax-screen-reader`) with Remote Control enabled (`--remote-control`). To
change that, edit the default command near the bottom of `claude-sandbox`.

## Setup

```sh
curl -sSL https://smolmachines.com/install.sh | bash   # installs smolvm into ~/.smolvm
./claude-sandbox build                                  # one-time, slow (see below)
ln -s "$PWD/claude-sandbox" ~/.local/bin/claude-sandbox  # put it on your PATH
```

Symlink the script rather than copying it. Sessions would work from a copy,
but `build` needs the Dockerfile next to the real script, and it follows the
symlink to find it.

On Linux your user needs access to `/dev/kvm` (be in the `kvm` group). On
macOS, smolvm needs Apple silicon. No Docker is needed on the host.

## Use

From the directory you want the agent to work on:

```sh
claude-sandbox                  # Claude Code, in an ephemeral VM
claude-sandbox shell            # zsh in the same environment
claude-sandbox run CMD [ARG..]  # any other command
claude-sandbox build            # rebuild after editing the Dockerfile
claude-sandbox clean            # delete the builder VM and built image
```

Every session is a fresh VM, discarded on exit, like `docker run --rm`.
Containers and images the agent creates with Docker are discarded along with
it. The VM sees exactly one host directory, the current one, mounted at
`/home/agent/project`. `~/.gitconfig` is copied in. The VM has outbound
network access.

Tunables (environment variables): `CLAUDE_SANDBOX_CPUS` (default 4),
`CLAUDE_SANDBOX_MEM` in MiB (default 4096; this is a cap, and the host only
commits what the guest touches), `CLAUDE_SANDBOX_STORAGE` in GiB (default 20;
holds the agent's Docker images and containers), and `CLAUDE_SANDBOX_HOME`
(default `~/.cache/claude-sandbox`).

## How it works

- `Dockerfile` defines the sandbox image, as before, plus Docker Engine.
- `claude-sandbox build` boots a persistent **builder microVM**
  (`smolvm/builder.smolfile`: bare Alpine + dockerd), runs `docker build` in
  it, and `docker save`s the result. The builder VM keeps Docker's layer cache
  between builds and is stopped when the build ends.
- The image archive is then turned into a **`.smolmachine` pack**: booted
  once in a throwaway machine to unpack it, then `smolvm pack create
  --from-vm`. Sessions are `smolvm machine run --from` that pack.
- `sandbox-entrypoint` runs at the start of every session: it starts dockerd,
  then drops to the `agent` user and execs Claude.

### smolvm quirks this works around

- **Docker's data must live on an ext4 disk.** A smolvm guest's root
  filesystem is an overlay, and Docker's overlay2 snapshotter can't use it.
  The entrypoint bind-mounts `/var/lib/docker` and `/var/lib/containerd` from
  the machine's ext4 data disk (`/workspace` in image machines, `/storage` in
  the builder).
- **Packs drop the image config.** `USER`, `ENV`, `ENTRYPOINT` and `CMD` are
  lost. The Dockerfile snapshots its environment into `/etc/sandbox-env`, the
  entrypoint restores it and switches to `agent` itself, and the launcher
  passes the command explicitly.
- **virtiofs can only share directories,** so `~/.gitconfig` is passed in by
  value and written by the entrypoint.
- **`init` in a Smolfile runs only on a machine's first boot,** so the
  builder's bind mounts and dockerd are set up again on every build.
- **Sessions use the `virtio-net` network backend.** smolvm's default (TSI)
  gives the guest no real network interface. smolvm's docs call for
  virtio-net when running a container runtime in the guest.

### Timing (Raspberry Pi CM4, SD card)

- A build from scratch took about 35 minutes. A rebuild that reuses the
  builder's layer cache still took about 27 minutes. Most of that is fixed
  cost: exporting, unpacking, and recompressing the roughly 3 GB image
  (around 7 minutes each).
- The first session from a new pack spent about 3 minutes extracting it into
  smolvm's cache.
- After that, a session reaches its shell or Claude in about 18 seconds,
  including starting dockerd.
- Disk use: the pack is about 860 MB, and `~/.cache/smolvm` (the builder's
  disk plus the extracted pack) was about 8 GB.
