# claude-sandbox

Runs the Claude Code TUI with `--dangerously-skip-permissions` inside a
[smolvm](https://github.com/smol-machines/smolvm) microVM, so the guardrails
come from a VM boundary (its own kernel, behind a KVM/Hypervisor.framework
VMM) rather than from per-action permission prompts. Docker Engine runs inside
the VM, so the agent can build and run containers without any access to the
host's Docker.

It's set up for blind users. Claude Code starts in screen reader mode
(`--ax-screen-reader`) with Remote Control enabled (`--remote-control`). To
change that, edit `CLAUDE_CMD` near the top of `claude-sandbox`.

## Requirements

- **Linux** with KVM (`/dev/kvm` present), or **macOS** on Apple silicon.
  So far this has been tested only on Linux on arm64 (a Raspberry Pi CM4
  and an NVIDIA DGX Spark); macOS and x86-64 Linux should work but are
  untested.
- **Python 3.8 or later.** The launcher uses only the standard library, so
  macOS's built-in `python3` works.
- **git** and **curl**.
- About **8 GB of RAM** and **10 GB of free disk**. Building uses a VM with
  up to 3 GB of memory, sessions use up to 4 GB by default, and the built
  image plus smolvm's caches took about 9 GB.
- No Docker is needed on the host.

## Setup

1. On Linux, let your user run VMs. Skip this if `id -nG` already lists
   `kvm`. Otherwise run the command below, then log out and back in:

   ```sh
   sudo usermod -aG kvm "$USER"
   ```

2. Install [smolvm](https://github.com/smol-machines/smolvm). Its installer
   puts it in `~/.smolvm`, links it into `~/.local/bin`, and adds that
   directory to your PATH in your shell profile if it isn't there already.
   If the installer says it changed your profile, open a new terminal
   afterwards.

   ```sh
   curl -sSL https://smolmachines.com/install.sh | bash
   smolvm --version
   ```

3. Get this repository and put the launcher on your PATH. Symlink it rather
   than copying it: sessions would work from a copy, but `build` needs the
   Dockerfile next to the real script, and it follows the symlink to find
   it.

   ```sh
   git clone https://github.com/mwcampbell/claude-sandbox ~/claude-sandbox
   ln -s ~/claude-sandbox/claude-sandbox ~/.local/bin/claude-sandbox
   ```

4. Build the sandbox image. This takes a while: about 4 minutes on an
   NVIDIA DGX Spark, but about 35 minutes on a Raspberry Pi CM4. It prints
   progress as it goes.

   ```sh
   claude-sandbox build
   ```

5. Create a login profile for each Claude account you want to use, named
   however you like. Each command starts a fresh sandbox running Claude
   Code. Log in, then `/quit`, and the login is saved. If the browser can't
   hand the login back to the sandbox, paste the code it shows at the
   "Paste code here" prompt.

   ```sh
   claude-sandbox login personal
   claude-sandbox login work
   ```

## Use

From the directory you want the agent to work on:

```sh
claude-sandbox run personal     # Claude Code, logged in as "personal"
claude-sandbox shell [PROFILE]  # zsh in the same environment
claude-sandbox exec CMD [ARG..] # any other command, without a profile
claude-sandbox login PROFILE    # create a profile, or log it in again
claude-sandbox profiles         # list saved profiles
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
holds the agent's Docker images and containers), `CLAUDE_SANDBOX_HOME`
(default `~/.cache/claude-sandbox`), and `CLAUDE_SANDBOX_PROFILES` (default
`~/.config/claude-sandbox/profiles`).

### Profiles

A profile holds only a Claude Code login, so sessions start logged in, while
everything else in `~/.claude` stays ephemeral: no session history, resumable
sessions, memories, or settings changes carry over.

- A profile directory holds two files, readable only by you:
  `credentials.json`, Claude Code's OAuth tokens, and `claude.json`, the
  `~/.claude.json` from the login session with its per-project records
  removed. That keeps the account details and first-run choices (theme,
  accepting the bypass-permissions warning), so sessions skip onboarding.
- The VM never sees the profile directory itself. Each session gets a
  scratch copy. When it ends, the launcher keeps only the credentials, which
  Claude Code may have refreshed during the session.
- Running `login` on an existing profile replaces it. To delete a profile,
  delete its directory.
- The agent inside the VM can read the login tokens, as it could in any
  logged-in session.
- Avoid running two sessions with the same profile at once. Each refreshes
  its tokens independently, and one may invalidate the other's, which means
  logging in again.

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
  installs the profile's login files if there are any, then drops to the
  `agent` user and runs Claude. With a profile, it stays around to hand the
  login files back when Claude exits.

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

### Timing

A full build from scratch took about 4 minutes 15 seconds on an NVIDIA DGX
Spark. On a Raspberry Pi CM4 with an SD card, everything is much slower:

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
