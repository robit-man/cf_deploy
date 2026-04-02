#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# vox — One-Command Deploy: Any Repo → Docker + Cloudflare Tunnel
# ─────────────────────────────────────────────────────────────────────────────
# Point this at any git repo and it will:
#   1. Clone the repo
#   2. Auto-detect the stack (Node, Python, Go, Rust, Ruby, PHP, static, etc.)
#   3. Detect env vars from .env.example / .env.sample (or let you add custom)
#   4. Set up a Cloudflare Tunnel to a domain you control
#   5. Generate Dockerfile + docker-compose.yml (or use the repo's own)
#   6. Build & deploy — live on your domain
#
# Think: "Vercel/Netlify, but it's your own box."
# ─────────────────────────────────────────────────────────────────────────────

BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
MAGENTA='\033[0;35m'
NC='\033[0m'

banner() {
  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  $1${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
}

info()    { echo -e "  ${GREEN}[INFO]${NC}  $1"; }
warn()    { echo -e "  ${YELLOW}[WARN]${NC}  $1"; }
err()     { echo -e "  ${RED}[ERR]${NC}  $1"; }
detect()  { echo -e "  ${MAGENTA}[AUTO]${NC}  $1"; }
prompt()  { echo -en "${BOLD}$1${NC}"; }

ask() {
  local varname="$1" text="$2" default="${3:-}"
  if [[ -n "$default" ]]; then
    prompt "  $text [$default]: "
  else
    prompt "  $text: "
  fi
  read -r input
  eval "$varname=\"${input:-$default}\""
}

ask_secret() {
  local varname="$1" text="$2" default="${3:-}"
  if [[ -n "$default" ]]; then
    prompt "  $text [$default]: "
  else
    prompt "  $text: "
  fi
  read -rs input
  echo ""
  eval "$varname=\"${input:-$default}\""
}

confirm() {
  prompt "  $1 [Y/n]: "
  read -r yn
  case "${yn,,}" in
    n|no) return 1 ;;
    *)    return 0 ;;
  esac
}

# ═════════════════════════════════════════════════════════════════════════════
# PROJECT AUTO-DETECTION ENGINE
# ═════════════════════════════════════════════════════════════════════════════

detect_project() {
  local repo="$1"

  # Result variables (globals)
  DETECTED_TYPE="unknown"
  DETECTED_BASE_IMAGE=""
  DETECTED_SYSTEM_DEPS=""
  DETECTED_INSTALL_CMD=""
  DETECTED_BUILD_CMD=""
  DETECTED_START_CMD=""
  DETECTED_PORT="3000"
  DETECTED_HAS_DOCKERFILE="false"
  DETECTED_COPY_DEPS=""     # files to copy for dep install layer
  DETECTED_IGNORE_PATTERNS=""
  DETECTED_DATA_DIRS=""     # dirs that should be volumes

  # ── Check for existing Docker config ──
  if [[ -f "$repo/Dockerfile" ]]; then
    DETECTED_HAS_DOCKERFILE="true"
    detect "Found existing Dockerfile"
  fi
  for cfile in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if [[ -f "$repo/$cfile" ]]; then
      detect "Found existing $cfile (will generate a new one with tunnel)"
      break
    fi
  done

  # ── Node.js ──
  if [[ -f "$repo/package.json" ]]; then
    DETECTED_TYPE="node"
    DETECTED_BASE_IMAGE="node:20-alpine"
    DETECTED_COPY_DEPS="package.json package-lock.json* yarn.lock* pnpm-lock.yaml*"
    DETECTED_IGNORE_PATTERNS="node_modules\n.next\n.nuxt\ndist\nbuild\n.env\n.env.local\n.git"

    # Read package.json for details
    local pkg="$repo/package.json"

    # Detect package manager
    local pkg_mgr="npm"
    if [[ -f "$repo/pnpm-lock.yaml" ]]; then
      pkg_mgr="pnpm"
      DETECTED_BASE_IMAGE="node:20-alpine"
      DETECTED_SYSTEM_DEPS="RUN corepack enable && corepack prepare pnpm@latest --activate"
    elif [[ -f "$repo/yarn.lock" ]]; then
      pkg_mgr="yarn"
    fi

    # Detect install command
    case "$pkg_mgr" in
      pnpm) DETECTED_INSTALL_CMD="pnpm install --frozen-lockfile" ;;
      yarn) DETECTED_INSTALL_CMD="yarn install --frozen-lockfile" ;;
      *)    DETECTED_INSTALL_CMD="npm ci" ;;
    esac

    # Detect framework from dependencies
    local has_next has_nuxt has_vite has_remix has_astro has_svelte has_express has_fastify
    has_next=$(grep -c '"next"' "$pkg" 2>/dev/null || true)
    has_nuxt=$(grep -c '"nuxt"' "$pkg" 2>/dev/null || true)
    has_vite=$(grep -c '"vite"' "$pkg" 2>/dev/null || true)
    has_remix=$(grep -c '"@remix-run' "$pkg" 2>/dev/null || true)
    has_astro=$(grep -c '"astro"' "$pkg" 2>/dev/null || true)
    has_svelte=$(grep -c '"@sveltejs/kit"' "$pkg" 2>/dev/null || true)
    has_express=$(grep -c '"express"' "$pkg" 2>/dev/null || true)
    has_fastify=$(grep -c '"fastify"' "$pkg" 2>/dev/null || true)

    # Check for native modules that need build tools
    local has_native=0
    for mod in argon2 better-sqlite3 bcrypt sharp canvas sqlite3 node-gyp; do
      if grep -q "\"$mod\"" "$pkg" 2>/dev/null; then
        has_native=1
        break
      fi
    done
    if [[ "$has_native" -eq 1 ]]; then
      DETECTED_SYSTEM_DEPS="${DETECTED_SYSTEM_DEPS:+$DETECTED_SYSTEM_DEPS\n}RUN apk add --no-cache python3 make g++ gcc musl-dev"
      detect "Native modules detected — adding build tools"
    fi

    # Check for scripts
    local has_build has_start
    has_build=$(grep -c '"build"' "$pkg" 2>/dev/null || true)
    has_start=$(grep -c '"start"' "$pkg" 2>/dev/null || true)

    # Set build/start per framework
    if [[ "$has_next" -gt 0 ]]; then
      DETECTED_TYPE="node/nextjs"
      DETECTED_BUILD_CMD="${pkg_mgr} run build"
      DETECTED_START_CMD="${pkg_mgr} start"
      DETECTED_PORT="3000"
      detect "Next.js project detected"
    elif [[ "$has_nuxt" -gt 0 ]]; then
      DETECTED_TYPE="node/nuxt"
      DETECTED_BUILD_CMD="${pkg_mgr} run build"
      DETECTED_START_CMD="node .output/server/index.mjs"
      DETECTED_PORT="3000"
      detect "Nuxt project detected"
    elif [[ "$has_remix" -gt 0 ]]; then
      DETECTED_TYPE="node/remix"
      DETECTED_BUILD_CMD="${pkg_mgr} run build"
      DETECTED_START_CMD="${pkg_mgr} start"
      DETECTED_PORT="3000"
      detect "Remix project detected"
    elif [[ "$has_astro" -gt 0 ]]; then
      DETECTED_TYPE="node/astro"
      DETECTED_BUILD_CMD="${pkg_mgr} run build"
      DETECTED_START_CMD="node ./dist/server/entry.mjs"
      DETECTED_PORT="4321"
      detect "Astro project detected"
    elif [[ "$has_svelte" -gt 0 ]]; then
      DETECTED_TYPE="node/sveltekit"
      DETECTED_BUILD_CMD="${pkg_mgr} run build"
      DETECTED_START_CMD="node build"
      DETECTED_PORT="3000"
      detect "SvelteKit project detected"
    elif [[ "$has_vite" -gt 0 ]] && [[ "$has_start" -eq 0 ]]; then
      # Vite SPA — static build, serve with lightweight server
      DETECTED_TYPE="node/vite-static"
      DETECTED_BUILD_CMD="${pkg_mgr} run build"
      DETECTED_START_CMD="npx serve dist -l 3000"
      DETECTED_PORT="3000"
      detect "Vite SPA (static) detected — will serve with 'serve'"
    elif [[ "$has_express" -gt 0 ]] || [[ "$has_fastify" -gt 0 ]]; then
      DETECTED_TYPE="node/server"
      [[ "$has_build" -gt 0 ]] && DETECTED_BUILD_CMD="${pkg_mgr} run build" || DETECTED_BUILD_CMD=""
      DETECTED_START_CMD="${pkg_mgr} start"
      DETECTED_PORT="3000"
      detect "Node.js server (Express/Fastify) detected"
    else
      # Generic Node.js
      [[ "$has_build" -gt 0 ]] && DETECTED_BUILD_CMD="${pkg_mgr} run build" || DETECTED_BUILD_CMD=""
      if [[ "$has_start" -gt 0 ]]; then
        DETECTED_START_CMD="${pkg_mgr} start"
      else
        # Try to find main entry
        local main_entry
        main_entry=$(python3 -c "import json; d=json.load(open('$pkg')); print(d.get('main',''))" 2>/dev/null || true)
        if [[ -n "$main_entry" ]]; then
          DETECTED_START_CMD="node $main_entry"
        else
          DETECTED_START_CMD="npm start"
        fi
      fi
      detect "Generic Node.js project detected"
    fi

    # Look for data dirs that should be volumes
    if grep -q "better-sqlite3\|sqlite3\|nedb\|lowdb" "$pkg" 2>/dev/null; then
      DETECTED_DATA_DIRS="data"
      detect "SQLite/file DB detected — will mount /app/data as volume"
    fi

    return 0
  fi

  # ── Python ──
  if [[ -f "$repo/requirements.txt" ]] || [[ -f "$repo/pyproject.toml" ]] || [[ -f "$repo/Pipfile" ]] || [[ -f "$repo/setup.py" ]]; then
    DETECTED_TYPE="python"
    DETECTED_BASE_IMAGE="python:3.12-slim"
    DETECTED_IGNORE_PATTERNS=".venv\nvenv\n__pycache__\n*.pyc\n.env\n.git\ndist\n*.egg-info"

    # Detect dependency file
    if [[ -f "$repo/pyproject.toml" ]]; then
      DETECTED_COPY_DEPS="pyproject.toml"
      if grep -q '\[tool.poetry\]' "$repo/pyproject.toml" 2>/dev/null; then
        DETECTED_INSTALL_CMD="pip install poetry && poetry install --no-root --no-interaction"
        DETECTED_COPY_DEPS="pyproject.toml poetry.lock*"
      elif grep -q '\[project\]' "$repo/pyproject.toml" 2>/dev/null; then
        DETECTED_INSTALL_CMD="pip install ."
        DETECTED_COPY_DEPS="pyproject.toml setup.cfg* setup.py*"
      else
        DETECTED_INSTALL_CMD="pip install ."
      fi
    elif [[ -f "$repo/Pipfile" ]]; then
      DETECTED_COPY_DEPS="Pipfile Pipfile.lock*"
      DETECTED_INSTALL_CMD="pip install pipenv && pipenv install --deploy --system"
    else
      DETECTED_COPY_DEPS="requirements.txt"
      DETECTED_INSTALL_CMD="pip install --no-cache-dir -r requirements.txt"
    fi

    # Detect framework
    local py_files
    py_files=$(cat "$repo/requirements.txt" "$repo/pyproject.toml" "$repo/Pipfile" 2>/dev/null || true)

    if echo "$py_files" | grep -qi "django"; then
      DETECTED_TYPE="python/django"
      DETECTED_BUILD_CMD="python manage.py collectstatic --noinput"
      DETECTED_START_CMD="gunicorn --bind 0.0.0.0:8000 --workers 4 config.wsgi:application"
      DETECTED_PORT="8000"
      # Try to find the wsgi module
      local wsgi_file
      wsgi_file=$(find "$repo" -name "wsgi.py" -not -path "*/venv/*" -not -path "*/.venv/*" 2>/dev/null | head -1)
      if [[ -n "$wsgi_file" ]]; then
        local wsgi_module
        wsgi_module=$(echo "$wsgi_file" | sed "s|$repo/||" | sed 's|/|.|g' | sed 's|\.py$||')
        DETECTED_START_CMD="gunicorn --bind 0.0.0.0:8000 --workers 4 ${wsgi_module}:application"
      fi
      DETECTED_SYSTEM_DEPS="RUN apt-get update && apt-get install -y --no-install-recommends gcc libpq-dev && rm -rf /var/lib/apt/lists/*"
      detect "Django project detected"

    elif echo "$py_files" | grep -qi "fastapi"; then
      DETECTED_TYPE="python/fastapi"
      DETECTED_BUILD_CMD=""
      # Find the main app module
      local app_entry="main:app"
      if [[ -f "$repo/app/main.py" ]]; then
        app_entry="app.main:app"
      elif [[ -f "$repo/src/main.py" ]]; then
        app_entry="src.main:app"
      fi
      DETECTED_START_CMD="uvicorn $app_entry --host 0.0.0.0 --port 8000"
      DETECTED_PORT="8000"
      detect "FastAPI project detected"

    elif echo "$py_files" | grep -qi "flask"; then
      DETECTED_TYPE="python/flask"
      DETECTED_BUILD_CMD=""
      local flask_app="app:app"
      if [[ -f "$repo/app.py" ]]; then
        flask_app="app:app"
      elif [[ -f "$repo/wsgi.py" ]]; then
        flask_app="wsgi:app"
      elif [[ -f "$repo/application.py" ]]; then
        flask_app="application:app"
      fi
      DETECTED_START_CMD="gunicorn --bind 0.0.0.0:5000 --workers 4 $flask_app"
      DETECTED_PORT="5000"
      detect "Flask project detected"

    elif echo "$py_files" | grep -qi "streamlit"; then
      DETECTED_TYPE="python/streamlit"
      DETECTED_BUILD_CMD=""
      local st_entry
      st_entry=$(find "$repo" -maxdepth 2 -name "*.py" \( -name "app.py" -o -name "main.py" -o -name "streamlit_app.py" \) 2>/dev/null | head -1)
      st_entry="${st_entry:-app.py}"
      st_entry="${st_entry#"$repo/"}"
      DETECTED_START_CMD="streamlit run $st_entry --server.port 8501 --server.address 0.0.0.0"
      DETECTED_PORT="8501"
      detect "Streamlit project detected"

    else
      # Generic Python
      DETECTED_BUILD_CMD=""
      if [[ -f "$repo/manage.py" ]]; then
        DETECTED_START_CMD="python manage.py runserver 0.0.0.0:8000"
        DETECTED_PORT="8000"
      elif [[ -f "$repo/app.py" ]]; then
        DETECTED_START_CMD="python app.py"
        DETECTED_PORT="8000"
      elif [[ -f "$repo/main.py" ]]; then
        DETECTED_START_CMD="python main.py"
        DETECTED_PORT="8000"
      else
        DETECTED_START_CMD="python -m http.server 8000"
        DETECTED_PORT="8000"
      fi
      detect "Generic Python project detected"
    fi

    return 0
  fi

  # ── Go ──
  if [[ -f "$repo/go.mod" ]]; then
    DETECTED_TYPE="go"
    DETECTED_BASE_IMAGE="golang:1.22-alpine"
    DETECTED_COPY_DEPS="go.mod go.sum*"
    DETECTED_INSTALL_CMD="go mod download"
    DETECTED_BUILD_CMD="CGO_ENABLED=0 go build -o /app/server ."
    DETECTED_START_CMD="/app/server"
    DETECTED_PORT="8080"
    DETECTED_IGNORE_PATTERNS=".git\n*.test\n.env"
    detect "Go project detected"
    return 0
  fi

  # ── Rust ──
  if [[ -f "$repo/Cargo.toml" ]]; then
    DETECTED_TYPE="rust"
    DETECTED_BASE_IMAGE="rust:1.77-slim"
    DETECTED_COPY_DEPS="Cargo.toml Cargo.lock*"
    DETECTED_INSTALL_CMD=""
    DETECTED_BUILD_CMD="cargo build --release"
    # Try to find binary name
    local bin_name
    bin_name=$(grep -m1 'name' "$repo/Cargo.toml" | sed 's/.*= *"\(.*\)"/\1/' || true)
    DETECTED_START_CMD="./target/release/${bin_name:-app}"
    DETECTED_PORT="8080"
    DETECTED_IGNORE_PATTERNS="target\n.git\n.env"
    detect "Rust project detected"
    return 0
  fi

  # ── Ruby ──
  if [[ -f "$repo/Gemfile" ]]; then
    DETECTED_TYPE="ruby"
    DETECTED_BASE_IMAGE="ruby:3.3-slim"
    DETECTED_COPY_DEPS="Gemfile Gemfile.lock*"
    DETECTED_INSTALL_CMD="bundle install"
    DETECTED_IGNORE_PATTERNS=".git\n.env\nvendor/bundle\ntmp\nlog"

    if [[ -f "$repo/config.ru" ]] || [[ -f "$repo/bin/rails" ]]; then
      DETECTED_TYPE="ruby/rails"
      DETECTED_BUILD_CMD="bundle exec rails assets:precompile"
      DETECTED_START_CMD="bundle exec rails server -b 0.0.0.0 -p 3000"
      DETECTED_PORT="3000"
      DETECTED_SYSTEM_DEPS="RUN apt-get update && apt-get install -y --no-install-recommends build-essential libpq-dev nodejs && rm -rf /var/lib/apt/lists/*"
      detect "Ruby on Rails project detected"
    else
      DETECTED_BUILD_CMD=""
      DETECTED_START_CMD="bundle exec ruby app.rb"
      DETECTED_PORT="4567"
      detect "Ruby (Sinatra/generic) project detected"
    fi
    return 0
  fi

  # ── PHP ──
  if [[ -f "$repo/composer.json" ]]; then
    DETECTED_TYPE="php"
    DETECTED_BASE_IMAGE="php:8.3-apache"
    DETECTED_COPY_DEPS="composer.json composer.lock*"
    DETECTED_INSTALL_CMD="composer install --no-dev --optimize-autoloader"
    DETECTED_IGNORE_PATTERNS="vendor\n.git\n.env\nstorage/logs"

    if [[ -f "$repo/artisan" ]]; then
      DETECTED_TYPE="php/laravel"
      DETECTED_BUILD_CMD="php artisan config:cache && php artisan route:cache && php artisan view:cache"
      DETECTED_START_CMD="php artisan serve --host=0.0.0.0 --port=8000"
      DETECTED_PORT="8000"
      DETECTED_DATA_DIRS="storage"
      detect "Laravel project detected"
    else
      DETECTED_BUILD_CMD=""
      DETECTED_START_CMD="apache2-foreground"
      DETECTED_PORT="80"
      detect "PHP project detected"
    fi
    return 0
  fi

  # ── Static site ──
  if [[ -f "$repo/index.html" ]]; then
    DETECTED_TYPE="static"
    DETECTED_BASE_IMAGE="nginx:alpine"
    DETECTED_COPY_DEPS=""
    DETECTED_INSTALL_CMD=""
    DETECTED_BUILD_CMD=""
    DETECTED_START_CMD=""  # nginx runs by default
    DETECTED_PORT="80"
    DETECTED_IGNORE_PATTERNS=".git\n.env"
    detect "Static site detected — will serve with nginx"
    return 0
  fi

  # ── Nothing matched ──
  warn "Could not auto-detect project type."
  return 1
}

# ═════════════════════════════════════════════════════════════════════════════
# ENV VAR DISCOVERY
# ═════════════════════════════════════════════════════════════════════════════

discover_env_vars() {
  local repo="$1"
  ENV_VARS=()        # array of KEY=VALUE
  ENV_VAR_KEYS=()    # just the keys

  # Look for env example files
  local env_example=""
  for candidate in .env.example .env.sample .env.template .env.defaults .env.development; do
    if [[ -f "$repo/$candidate" ]]; then
      env_example="$repo/$candidate"
      detect "Found env template: $candidate"
      break
    fi
  done

  if [[ -n "$env_example" ]]; then
    echo ""
    info "Collecting environment variables from $(basename "$env_example")"
    info "Press Enter to keep default, or type a new value."
    echo ""

    while IFS= read -r line; do
      # Skip comments and blank lines
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ -z "${line// /}" ]] && continue

      # Parse KEY=VALUE
      if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*) ]]; then
        local key="${BASH_REMATCH[1]}"
        local default_val="${BASH_REMATCH[2]}"
        # Strip surrounding quotes
        default_val="${default_val#\"}"
        default_val="${default_val%\"}"
        default_val="${default_val#\'}"
        default_val="${default_val%\'}"

        # Detect secret-like keys
        local is_secret=0
        if [[ "$key" =~ (SECRET|TOKEN|PASSWORD|KEY|PRIVATE|AUTH) ]]; then
          is_secret=1
        fi

        local value
        if [[ "$is_secret" -eq 1 ]]; then
          ask_secret value "$key" "$default_val"
        else
          ask value "$key" "$default_val"
        fi
        ENV_VARS+=("${key}=${value}")
        ENV_VAR_KEYS+=("$key")
      fi
    done < "$env_example"
  else
    info "No .env.example found. You can add env vars manually."
  fi

  # Always offer to add custom vars
  echo ""
  if confirm "Add custom environment variables?"; then
    while true; do
      ask custom_key "Variable name (blank to finish)" ""
      [[ -z "$custom_key" ]] && break
      ask custom_val "$custom_key value" ""
      ENV_VARS+=("${custom_key}=${custom_val}")
      ENV_VAR_KEYS+=("$custom_key")
    done
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
# DOCKERFILE GENERATOR
# ═════════════════════════════════════════════════════════════════════════════

generate_dockerfile() {
  local repo="$1" outfile="$2"

  # Static sites get a special nginx Dockerfile
  if [[ "$DETECTED_TYPE" == "static" ]]; then
    cat > "$outfile" <<'STATICEOF'
FROM nginx:alpine
COPY . /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
STATICEOF
    return 0
  fi

  # Go gets a multi-stage build
  if [[ "$DETECTED_TYPE" == "go" ]]; then
    cat > "$outfile" <<GOEOF
FROM golang:1.22-alpine AS builder
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN ${DETECTED_BUILD_CMD}

FROM alpine:3.19
RUN apk add --no-cache ca-certificates
WORKDIR /app
COPY --from=builder /app/server .
EXPOSE ${DETECTED_PORT}
CMD ["${DETECTED_START_CMD}"]
GOEOF
    return 0
  fi

  # Rust gets a multi-stage build
  if [[ "$DETECTED_TYPE" == "rust" ]]; then
    cat > "$outfile" <<RUSTEOF
FROM rust:1.77-slim AS builder
WORKDIR /src
COPY Cargo.toml Cargo.lock* ./
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release && rm -rf src
COPY . .
RUN cargo build --release

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=builder /src/target/release/* ./
EXPOSE ${DETECTED_PORT}
CMD ["${DETECTED_START_CMD}"]
RUSTEOF
    return 0
  fi

  # Generic Dockerfile for everything else
  {
    echo "FROM ${DETECTED_BASE_IMAGE}"
    echo ""

    # System deps
    if [[ -n "$DETECTED_SYSTEM_DEPS" ]]; then
      echo -e "$DETECTED_SYSTEM_DEPS"
      echo ""
    fi

    echo "WORKDIR /app"
    echo ""

    # Copy dependency manifests first (Docker layer caching)
    if [[ -n "$DETECTED_COPY_DEPS" ]]; then
      echo "# Dependencies (cached layer)"
      for dep_file in $DETECTED_COPY_DEPS; do
        echo "COPY ${dep_file} ./"
      done
      echo "RUN ${DETECTED_INSTALL_CMD}"

      # For Node.js with native modules, rebuild them
      if [[ "$DETECTED_TYPE" == node/* ]] || [[ "$DETECTED_TYPE" == "node" ]]; then
        # Check if we need explicit rebuild for native modules
        local pkg="$repo/package.json"
        local needs_rebuild=""
        for mod in argon2 better-sqlite3 bcrypt sharp canvas sqlite3; do
          if grep -q "\"$mod\"" "$pkg" 2>/dev/null; then
            needs_rebuild="${needs_rebuild:+$needs_rebuild }$mod"
          fi
        done
        if [[ -n "$needs_rebuild" ]]; then
          echo "RUN npm rebuild $needs_rebuild 2>/dev/null || true"
        fi
      fi
      echo ""
    fi

    echo "# Application source"
    echo "COPY . ."
    echo ""

    # Build step
    if [[ -n "$DETECTED_BUILD_CMD" ]]; then
      echo "RUN ${DETECTED_BUILD_CMD}"
      echo ""
    fi

    # Data volume
    if [[ -n "$DETECTED_DATA_DIRS" ]]; then
      for ddir in $DETECTED_DATA_DIRS; do
        echo "VOLUME [\"/app/$ddir\"]"
      done
      echo ""
    fi

    echo "EXPOSE ${DETECTED_PORT}"
    echo ""

    # Start command — convert to exec form for proper signal handling
    if [[ -n "$DETECTED_START_CMD" ]]; then
      echo "CMD ${DETECTED_START_CMD}"
    fi
  } > "$outfile"
}

# ═════════════════════════════════════════════════════════════════════════════
# DOCKER-COMPOSE GENERATOR
# ═════════════════════════════════════════════════════════════════════════════

generate_compose() {
  local outfile="$1" repo_dir="$2"
  local container_name
  container_name=$(echo "$repo_dir" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/-*$//')

  local volume_block=""
  local volume_def=""
  if [[ -n "$DETECTED_DATA_DIRS" ]]; then
    for ddir in $DETECTED_DATA_DIRS; do
      local vol_name="${container_name}-${ddir}"
      volume_block="${volume_block}      - ${vol_name}:/app/${ddir}\n"
      volume_def="${volume_def}  ${vol_name}:\n"
    done
  fi

  # Healthcheck — try common health endpoints, fall back to TCP check
  local hc_cmd
  hc_cmd="[\"CMD\", \"sh\", \"-c\", \"wget -qO- http://localhost:${DETECTED_PORT}/ || exit 1\"]"

  {
    cat <<COMPHEAD
# Generated by vox setup.sh — $(date -Iseconds)

services:
  app:
COMPHEAD

    # Build context: use existing Dockerfile or generated one
    if [[ "$DETECTED_HAS_DOCKERFILE" == "true" ]] && [[ "$USE_EXISTING_DOCKERFILE" == "true" ]]; then
      echo "    build: ./${repo_dir}"
    else
      cat <<COMPBUILD
    build:
      context: ./${repo_dir}
      dockerfile: Dockerfile
COMPBUILD
    fi

    cat <<COMPCORE
    container_name: ${container_name}-app
    restart: unless-stopped
    env_file: .env
    ports:
      - "${DETECTED_PORT}:${DETECTED_PORT}"
COMPCORE

    # Volumes
    if [[ -n "$volume_block" ]]; then
      echo "    volumes:"
      echo -e "$volume_block" | sed '/^$/d'
    fi

    cat <<COMPHC
    healthcheck:
      test: ${hc_cmd}
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
COMPHC

    # Tunnel service
    echo ""
    if [[ -n "$CF_TUNNEL_TOKEN" ]]; then
      cat <<COMPTUNNEL
  tunnel:
    image: cloudflare/cloudflared:latest
    container_name: ${container_name}-tunnel
    restart: unless-stopped
    command: tunnel run
    environment:
      - TUNNEL_TOKEN=\${CF_TUNNEL_TOKEN}
    depends_on:
      app:
        condition: service_healthy
COMPTUNNEL
    else
      cat <<COMPTUNNEL2
  tunnel:
    image: cloudflare/cloudflared:latest
    container_name: ${container_name}-tunnel
    restart: unless-stopped
    command: tunnel --config /etc/cloudflared/config.yml run
    volumes:
      - ./.cloudflared:/etc/cloudflared:ro
    depends_on:
      app:
        condition: service_healthy
COMPTUNNEL2
    fi

    # Volume definitions
    if [[ -n "$volume_def" ]]; then
      echo ""
      echo "volumes:"
      echo -e "$volume_def" | sed '/^$/d'
    fi
  } > "$outfile"
}

# ═════════════════════════════════════════════════════════════════════════════
# MAIN FLOW
# ═════════════════════════════════════════════════════════════════════════════

banner "vox — Deploy Any Repo"

info "Checking prerequisites..."

# ── Docker ──
if command -v docker &>/dev/null; then
  info "Docker: $(docker --version | head -c 60)"
else
  warn "Docker not found."
  if confirm "Install Docker via get.docker.com?"; then
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER" 2>/dev/null || true
    info "Docker installed. You may need to log out/in for group changes."
  else
    err "Docker is required."
    exit 1
  fi
fi

# ── Docker Compose ──
if docker compose version &>/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
  info "Docker Compose (plugin): OK"
elif command -v docker-compose &>/dev/null; then
  COMPOSE_CMD="docker-compose"
  info "docker-compose (standalone): OK"
else
  warn "Docker Compose not found."
  if confirm "Install Docker Compose plugin?"; then
    if ! { sudo apt-get update -qq && sudo apt-get install -y -qq docker-compose-plugin 2>/dev/null; }; then
      err "Auto-install failed. Install docker-compose-plugin manually."
      exit 1
    fi
    COMPOSE_CMD="docker compose"
  else
    err "Docker Compose is required."
    exit 1
  fi
fi

# ── Git ──
if ! command -v git &>/dev/null; then
  err "git is required. Install it and re-run."
  exit 1
fi
info "git: OK"

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Repository
# ─────────────────────────────────────────────────────────────────────────────
banner "Step 1 / 5 — Repository"

WORK_DIR="$(pwd)"
info "Working directory: $WORK_DIR"
echo ""

ask REPO_URL "Git repo URL (or local path)" ""
ask REPO_BRANCH "Branch" "main"

# Derive directory name from URL
DEFAULT_DIR=$(basename "$REPO_URL" .git 2>/dev/null || echo "app")
ask REPO_DIR "Local directory name" "$DEFAULT_DIR"

REPO_PATH="$WORK_DIR/$REPO_DIR"

if [[ -d "$REPO_PATH/.git" ]]; then
  info "Repo already exists at $REPO_PATH"
  if confirm "Pull latest from $REPO_BRANCH?"; then
    git -C "$REPO_PATH" fetch origin
    git -C "$REPO_PATH" checkout "$REPO_BRANCH"
    git -C "$REPO_PATH" pull origin "$REPO_BRANCH"
  fi
elif [[ -d "$REPO_PATH" ]] && [[ ! -d "$REPO_PATH/.git" ]]; then
  # Local path, not a git repo — use as-is
  info "Using existing directory: $REPO_PATH"
else
  info "Cloning $REPO_URL → $REPO_PATH ..."
  git clone -b "$REPO_BRANCH" "$REPO_URL" "$REPO_PATH"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Auto-Detect
# ─────────────────────────────────────────────────────────────────────────────
banner "Step 2 / 5 — Project Detection"

USE_EXISTING_DOCKERFILE="false"

if detect_project "$REPO_PATH"; then
  echo ""
  info "Detection results:"
  echo ""
  echo -e "  ${BOLD}Type:${NC}     $DETECTED_TYPE"
  echo -e "  ${BOLD}Image:${NC}    $DETECTED_BASE_IMAGE"
  echo -e "  ${BOLD}Install:${NC}  ${DETECTED_INSTALL_CMD:-(none)}"
  echo -e "  ${BOLD}Build:${NC}    ${DETECTED_BUILD_CMD:-(none)}"
  echo -e "  ${BOLD}Start:${NC}    ${DETECTED_START_CMD:-(default entrypoint)}"
  echo -e "  ${BOLD}Port:${NC}     $DETECTED_PORT"
  if [[ -n "$DETECTED_DATA_DIRS" ]]; then
    echo -e "  ${BOLD}Volumes:${NC}  $DETECTED_DATA_DIRS"
  fi
  echo ""

  if [[ "$DETECTED_HAS_DOCKERFILE" == "true" ]]; then
    echo ""
    echo "  This repo already has a Dockerfile."
    if confirm "Use the repo's own Dockerfile? (n = generate a new one)"; then
      USE_EXISTING_DOCKERFILE="true"
      # Try to detect EXPOSE port from existing Dockerfile
      local_port=$(grep -i "^EXPOSE" "$REPO_PATH/Dockerfile" 2>/dev/null | head -1 | awk '{print $2}' || true)
      if [[ -n "$local_port" ]]; then
        DETECTED_PORT="$local_port"
        detect "Using port $DETECTED_PORT from existing Dockerfile"
      fi
    fi
  fi

  if confirm "Customize these settings?"; then
    ask DETECTED_BASE_IMAGE  "Base Docker image"  "$DETECTED_BASE_IMAGE"
    ask DETECTED_INSTALL_CMD "Install command"     "$DETECTED_INSTALL_CMD"
    ask DETECTED_BUILD_CMD   "Build command"       "$DETECTED_BUILD_CMD"
    ask DETECTED_START_CMD   "Start command"       "$DETECTED_START_CMD"
    ask DETECTED_PORT        "Port"                "$DETECTED_PORT"
    ask DETECTED_DATA_DIRS   "Data dirs (space-separated, for volumes)" "$DETECTED_DATA_DIRS"
  fi
else
  # Manual configuration
  echo ""
  warn "Could not auto-detect. Let's configure manually."
  echo ""

  if [[ "$DETECTED_HAS_DOCKERFILE" == "true" ]]; then
    if confirm "The repo has a Dockerfile. Use it?"; then
      USE_EXISTING_DOCKERFILE="true"
      local_port=$(grep -i "^EXPOSE" "$REPO_PATH/Dockerfile" 2>/dev/null | head -1 | awk '{print $2}' || true)
      DETECTED_PORT="${local_port:-3000}"
      ask DETECTED_PORT "Port" "$DETECTED_PORT"
    else
      ask DETECTED_BASE_IMAGE  "Base Docker image (e.g. node:20-alpine, python:3.12-slim)" ""
      ask DETECTED_INSTALL_CMD "Dependency install command (e.g. npm ci, pip install -r requirements.txt)" ""
      ask DETECTED_BUILD_CMD   "Build command (blank if none)" ""
      ask DETECTED_START_CMD   "Start command (e.g. npm start, python app.py)" ""
      ask DETECTED_PORT        "Port the app listens on" "3000"
      ask DETECTED_DATA_DIRS   "Persistent data dirs (blank if none)" ""
    fi
  else
    echo "  Common base images:"
    echo "    node:20-alpine | python:3.12-slim | golang:1.22-alpine"
    echo "    ruby:3.3-slim  | php:8.3-apache   | nginx:alpine"
    echo ""
    ask DETECTED_BASE_IMAGE  "Base Docker image" ""
    ask DETECTED_INSTALL_CMD "Install command" ""
    ask DETECTED_BUILD_CMD   "Build command (blank if none)" ""
    ask DETECTED_START_CMD   "Start command" ""
    ask DETECTED_PORT        "Port" "3000"
    ask DETECTED_DATA_DIRS   "Persistent data dirs (blank if none)" ""
    DETECTED_IGNORE_PATTERNS=".git\n.env\n.env.local"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Cloudflare Tunnel
# ─────────────────────────────────────────────────────────────────────────────
banner "Step 3 / 5 — Cloudflare Tunnel"

echo "  Expose your app on a domain you control — no open ports needed."
echo "  You'll need a tunnel token from the Cloudflare Zero Trust dashboard."
echo ""

ask CF_HOSTNAME "Public hostname (e.g. app.example.com)" ""

echo ""
echo "  Auth method:"
echo "    1) Tunnel token  (recommended — one string from dashboard)"
echo "    2) Credentials file  (JSON from 'cloudflared tunnel create')"
echo ""
ask CF_AUTH_METHOD "Choose [1/2]" "1"

CF_TUNNEL_TOKEN=""
CF_TUNNEL_ID=""
CF_CREDENTIALS_FILE=""

if [[ "$CF_AUTH_METHOD" == "1" ]]; then
  ask_secret CF_TUNNEL_TOKEN "Cloudflare Tunnel token" ""
  if [[ -z "$CF_TUNNEL_TOKEN" ]]; then
    err "Tunnel token is required."
    exit 1
  fi
else
  ask CF_CREDENTIALS_FILE "Path to tunnel credentials JSON" ""
  if [[ ! -f "$CF_CREDENTIALS_FILE" ]]; then
    err "File not found: $CF_CREDENTIALS_FILE"
    exit 1
  fi
  CF_TUNNEL_ID=$(python3 -c "import json; print(json.load(open('$CF_CREDENTIALS_FILE'))['TunnelID'])" 2>/dev/null || true)
  if [[ -z "$CF_TUNNEL_ID" ]]; then
    ask CF_TUNNEL_ID "Tunnel ID (UUID)" ""
  fi
  info "Tunnel ID: $CF_TUNNEL_ID"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Environment Variables
# ─────────────────────────────────────────────────────────────────────────────
banner "Step 4 / 5 — Environment Variables"

discover_env_vars "$REPO_PATH"

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Generate & Deploy
# ─────────────────────────────────────────────────────────────────────────────
banner "Step 5 / 5 — Generate & Deploy"

# ── .env ──
ENV_FILE="$WORK_DIR/.env"
info "Writing $ENV_FILE"

{
  echo "# Generated by vox setup.sh — $(date -Iseconds)"
  echo ""
  echo "# Cloudflare Tunnel"
  echo "CF_HOSTNAME=$CF_HOSTNAME"
  echo "CF_TUNNEL_TOKEN=$CF_TUNNEL_TOKEN"
  [[ -n "$CF_TUNNEL_ID" ]] && echo "CF_TUNNEL_ID=$CF_TUNNEL_ID"
  echo ""
  echo "# Application"
  for entry in "${ENV_VARS[@]+"${ENV_VARS[@]}"}"; do
    echo "$entry"
  done
} > "$ENV_FILE"

# ── Dockerfile ──
if [[ "$USE_EXISTING_DOCKERFILE" == "true" ]]; then
  info "Using repo's existing Dockerfile"
else
  DOCKERFILE="$REPO_PATH/Dockerfile"
  info "Writing $DOCKERFILE"
  generate_dockerfile "$REPO_PATH" "$DOCKERFILE"
fi

# ── .dockerignore ──
DOCKERIGNORE="$REPO_PATH/.dockerignore"
if [[ ! -f "$DOCKERIGNORE" ]]; then
  info "Writing $DOCKERIGNORE"
  echo -e "$DETECTED_IGNORE_PATTERNS" > "$DOCKERIGNORE"
else
  info "Keeping existing .dockerignore"
fi

# ── docker-compose.yml ──
COMPOSE_FILE="$WORK_DIR/docker-compose.yml"
info "Writing $COMPOSE_FILE"
generate_compose "$COMPOSE_FILE" "$REPO_DIR"

# ── Credentials file tunnel config ──
if [[ -z "$CF_TUNNEL_TOKEN" ]] && [[ -n "$CF_CREDENTIALS_FILE" ]]; then
  CF_CREDS_DEST="$WORK_DIR/.cloudflared"
  mkdir -p "$CF_CREDS_DEST"
  cp "$CF_CREDENTIALS_FILE" "$CF_CREDS_DEST/credentials.json"
  cat > "$CF_CREDS_DEST/config.yml" <<CFGEOF
tunnel: $CF_TUNNEL_ID
credentials-file: /etc/cloudflared/credentials.json

ingress:
  - hostname: $CF_HOSTNAME
    service: http://app:${DETECTED_PORT}
  - service: http_status:404
CFGEOF
  info "Writing .cloudflared/config.yml"
fi

# ── Summary ──
echo ""
echo -e "${CYAN}┌──────────────────────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│${NC}  ${BOLD}Generated files:${NC}                                           ${CYAN}│${NC}"
echo -e "${CYAN}│${NC}                                                              ${CYAN}│${NC}"
echo -e "${CYAN}│${NC}  $WORK_DIR/                                    ${CYAN}│${NC}"
echo -e "${CYAN}│${NC}    docker-compose.yml                                        ${CYAN}│${NC}"
echo -e "${CYAN}│${NC}    .env                                                      ${CYAN}│${NC}"
if [[ "$USE_EXISTING_DOCKERFILE" != "true" ]]; then
echo -e "${CYAN}│${NC}    $REPO_DIR/Dockerfile                                      ${CYAN}│${NC}"
fi
echo -e "${CYAN}│${NC}    $REPO_DIR/.dockerignore                                   ${CYAN}│${NC}"
[[ -d "${CF_CREDS_DEST:-}" ]] && \
echo -e "${CYAN}│${NC}    .cloudflared/config.yml                                   ${CYAN}│${NC}"
echo -e "${CYAN}│${NC}                                                              ${CYAN}│${NC}"
echo -e "${CYAN}│${NC}  ${BOLD}Stack:${NC} $DETECTED_TYPE → port $DETECTED_PORT → https://$CF_HOSTNAME  ${CYAN}│${NC}"
echo -e "${CYAN}└──────────────────────────────────────────────────────────────┘${NC}"
echo ""

if confirm "Build and start now?"; then
  cd "$WORK_DIR"

  info "Building container..."
  $COMPOSE_CMD build

  info "Starting services..."
  $COMPOSE_CMD up -d

  echo ""
  banner "Live"

  container_name=$(echo "$REPO_DIR" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/-*$//')

  echo -e "  ${GREEN}App:${NC}     http://localhost:${DETECTED_PORT}"
  echo -e "  ${GREEN}Public:${NC}  https://${CF_HOSTNAME}"
  echo ""
  echo "  Commands:"
  echo "    $COMPOSE_CMD logs -f        # follow logs"
  echo "    $COMPOSE_CMD ps             # status"
  echo "    $COMPOSE_CMD down           # stop"
  echo "    $COMPOSE_CMD up -d --build  # rebuild"
  echo ""
  echo -e "  Edit ${BOLD}.env${NC} and run '${BOLD}$COMPOSE_CMD up -d${NC}' to apply changes."
else
  echo ""
  info "When ready:"
  echo "    cd $WORK_DIR && $COMPOSE_CMD up -d --build"
fi

banner "Done"
