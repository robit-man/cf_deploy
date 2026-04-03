# cf_deploy

Deploy any git repo to your own server with a Cloudflare Tunnel — one command, one container, fully isolated.

```
curl -fsSL https://raw.githubusercontent.com/robit-man/cf_deploy/main/setup.sh -o vox && chmod +x vox
./vox setup
```

## What You Need

1. A **Cloudflare Tunnel token** (from [Zero Trust dashboard](https://one.dash.cloudflare.com/) > Networks > Tunnels > Create)
2. A **git repo URL** with your site/app
3. **Docker** installed on your server

That's it. The script auto-detects your stack, builds a Docker image with your app + cloudflared tunnel baked in, and deploys it — live on your domain, no ports exposed to the host.

## Quick Start

```bash
# Download
curl -fsSL https://raw.githubusercontent.com/robit-man/cf_deploy/main/setup.sh -o vox
chmod +x vox

# Deploy (interactive — walks you through everything)
./vox setup
```

The setup wizard asks for:
- Git repo URL
- Cloudflare Tunnel token
- (Optional) environment variables

If your repo has a `.env.example`, it reads the keys and prompts you for values. Or drag-and-drop a `.env` file:

```bash
# Import env vars from a file
./vox setup /path/to/your/.env
```

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
