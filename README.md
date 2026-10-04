# claude-dockerized

Same shape as `opencode-dockerized`: Debian slim base, one non-root `coder`
user remapped to your host UID/GID, the project bind-mounted read-write and
nothing else of your home directory exposed. Only the agent-specific pieces
differ. Those differences are the interesting part, so they are listed first.

## What had to change versus the OpenCode setup

### 1. State lives in one directory, but only if you say so

OpenCode splits config (`~/.config/opencode`, mountable read-only) from state
(`~/.local/share/opencode`). Claude Code keeps credentials, settings, history
and sessions under `~/.claude`, and puts the OAuth account, personal MCP
servers and per-project trust in `~/.claude.json`, **outside** that directory.

Mounting only `~/.claude` therefore signs you out on every `docker run --rm`.
Setting `CLAUDE_CONFIG_DIR=/home/coder/.claude` moves `.claude.json` inside the
mount, so one mount covers everything. That is done in the Dockerfile.

A second consequence: unlike OpenCode's config, this mount cannot be read-only.

### 2. The host state directory is not `~/.claude`

`claude-dockerized.sh` mounts `~/.claude-dockerized` instead. A container run
with `--dangerously-skip-permissions` can write anything it can reach, and your
host Claude Code credentials and session history are not something the sandbox
needs write access to. Sign in separately inside the container.

### 3. Authentication

Three options, in decreasing order of how much the container gets to see:

```bash
./claude-dockerized.sh auth          # interactive browser login, persisted in the state dir
claude setup-token                   # on the HOST; export CLAUDE_CODE_OAUTH_TOKEN and pass it in
export ANTHROPIC_API_KEY=...         # Console key, passed through
```

The browser flow calls back to localhost, which is why the default run uses
`--network host`. With the firewall enabled (bridge network) the callback may
not land; the CLI then shows a code to paste at its `Paste code here if
prompted` prompt.

### 4. No passwordless sudo

`opencode-dockerized` grants `coder ALL=(ALL) NOPASSWD:ALL`. For an agent that
may run unattended that undoes every other control in the image: `sudo iptables
-F` clears the firewall, `sudo tee` rewrites the managed settings. The
entrypoint here does the privileged work (UID remap, firewall, Docker socket
group) and then drops privileges permanently via `setpriv`.

Keeping `coder` non-root is also a hard requirement for
`--dangerously-skip-permissions` — the CLI refuses to start as root.

### 5. Managed settings

`/etc/claude-code/managed-settings.json` sits at the top of the settings
hierarchy on Linux and overrides `~/.claude` and the project's `.claude/`. It
is baked into the image, which makes it a convenient place for deny rules on
secret files. It is a guardrail, not an access control: the file comes out of
this repository, so anyone with write access can change it. For policy nobody
can edit, use server-managed settings or MDM.

Add `"disableBypassPermissionsMode": "disable"` under `permissions` if you want
to forbid `--dangerously-skip-permissions` outright.

### 6. Version pinning

The CLI auto-updates itself by default. `DISABLE_AUTOUPDATER=1` plus a pinned
`CLAUDE_CODE_VERSION` build arg gives you a reproducible image, the same way
`OPENCODE_BUILD_TIME` busts the cache in the OpenCode setup.

### 7. Egress allowlist instead of `--network host`

This is the part `opencode-dockerized` does not attempt, and it is where most
of the real safety gain sits — a filesystem sandbox stops `rm -rf`, but it does
nothing about an agent that reads your source and posts it somewhere. Set
`CLAUDE_FIREWALL=true` to run `init-firewall.sh`, which needs `NET_ADMIN` and
`NET_RAW` and a normal bridge network.

Be honest about what it buys you: it resolves names to IPs once at startup, and
the Anthropic endpoints sit behind CDNs whose address sets rotate and are
shared with other tenants. It raises the cost of exfiltration; it is not a
boundary. A forward proxy filtering on SNI/Host is stronger if you need that.

`allowed-domains.txt` carries the Claude Code hosts with a comment each, plus a
toolchain section to trim.

## Things that stayed the same

- UID/GID remap in the entrypoint, so files in the bind mount belong to you.
- Non-root user, project directory as the only writable mount.
- Docker CLI against the host daemon for Testcontainers.
- SDKMAN/Java/Scala/sbt, nvm/Node, uv/Python layers.

## One warning about the Docker socket

Mounting `/var/run/docker.sock` hands the container the ability to start a
privileged container bind-mounting `/`, which is host root. It voids the blast
radius argument entirely, and it does so specifically for an agent you were
sandboxing because you did not fully trust its actions.

It is off by default here (`CLAUDE_DOCKER_SOCK=true` to enable). If you need
Testcontainers, a socket proxy that allows only the container lifecycle calls
Testcontainers actually makes is a meaningful middle ground.

## Quick start

```bash
chmod +x claude-dockerized.sh entrypoint.sh init-firewall.sh
./claude-dockerized.sh build
./claude-dockerized.sh auth
./claude-dockerized.sh run ~/projects/my-app

# with the egress allowlist
CLAUDE_FIREWALL=true ./claude-dockerized.sh run ~/projects/my-app

# preview the docker command
DRY_RUN=true ./claude-dockerized.sh run
```

## Alternative: the dev container route

If you use VS Code, JetBrains or Codespaces, you may not need any of this.
Claude Code installs into any dev container through a feature:

```json
{
  "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
  "features": {
    "ghcr.io/anthropics/devcontainer-features/claude-code:1.0": {}
  }
}
```

Anthropic's reference container in `anthropics/claude-code` under
`.devcontainer/` combines that with the firewall and persistent volumes, and is
worth reading even if you stay with the plain `docker run` approach.

## Docs

- Dev containers: https://code.claude.com/docs/en/devcontainer
- Sandbox environments compared: https://code.claude.com/docs/en/sandbox-environments
- Network access requirements: https://code.claude.com/docs/en/network-config
- Settings reference: https://code.claude.com/docs/en/settings-reference
- The `.claude` directory: https://code.claude.com/docs/en/claude-directory
