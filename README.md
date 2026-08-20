# cf_deploy

Deploy any git repo to your own server with a Cloudflare Tunnel — one command, one container, fully isolated.

```bash
curl -fsSL https://raw.githubusercontent.com/robit-man/cf_deploy/main/vox -o vox && chmod +x vox
./vox setup --repo https://github.com/you/app --token eyJ... --hostname app.example.com
```

## What You Need

1. A **Cloudflare Tunnel token** (from [Zero Trust dashboard](https://one.dash.cloudflare.com/) > Networks > Tunnels > Create)
2. A **git repo URL** with your site/app
3. **Docker** installed on your server

That's it. The script auto-detects your stack, builds a Docker image with your app + cloudflared tunnel baked in, and deploys it — live on your domain, no ports exposed to the host.

## Quick Start

### One-liner (no prompts)

```bash
# Download + deploy in one shot
curl -fsSL https://raw.githubusercontent.com/robit-man/cf_deploy/main/vox -o vox && chmod +x vox

./vox setup \
  --repo https://github.com/you/your-app \
  --token eyJhIjoiNjQ1... \
  --hostname app.example.com
```

With env file and custom branch:

```bash
./vox setup \
  --repo https://github.com/you/your-app \
  --token eyJhIjoiNjQ1... \
  --hostname app.example.com \
  --env /path/to/.env \
  --branch develop
```

### Interactive mode

```bash
./vox setup              # prompts for everything
./vox setup my-app.env   # prompts but imports env vars from file
```

### Flags

| Flag | Required | Description |
|------|----------|-------------|
| `--repo URL` | Yes* | Git repo URL |
| `--token TOKEN` | Yes* | Cloudflare Tunnel token |
| `--hostname DOMAIN` | Yes* | Public hostname (e.g. `app.example.com`) |
| `--env PATH` | No | Path to `.env` file |
| `--branch BRANCH` | No | Git branch (default: `main`) |

*When all three required flags are provided, setup runs fully non-interactive — no prompts, straight to build and deploy.

## Custom Docker Build Arguments

Some applications need deployment metadata at image-build time, but the
meaning and naming of that metadata belongs to the application, not to `vox`.
Create an executable `.vox/build-args` hook in the deployment directory to
emit the arguments your Dockerfile declares:

```bash
#!/usr/bin/env bash
printf 'BUILD_GIT_SHA=%s\n' "$VOX_GIT_SHA_SHORT"
printf 'BUILD_GIT_COMMIT_COUNT=%s\n' "$VOX_GIT_COMMIT_COUNT"
```

```bash
chmod +x .vox/build-args
```

Each non-comment output line must be `NAME=value`. `vox` validates the names,
passes the pairs to `docker compose build --build-arg`, and logs only the names.
The hook runs with the application repository as its working directory and
receives these environment variables:

- `VOX_REPO_PATH`
- `VOX_GIT_SHA`
- `VOX_GIT_SHA_SHORT`
- `VOX_GIT_COMMIT_COUNT`
- `VOX_GIT_BRANCH`

Set `VOX_BUILD_ARGS_HOOK` to use a different operator-controlled hook path.
The default hook is kept in `.vox`, outside the pulled repository, so a remote
commit cannot introduce host-side hook execution. Build arguments are not a
safe channel for secrets; use runtime environment variables or Docker secrets
for credentials.

## How It Works

Each project runs in a **single Docker container** that contains:
- Your app (auto-detected: Node/Next.js/Python/Go/Rust/Ruby/PHP/static)
- `cloudflared` tunnel daemon (routes traffic through Cloudflare to your domain)
- Persistent volumes for databases and state

No ports are exposed to the host. All traffic flows through the Cloudflare Tunnel inside the container. Run multiple projects side-by-side — each fully isolated with its own tunnel, domain, and data.

```
┌─────────────────────────────────────────────┐
│  Docker Container                           │
│                                             │
│  ┌─────────────┐    ┌───────────────────┐   │
│  │ cloudflared │───▶│ Cloudflare Edge   │──▶ yourdomain.com
│  └─────────────┘    └───────────────────┘   │
│        │                                    │
│        ▼                                    │
│  ┌─────────────┐                            │
│  │  Your App   │  (port 3000 internal)      │
│  │  + SQLite   │                            │
│  └─────────────┘                            │
│                                             │
│  No ports exposed to host                   │
└─────────────────────────────────────────────┘
```

## Auto-Detection

The setup wizard detects your project type and generates an appropriate Dockerfile:

| Stack | Detection | Frameworks |
|-------|-----------|------------|
| **Node.js** | `package.json` | Next.js, Nuxt, Remix, Astro, SvelteKit, Vite, Express, Fastify, Hono, Koa |
| **Python** | `requirements.txt` / `pyproject.toml` | Django, FastAPI, Flask, Streamlit |
| **Go** | `go.mod` | Multi-stage build |
| **Rust** | `Cargo.toml` | Multi-stage build |
| **Ruby** | `Gemfile` | Rails, Sinatra |
| **PHP** | `composer.json` | Laravel |
| **Static** | `index.html` | nginx |

It also detects native modules, dangerous lifecycle scripts (`prebuild`/`prestart` that kill processes), package managers (npm/yarn/pnpm), and file-based databases (SQLite) that need persistent volumes.

Every detected setting is shown and can be customized before building.

## Commands

After initial setup, manage your deployment with:

```bash
./vox deploy          # Pull latest code, rebuild, restart
./vox status          # Show container health, uptime, git SHA
./vox logs            # View container logs
./vox logs --follow   # Tail logs in real-time
./vox stop            # Stop the container
./vox start           # Start the container
./vox restart         # Restart the container
./vox rollback        # Roll back to previous deploy
./vox rollback 3      # Roll back 3 deploys
./vox env             # Show current env vars (secrets masked)
./vox env set KEY=VAL # Set an env var and redeploy
./vox env unset KEY   # Remove an env var and redeploy
./vox history         # Show deploy history
./vox watch           # Auto-redeploy when git repo updates (polls every 60s)
./vox destroy         # Tear down everything
./vox help            # Show all commands
```

## Cloudflare Tunnel Setup

1. Go to [Cloudflare Zero Trust](https://one.dash.cloudflare.com/) > Networks > Tunnels
2. Click **Create a tunnel**
3. Name it (e.g., your project name)
4. Copy the **tunnel token** (long string starting with `eyJ...`)
5. Under **Public Hostnames**, add a route:
   - **Subdomain**: your choice (e.g., `app`)
   - **Domain**: your Cloudflare domain
   - **Service**: `http://localhost:3000` (or whatever port your app uses)
6. Run `./vox setup` and paste the token when prompted

The tunnel runs entirely inside the Docker container. Your server exposes zero ports.

## Deploying Multiple Sites

Run `./vox setup` in separate directories — each gets its own isolated container:

```
~/sites/
  blog/
    vox              # manages blog container
    .vox/            # state for this project
    my-blog-repo/    # cloned repo
    docker-compose.yml
  
  api/
    vox              # manages api container  
    .vox/            # state for this project
    my-api-repo/     # cloned repo
    docker-compose.yml
```

Each container runs its own cloudflared tunnel on its own domain. No conflicts, no shared state.

## Persistent Data

Databases (SQLite, etc.) and application state are stored in Docker volumes that survive container restarts and redeploys. The script auto-detects file-based databases and mounts appropriate volumes.

## Requirements

- Docker (the script offers to install it if missing)
- Git
- A Cloudflare account with a domain
- A Cloudflare Tunnel token

## License

MIT
