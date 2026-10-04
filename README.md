# claude-dockerized

Same shape as `opencode-dockerized`: Debian slim base, one non-root `coder`
user remapped to your host UID/GID, the project bind-mounted read-write and
nothing else of your home directory exposed unless you configure it. The
optional add-ons from `opencode-dockerized` are here too — Matt Pocock's
skills, local models, mitmproxy interception, OpenSpec, graphify, pumlsrv —
each adapted to how Claude Code works rather than copied 1:1.

## Quick start

```bash
./setup.sh                         # config file, completions, ~/.local/bin/claude-dockerized
claude-dockerized build
claude-dockerized auth             # sign in once (not needed for local models)
claude-dockerized                  # = run in the current directory
claude-dockerized run ~/projects/my-app --resume

DRY_RUN=true claude-dockerized run # print the docker command instead
```

| Command | What it does |
|---|---|
| `run [DIR] [args…]` | Claude Code in `DIR` (default `$PWD`); extra args go to `claude`. Default command. |
| `shell [DIR]` | bash in the same container setup |
| `auth` / `token` | sign in interactively / how to mint a long-lived token on the host |
| `models [--refresh\|--clear]` | list the local model server's models; write/remove them in `/model` |
| `build` / `update` | build with the layer cache / rebuild Claude Code, OpenSpec, graphify and the skills |
| `version` | versions inside the image |
| `config [show\|edit\|path]` | the config file below |
| `clean` | remove the image |

## Configuration

`~/.config/claude-dockerized/config`, same format as opencode-dockerized —
`./setup.sh` writes it, [`examples/config.example`](examples/config.example)
documents every key:

```ini
setting.matt_pocock_skills_support=true
setting.local_model_support=true
setting.local_model_base_url=http://127.0.0.1:11434
mount.gitconfig=~/.gitconfig:/home/coder/.gitconfig     # read-only unless :rw
env.context7=CONTEXT7_API_KEY                           # passed by name, never on the command line
```

| Setting | Default | |
|---|---|---|
| `ssh_agent_support` | false | mounts `$SSH_AUTH_SOCK` at `/run/host-ssh-agent.sock` |
| `firewall_support` | false | egress allowlist, see §7 below (`CLAUDE_FIREWALL` overrides) |
| `docker_socket_support` | false | Testcontainers, see the warning below (`CLAUDE_DOCKER_SOCK` overrides) |
| `matt_pocock_skills_support` | false | [Matt Pocock's skills](#matt-pococks-agent-skills) |
| `openspec_support` | false | [OpenSpec](#openspec) |
| `graphify_support` | false | [graphify](#graphify) |
| `pumlsrv_support` | false | PlantUML server on :8380 for `pumlcli` |
| `llm_interceptor_support`, `_port`, `_capture_local` | false, 9090, false | [mitmproxy interception](#llm-traffic-interception-llm-interceptor) |
| `local_model_support`, `local_model_base_url`, `local_model` | false, `:8080`, empty | [local models](#local-models) |

Each project is mounted at `/workspace` plus its path below `$HOME`
(`~/projects/acme` → `/workspace/projects/acme`). Claude Code keys session
history, project trust and auto-memory on the working directory, so the old
single `/workspace` mount made every project share one history. If the project
is a git worktree, the main repository's `.git` is mounted read-only at its
host path so `git status`/`log`/`diff` work.

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

`claude-dockerized.sh` mounts `~/.claude-dockerized` instead
(`CLAUDE_DOCKER_STATE` to change it). A container run
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
`CLAUDE_CODE_VERSION` build arg gives you a reproducible image. To move
forward, `claude-dockerized update` rebuilds with a fresh `CLAUDE_BUILD_TIME`
build arg, which invalidates every layer from Claude Code onwards (OpenSpec,
graphify and Matt Pocock's skills included) — the same trick as
`OPENCODE_BUILD_TIME` in the OpenCode setup. `claude-dockerized build --build-arg
CLAUDE_CODE_VERSION=2.1.289` pins a version.

### 7. Egress allowlist instead of `--network host`

This is the part `opencode-dockerized` does not attempt, and it is where most
of the real safety gain sits — a filesystem sandbox stops `rm -rf`, but it does
nothing about an agent that reads your source and posts it somewhere. Set
`setting.firewall_support=true` (or `CLAUDE_FIREWALL=true` for one run) to run
`init-firewall.sh`, which needs `NET_ADMIN` and `NET_RAW` and a normal bridge
network.

Be honest about what it buys you: it resolves names to IPs once at startup, and
the Anthropic endpoints sit behind CDNs whose address sets rotate and are
shared with other tenants. It raises the cost of exfiltration; it is not a
boundary. A forward proxy filtering on SNI/Host is stronger if you need that.

`allowed-domains.txt` carries the Claude Code hosts with a comment each, plus a
toolchain section to trim. Trailing `# comments` are stripped before lookup
(earlier versions passed the whole line to `dig`, so the commented Anthropic
hosts never made it into the allowlist).

## Things that stayed the same

- UID/GID remap in the entrypoint, so files in the bind mount belong to you.
- Non-root user; the project and the state directory are the only writable
  mounts unless you add `mount.*:rw` entries.
- Docker CLI against the host daemon for Testcontainers.
- SDKMAN/Java/Scala/sbt, nvm/Node, uv/Python layers.

## One warning about the Docker socket

Mounting `/var/run/docker.sock` hands the container the ability to start a
privileged container bind-mounting `/`, which is host root. It voids the blast
radius argument entirely, and it does so specifically for an agent you were
sandboxing because you did not fully trust its actions.

It is off by default here (`setting.docker_socket_support=true` or
`CLAUDE_DOCKER_SOCK=true` to enable). If you need
Testcontainers, a socket proxy that allows only the container lifecycle calls
Testcontainers actually makes is a meaningful middle ground.

## Add-ons

All of them are opt-in, and all of them are non-fatal: a failing step prints a
hint and Claude Code starts anyway. Per-project setup (OpenSpec, graphify,
model picker) runs only when the container starts `claude`, not for `shell`
or `models`, and it runs as `coder`, so whatever it writes belongs to you.

### Matt Pocock's agent skills

[mattpocock/skills](https://github.com/mattpocock/skills): `grill-me`, `tdd`,
`code-review`, `domain-modeling`, `to-spec`, `to-tickets`, `triage`, … 37 in all.

```ini
setting.matt_pocock_skills_support=true
```

The image stages them at build time with the upstream installer
(`npx skills@latest add mattpocock/skills --skill '*' --agent claude-code --global`),
and the entrypoint syncs them into `~/.claude/skills` on every launch. Then:

```text
/setup-matt-pocock-skills    # once per repository: issue tracker, triage labels, domain docs
/grill-me
/to-tickets
```

Differences from the OpenCode version:

- **No wrapper commands.** OpenCode hides skills from its `/` menu, so
  opencode-dockerized writes `.opencode/command/*.md` files into the project.
  Claude Code lists skills in the `/` menu itself and implements
  `disable-model-invocation` natively (the field comes from Claude Code), so
  the project directory is not touched at all.
- **Persistent target, so there is a manifest.** `~/.claude` is the state
  mount (`~/.claude-dockerized` on the host), not a `--rm` scratch directory.
  `skills/.matt-pocock-skills` records which skill directories the sync owns:
  those are refreshed from the image on every launch (edits to them are
  overwritten), removed again when you turn the setting off, and a skill of your
  own with the same name is never touched.
- Skills are pinned to the image build. `claude-dockerized update` refreshes
  them; a plain `build` reuses the cached layer.

### Local models

Claude Code talks to any server that speaks the Anthropic Messages API:
llama-server, ollama ≥ 0.14, LM Studio, LiteLLM.

```ini
setting.local_model_support=true
setting.local_model_base_url=http://127.0.0.1:8080
setting.local_model=                 # empty = first model the server lists
```

On every launch the entrypoint

1. asks the server's `/v1/models` (or ollama's `/api/tags`) what it serves,
2. starts the session on `local_model` or the first listed model, and maps
   `opus`/`sonnet`/`haiku` and the subagent model to it — subagents such as
   Explore ask for `haiku`, which a local server does not have,
3. writes the list into the `/model` picker (`modelPicker` in
   `~/.claude-dockerized/settings.json`, replacing the Claude entries),
4. sets `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` and
   `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` unless you set them yourself.

`claude-dockerized models` lists what the server offers, `models --refresh`
updates the picker without starting a session, `models --clear` removes it.

Why not Claude Code's own `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY`? It
keeps only model ids containing `claude` or `anthropic`, so `qwen3-coder` or
`gpt-oss` never appear. The picker is only written if it is empty or still the
one this tool wrote; a `modelPicker` you configured yourself is left alone.

Authentication: local servers accept any token, so `ANTHROPIC_AUTH_TOKEN=local`
is passed to skip the login screen. Export `CLAUDE_LOCAL_MODEL_TOKEN` on the
host for a server (e.g. LiteLLM) that wants a real one. Local models often have
a smaller context than the 200K Claude Code assumes for an unknown id; pass
`CLAUDE_CODE_AUTO_COMPACT_WINDOW` via `env.*` if compaction kicks in too late.

With the firewall on, the container is on a bridge network: a loopback URL is
rewritten to `host.docker.internal`, and the server must listen on an address
the bridge can reach (e.g. `0.0.0.0`), not only `127.0.0.1`.

### LLM traffic interception (llm-interceptor)

Records the prompts and responses with
[llm-interceptor](https://pypi.org/project/llm-interceptor/) (`lli`), a
mitmproxy-based recorder. As in opencode-dockerized, `lli` runs **on the host**
(it is an interactive TUI), so traces survive `--rm`:

```bash
uv tool install llm-interceptor
lli watch                     # creates ~/.mitmproxy on first run
```

```ini
setting.llm_interceptor_support=true
setting.llm_interceptor_port=9090
setting.llm_interceptor_capture_local=false   # true to record a local model, see below
```

The container trusts the mitmproxy CA (system store plus
`NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`) and points
`HTTP(S)_PROXY` at the proxy. Claude Code honours both; it reads the system
store itself because the image's Node is ≥ 22.15.

One deliberate difference: only `~/.mitmproxy/mitmproxy-ca-cert.pem` is
mounted, not the directory. The directory also holds the CA's **private key**,
and an agent that can read it can mint certificates your host trusts for any
site whenever `lli` is your proxy.

Loopback is exempt from the proxy by default. To record a local model, set
`capture_local=true` — `NO_PROXY` matches hosts, not ports, so all of loopback
is then proxied — and give `lli` a matching filter, since it only records URLs
on its built-in list of hosted providers:

```bash
lli watch --include '*127.0.0.1*' --include '*localhost*'
```

With the firewall on, the proxy is reached as `host.docker.internal`. Note
that a proxy on the host is a way around the allowlist: everything sent through
it reaches whatever the proxy reaches.

### OpenSpec

[OpenSpec](https://github.com/Fission-AI/OpenSpec/) spec-driven development.
First launch in a project runs `openspec init --tools claude --profile core`,
every launch runs `openspec update`. That adds `openspec/`, skills under
`.claude/skills/openspec-*` and the `/opsx:*` commands to the project — meant
to be committed.

### graphify

[graphify](https://pypi.org/project/graphifyy/) builds a code knowledge graph.
On launch the entrypoint runs `graphify claude install --project` (again when
the image ships a newer graphify than the one that wrote the skill) and
`graphify update .`, which builds or refreshes `graphify-out/` including
`GRAPH_REPORT.md` from the AST alone — no API key, no tokens, no network.

It is **off by default** here (opencode-dockerized enables it): the Claude Code
integration writes a section into the project's `CLAUDE.md` and `PreToolUse`
hooks into `.claude/settings.json`, both files you usually commit, rather than
into a gitignorable `.opencode/` directory. Typically add `/graphify-out/` to
the project's `.gitignore`.

### Not ported

- oh-my-opencode, bun, ast-grep, the slim system prompts and `slim-tools.js`:
  OpenCode-specific.
- Passwordless sudo: see §4 above.
- Automatic mounts of `~/.npmrc` and `~/.gradle/gradle.properties` (often
  contain registry tokens). Add them with `mount.*` if you want them;
  `setup.sh` offers `~/.gitconfig`.

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
