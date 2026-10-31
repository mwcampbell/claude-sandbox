# claude-sandbox

Runs the Claude Code TUI with `--dangerously-skip-permissions` inside a
[smolvm](https://github.com/smol-machines/smolvm) microVM, so the guardrails
come from a VM boundary (its own kernel, behind a KVM/Hypervisor.framework
VMM) rather than from per-action permission prompts. Docker Engine runs inside
the VM, so the agent can build and run containers without any access to the
host's Docker.

For work that needs a GPU, which smolvm can't pass through, there's also a
**container mode**: the same image run as an ordinary (unprivileged) Docker
container on the host, with the host's GPUs but without Docker inside. See
[Container mode](#container-mode).

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
- **Docker** on the host, usable without sudo, to build the image. Container
  mode also runs sessions with it.
- For GPUs in container mode, the **NVIDIA Container Toolkit**, configured
  for Docker (`docker run --rm --gpus=all ubuntu nvidia-smi` should work).
- About **8 GB of RAM** and **15 GB of free disk**. Sessions use up to 4 GB
  of memory by default. The built image takes about 4.5 GB in Docker, and the
  VM image plus smolvm's caches took about 9 GB more.

## Setup

1. On Linux, let your user run VMs. Skip this if `id -nG` already lists
   `kvm`. Otherwise run the command below, then log out and back in:

   ```sh
   sudo usermod -aG kvm "$USER"
   ```

2. Let your user run Docker, if `docker info` doesn't already work without
   sudo. Then log out and back in. (Membership in the `docker` group is
   equivalent to root on the host; the sandbox itself never gets it.)

   ```sh
   sudo usermod -aG docker "$USER"
   ```

3. Install [smolvm](https://github.com/smol-machines/smolvm). Its installer
   puts it in `~/.smolvm`, links it into `~/.local/bin`, and adds that
   directory to your PATH in your shell profile if it isn't there already.
   If the installer says it changed your profile, open a new terminal
   afterwards.

   ```sh
   curl -sSL https://smolmachines.com/install.sh | bash
   smolvm --version
   ```

   You can skip this if you'll only use container mode. Then `build` makes
   only the container image, and the VM commands won't work.

4. Get this repository and put the launcher on your PATH. Symlink it rather
   than copying it: sessions would work from a copy, but `build` needs the
   Dockerfile next to the real script, and it follows the symlink to find
   it.

   ```sh
   git clone https://github.com/mwcampbell/claude-sandbox ~/claude-sandbox
   ln -s ~/claude-sandbox/claude-sandbox ~/.local/bin/claude-sandbox
   ```

5. Build the sandbox image. This takes a while: about 4 minutes on an
   NVIDIA DGX Spark, but about 35 minutes on a Raspberry Pi CM4. It prints
   progress as it goes. This makes two images from the same Dockerfile: a
   Docker image tagged `claude-sandbox`, for container mode, and a smolvm
   machine image, for VM mode.

   ```sh
   claude-sandbox build
   ```

6. Create a login profile for each Claude account you want to use, named
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
claude-sandbox run-container personal  # the same, in a container with GPUs
claude-sandbox shell [PROFILE]  # zsh in the same environment
claude-sandbox exec CMD [ARG..] # any other command, without a profile
claude-sandbox login PROFILE    # create a profile, or log it in again
claude-sandbox profiles         # list saved profiles
claude-sandbox build            # rebuild after editing the Dockerfile
claude-sandbox clean            # delete the built images
```

Every session is a fresh VM, discarded on exit, like `docker run --rm`.
Containers and images the agent creates with Docker are discarded along with
it. The VM sees exactly one host directory, the current one, mounted at
`/home/agent/project`. `~/.gitconfig` is copied in. The VM has outbound
network access.

Tunables (environment variables): `CLAUDE_SANDBOX_CPUS` (default 4),
`CLAUDE_SANDBOX_MEM` in MiB (default 4096; this is a cap, and the host only
commits what the guest touches), `CLAUDE_SANDBOX_STORAGE` in GiB (default 20;
holds the agent's Docker images and containers; VMs only),
`CLAUDE_SANDBOX_GPUS` (default `all`; container mode only, passed to `docker
run --gpus`, or empty for no GPUs), `CLAUDE_SANDBOX_HOME` (where the VM image
is kept; default `~/.cache/claude-sandbox`), and `CLAUDE_SANDBOX_PROFILES`
(default `~/.config/claude-sandbox/profiles`).

### Container mode

`claude-sandbox run-container PROFILE` runs Claude Code in a container made
from the `claude-sandbox` Docker image, with `--gpus=all`, instead of in a
VM. Use it for work that needs the GPU. Otherwise it's like `run`: the
current directory is mounted at `/home/agent/project`, profiles work the same
way, and the container is discarded on exit.

The differences:

- **No Docker inside.** Running dockerd would need a privileged container,
  which would undo most of the isolation. The Docker CLI is still installed
  but has no daemon to talk to.
- **A weaker boundary.** The container shares the host's kernel, so the
  isolation is only as strong as Docker's default (unprivileged) settings.
  The agent has sudo, so it can be root inside the container. That's the
  host's root user too, unless Docker remaps user namespaces, but held in
  check by Docker's dropped capabilities, seccomp and AppArmor profiles.
- **Host resources.** `CLAUDE_SANDBOX_CPUS` and `CLAUDE_SANDBOX_MEM` apply
  as Docker's `--cpus` and `--memory`. GPU work may need a higher memory cap
  than the 4 GB default. `CLAUDE_SANDBOX_STORAGE` doesn't apply: the
  container's files live in the host's Docker storage until it exits.
- The agent user's uid is the host user's (set when the image is built), so
  files it creates in the project directory are owned by you.

### Profiles

A profile holds only a Claude Code login, so sessions start logged in, while
everything else in `~/.claude` stays ephemeral: no session history, resumable
sessions, memories, or settings changes carry over.

- A profile directory holds two files, readable only by you:
  `credentials.json`, Claude Code's OAuth tokens, and `claude.json`, the
  `~/.claude.json` from the login session with its per-project records
  removed. That keeps the account details and first-run choices (theme,
  accepting the bypass-permissions warning), so sessions skip onboarding.
- The sandbox never sees the profile directory itself. Each session gets a
  scratch copy. When it ends, the launcher keeps only the credentials, which
  Claude Code may have refreshed during the session.
- Running `login` on an existing profile replaces it. To delete a profile,
  delete its directory.
- The agent inside the sandbox can read the login tokens, as it could in any
  logged-in session.
- Avoid running two sessions with the same profile at once. Each refreshes
  its tokens independently, and one may invalidate the other's, which means
  logging in again.

## How it works

- `Dockerfile` defines the sandbox image, including Docker Engine.
- `claude-sandbox build` runs `docker build` with the host's Docker and tags
  the result `claude-sandbox`. Container sessions are `docker run` of that
  image.
- If smolvm is installed, the image is then `docker save`d and turned into a
  **`.smolmachine` pack**: booted once in a throwaway machine to unpack it,
  then `smolvm pack create --from-vm`. VM sessions are `smolvm machine run
  --from` that pack. When a rebuild leaves the Docker image unchanged, the
  pack is kept as it is, since packing is the slow part.
- `sandbox-entrypoint` runs at the start of every session: in a VM it starts
  dockerd, installs the profile's login files if there are any, then drops to
  the `agent` user and runs Claude. In a container, it starts as `agent` and
  skips dockerd. With a profile, it stays around to hand the login files back
  when Claude exits.

### smolvm quirks this works around

- **Docker's data must live on an ext4 disk.** A smolvm guest's root
  filesystem is an overlay, and Docker's overlay2 snapshotter can't use it.
  The entrypoint bind-mounts `/var/lib/docker` and `/var/lib/containerd` from
  the machine's ext4 data disk, mounted at `/workspace`.
- **Packs drop the image config.** `USER`, `ENV`, `ENTRYPOINT` and `CMD` are
  lost. The Dockerfile snapshots its environment into `/etc/sandbox-env`, the
  entrypoint restores it and switches to `agent` itself, and the launcher
  passes the command explicitly.
- **virtiofs can only share directories,** so `~/.gitconfig` is passed in by
  value and written by the entrypoint.
- **Sessions use the `virtio-net` network backend.** smolvm's default (TSI)
  gives the guest no real network interface. smolvm's docs call for
  virtio-net when running a container runtime in the guest.

### Timing

These were measured when the image was built in a smolvm builder VM rather
than with the host's Docker. A full build from scratch took about 4 minutes 15 seconds on an NVIDIA DGX
Spark. On a Raspberry Pi CM4 with an SD card, everything is much slower:

- A build from scratch took about 35 minutes. A rebuild that reused Docker's
  layer cache still took about 27 minutes. Most of that is fixed
  cost: exporting, unpacking, and recompressing the roughly 3 GB image
  (around 7 minutes each).
- The first session from a new pack spent about 3 minutes extracting it into
  smolvm's cache.
- After that, a session reaches its shell or Claude in about 18 seconds,
  including starting dockerd.
- Disk use: the pack is about 860 MB, and `~/.cache/smolvm` (then holding
  the builder VM's disk as well as the extracted pack) was about 8 GB.
