#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# vox — Multi-Command Deploy CLI: Any Repo → Docker + Cloudflare Tunnel
# ─────────────────────────────────────────────────────────────────────────────
# Usage:
#   ./vox setup          # Interactive first-time setup
#   ./vox deploy         # Pull latest + rebuild + zero-downtime restart
#   ./vox logs [--follow]# Tail container logs
#   ./vox status         # Show running containers, health, uptime
#   ./vox stop           # Stop all services
#   ./vox start          # Start services
#   ./vox restart        # Restart services
#   ./vox rollback [n]   # Roll back to previous deploy
#   ./vox env            # Show current env vars (masked secrets)
#   ./vox env set K=V    # Set an env var and redeploy
#   ./vox env unset K    # Remove an env var and redeploy
#   ./vox destroy        # Tear down everything
#   ./vox history        # Show deploy history
#   ./vox watch          # Start auto-redeploy watcher
#   ./vox help           # Show usage
# ─────────────────────────────────────────────────────────────────────────────

BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
MAGENTA='\033[0;35m'
NC='\033[0m'

get_cols() { tput cols 2>/dev/null || echo 80; }

banner() {
  local cols
  cols=$(get_cols)
  local inner=$((cols - 4))
  [[ "$inner" -lt 20 ]] && inner=20
  local hbar=""
  for ((i=0; i<inner+2; i++)); do hbar="${hbar}─"; done

  local text="$1"
  local plain_text
  plain_text=$(echo -e "$text" | sed 's/\x1b\[[0-9;]*m//g')
  local tlen=${#plain_text}
  local pad=$((inner - tlen))
  [[ "$pad" -lt 0 ]] && pad=0
  local spaces=""
  for ((i=0; i<pad; i++)); do spaces="${spaces} "; done

  echo ""
  echo -e "${CYAN}╭${hbar}╮${NC}"
  echo -e "${CYAN}│${NC} ${BOLD}${text}${NC}${spaces} ${CYAN}│${NC}"
  echo -e "${CYAN}╰${hbar}╯${NC}"
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
# DYNAMIC BOX RENDERING — adapts to terminal width
# ═════════════════════════════════════════════════════════════════════════════

BOX_LINES=()

box_line() {
  BOX_LINES+=("$1")
}

box_render() {
  # Get terminal width, default 80
  local cols
  cols=$(tput cols 2>/dev/null || echo 80)
  # Box inner width = terminal - 4 (border + padding each side)
  local inner=$((cols - 4))
  [[ "$inner" -lt 20 ]] && inner=20

  # Top border
  local hbar=""
  for ((i=0; i<inner+2; i++)); do hbar="${hbar}─"; done
  echo -e "${CYAN}╭${hbar}╮${NC}"

  # Content lines — pad/truncate to fit
  for line in "${BOX_LINES[@]}"; do
    # Strip ANSI for length calculation
    local plain
    plain=$(echo -e "$line" | sed 's/\x1b\[[0-9;]*m//g')
    local len=${#plain}

    if [[ "$len" -le "$inner" ]]; then
      # Pad with spaces
      local pad=$((inner - len))
      local spaces=""
      for ((i=0; i<pad; i++)); do spaces="${spaces} "; done
      echo -e "${CYAN}│${NC} ${line}${spaces} ${CYAN}│${NC}"
    else
      # Truncate
      echo -e "${CYAN}│${NC} ${line:0:$inner} ${CYAN}│${NC}"
    fi
  done

  # Bottom border
  echo -e "${CYAN}╰${hbar}╯${NC}"

  # Reset
  BOX_LINES=()
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
  DETECTED_NATIVE_MODULES="" # native node modules needing rebuild

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

    # ── Parse package.json scripts with a single python3 call ──
    # Extracts: scripts object, dependencies, devDependencies, main
    local pkg_json_data
    pkg_json_data=$(python3 -c "
import json, sys
d = json.load(open('$pkg'))
scripts = d.get('scripts', {})
deps = {**d.get('dependencies', {}), **d.get('devDependencies', {})}
# Print script names one per line, prefixed
for k in scripts:
    print(f'script:{k}={scripts[k]}')
for k in deps:
    print(f'dep:{k}')
print(f'main:{d.get(\"main\", \"\")}')
" 2>/dev/null || true)

    # Helper: check if a script exists
    has_script() { echo "$pkg_json_data" | grep -q "^script:$1=" 2>/dev/null; }
    get_script() { echo "$pkg_json_data" | grep "^script:$1=" 2>/dev/null | head -1 | sed 's/^script:[^=]*=//'; }
    has_dep()    { echo "$pkg_json_data" | grep -q "^dep:$1$" 2>/dev/null; }

    # Detect install command — always --ignore-scripts for Docker layer caching
    # (postinstall scripts often reference source files not yet copied)
    if has_script "postinstall"; then
      detect "postinstall script found: $(get_script postinstall)"
      detect "Will use --ignore-scripts for Docker layer caching"
    fi

    case "$pkg_mgr" in
      pnpm) DETECTED_INSTALL_CMD="pnpm install --frozen-lockfile --ignore-scripts" ;;
      yarn) DETECTED_INSTALL_CMD="yarn install --frozen-lockfile --ignore-scripts" ;;
      *)    DETECTED_INSTALL_CMD="npm ci --ignore-scripts" ;;
    esac

    # Check for native modules that need build tools
    local has_native=0
    local native_modules=""
    for mod in argon2 better-sqlite3 bcrypt sharp canvas sqlite3 node-gyp; do
      if has_dep "$mod"; then
        has_native=1
        native_modules="${native_modules:+$native_modules }$mod"
      fi
    done
    if [[ "$has_native" -eq 1 ]]; then
      DETECTED_SYSTEM_DEPS="${DETECTED_SYSTEM_DEPS:+$DETECTED_SYSTEM_DEPS\n}RUN apk add --no-cache python3 make g++ gcc musl-dev"
      detect "Native modules detected ($native_modules) — adding build tools"
    fi
    # Store for Dockerfile generator
    DETECTED_NATIVE_MODULES="$native_modules"

    # Detect framework from dependencies
    local framework=""
    if has_dep "next";              then framework="next"
    elif has_dep "nuxt";            then framework="nuxt"
    elif has_dep "@remix-run/node";  then framework="remix"
    elif has_dep "@remix-run/react"; then framework="remix"
    elif has_dep "astro";           then framework="astro"
    elif has_dep "@sveltejs/kit";   then framework="sveltekit"
    elif has_dep "vite";            then framework="vite"
    elif has_dep "express";         then framework="express"
    elif has_dep "fastify";         then framework="fastify"
    elif has_dep "hono";            then framework="hono"
    elif has_dep "koa";             then framework="koa"
    fi

    # Read actual build/start scripts from package.json
    local pkg_build_script="" pkg_start_script=""
    has_script "build" && pkg_build_script="$(get_script build)"
    has_script "start" && pkg_start_script="$(get_script start)"

    # ── Detect dangerous lifecycle scripts ──
    # prebuild/prestart/predev often contain dev-machine ops (kill-port, etc.)
    # that break inside Docker (killing PID 1 = killing the build).
    # When found, we bypass npm run and call the underlying command directly.
    local has_dangerous_prebuild=0 has_dangerous_prestart=0
    local prebuild_script="" prestart_script=""

    if has_script "prebuild"; then
      prebuild_script="$(get_script prebuild)"
      # Flag if it contains kill, port-kill, fuser, lsof, or process management
      if echo "$prebuild_script" | grep -qiE 'kill|fuser|lsof|pkill|taskkill'; then
        has_dangerous_prebuild=1
        warn "prebuild contains process-killing ops — will bypass for Docker"
        detect "prebuild: $prebuild_script"
      fi
    fi
    if has_script "prestart"; then
      prestart_script="$(get_script prestart)"
      if echo "$prestart_script" | grep -qiE 'kill|fuser|lsof|pkill|taskkill'; then
        has_dangerous_prestart=1
        warn "prestart contains process-killing ops — will bypass for Docker"
        detect "prestart: $prestart_script"
      fi
    fi

    # ── Resolve build command ──
    # If prebuild is dangerous, run the raw build command directly (e.g. "next build")
    # instead of "npm run build" which triggers prebuild → death
    resolve_build_cmd() {
      if [[ "$has_dangerous_prebuild" -eq 1 ]] && [[ -n "$pkg_build_script" ]]; then
        # Run the underlying command directly, skip lifecycle
        echo "npx $pkg_build_script"
      elif [[ -n "$pkg_build_script" ]]; then
        echo "${pkg_mgr} run build"
      else
        echo ""
      fi
    }

    # ── Resolve start command ──
    # Same logic: if prestart is dangerous, use the raw command
    resolve_start_cmd() {
      if [[ "$has_dangerous_prestart" -eq 1 ]] && [[ -n "$pkg_start_script" ]]; then
        echo "npx $pkg_start_script"
      elif [[ -n "$pkg_start_script" ]]; then
        echo "${pkg_mgr} start"
      else
        echo ""
      fi
    }

    # Set build/start per framework
    case "$framework" in
      next)
        DETECTED_TYPE="node/nextjs"
        DETECTED_BUILD_CMD="$(resolve_build_cmd)"
        DETECTED_START_CMD="$(resolve_start_cmd)"
        [[ -z "$DETECTED_BUILD_CMD" ]] && DETECTED_BUILD_CMD="npx next build"
        [[ -z "$DETECTED_START_CMD" ]] && DETECTED_START_CMD="npx next start"
        DETECTED_PORT="3000"
        detect "Next.js detected (build: $DETECTED_BUILD_CMD, start: $DETECTED_START_CMD)"
        ;;
      nuxt)
        DETECTED_TYPE="node/nuxt"
        DETECTED_BUILD_CMD="$(resolve_build_cmd)"
        [[ -z "$DETECTED_BUILD_CMD" ]] && DETECTED_BUILD_CMD="npx nuxt build"
        DETECTED_START_CMD="node .output/server/index.mjs"
        DETECTED_PORT="3000"
        detect "Nuxt detected"
        ;;
      remix)
        DETECTED_TYPE="node/remix"
        DETECTED_BUILD_CMD="$(resolve_build_cmd)"
        DETECTED_START_CMD="$(resolve_start_cmd)"
        [[ -z "$DETECTED_BUILD_CMD" ]] && DETECTED_BUILD_CMD="npx remix build"
        [[ -z "$DETECTED_START_CMD" ]] && DETECTED_START_CMD="${pkg_mgr} start"
        DETECTED_PORT="3000"
        detect "Remix detected"
        ;;
      astro)
        DETECTED_TYPE="node/astro"
        DETECTED_BUILD_CMD="$(resolve_build_cmd)"
        [[ -z "$DETECTED_BUILD_CMD" ]] && DETECTED_BUILD_CMD="npx astro build"
        DETECTED_START_CMD="node ./dist/server/entry.mjs"
        DETECTED_PORT="4321"
        detect "Astro detected"
        ;;
      sveltekit)
        DETECTED_TYPE="node/sveltekit"
        DETECTED_BUILD_CMD="$(resolve_build_cmd)"
        [[ -z "$DETECTED_BUILD_CMD" ]] && DETECTED_BUILD_CMD="npx svelte-kit build"
        DETECTED_START_CMD="node build"
        DETECTED_PORT="3000"
        detect "SvelteKit detected"
        ;;
      vite)
        if [[ -z "$pkg_start_script" ]]; then
          DETECTED_TYPE="node/vite-static"
          DETECTED_BUILD_CMD="$(resolve_build_cmd)"
          [[ -z "$DETECTED_BUILD_CMD" ]] && DETECTED_BUILD_CMD="npx vite build"
          DETECTED_START_CMD="npx serve dist -l 3000"
          DETECTED_PORT="3000"
          detect "Vite SPA (static) — will serve with 'serve'"
        else
          DETECTED_TYPE="node/vite-ssr"
          DETECTED_BUILD_CMD="$(resolve_build_cmd)"
          DETECTED_START_CMD="$(resolve_start_cmd)"
          [[ -z "$DETECTED_BUILD_CMD" ]] && DETECTED_BUILD_CMD="npx vite build"
          [[ -z "$DETECTED_START_CMD" ]] && DETECTED_START_CMD="${pkg_mgr} start"
          DETECTED_PORT="3000"
          detect "Vite SSR detected (start: $DETECTED_START_CMD)"
        fi
        ;;
      express|fastify|hono|koa)
        DETECTED_TYPE="node/$framework"
        DETECTED_BUILD_CMD="$(resolve_build_cmd)"
        DETECTED_START_CMD="$(resolve_start_cmd)"
        [[ -z "$DETECTED_START_CMD" ]] && DETECTED_START_CMD="${pkg_mgr} start"
        DETECTED_PORT="3000"
        detect "$framework server detected (start: $DETECTED_START_CMD)"
        ;;
      *)
        # Generic Node.js — read directly from scripts
        DETECTED_BUILD_CMD="$(resolve_build_cmd)"
        DETECTED_START_CMD="$(resolve_start_cmd)"

        if [[ -z "$DETECTED_START_CMD" ]]; then
          local main_entry
          main_entry=$(echo "$pkg_json_data" | grep "^main:" | sed 's/^main://')
          if [[ -n "$main_entry" ]]; then
            DETECTED_START_CMD="node $main_entry"
            detect "Generic Node.js (main: $main_entry)"
          else
            DETECTED_START_CMD="node index.js"
            detect "Generic Node.js (no start script, defaulting to index.js)"
          fi
        else
          detect "Generic Node.js (start: $DETECTED_START_CMD)"
        fi
        ;;
    esac

    # Show all discovered scripts to user
    local all_scripts
    all_scripts=$(echo "$pkg_json_data" | grep "^script:" | sed 's/^script:/  /' | head -20)
    if [[ -n "$all_scripts" ]]; then
      detect "package.json scripts:"
      echo "$all_scripts" | while IFS= read -r line; do
        echo -e "    ${MAGENTA}${line}${NC}"
      done
    fi

    # Look for data dirs that should be volumes
    if has_dep "better-sqlite3" || has_dep "sqlite3" || has_dep "nedb" || has_dep "lowdb"; then
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
  # ── Option A: User provided a .env file (drag-and-drop / CLI arg) ──
  if [[ -n "$IMPORTED_ENV_FILE" ]]; then
    info "Importing env file: $IMPORTED_ENV_FILE"

    # Count vars
    local var_count
    var_count=$(grep -cE '^[A-Za-z_][A-Za-z0-9_]*=' "$IMPORTED_ENV_FILE" 2>/dev/null || echo 0)
    info "Found $var_count environment variables"

    # Parse into ENV_VARS array (for display / merge)
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ -z "${line// /}" ]] && continue
      if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]]; then
        local key="${BASH_REMATCH[1]}"
        ENV_VARS+=("$line")
        ENV_VAR_KEYS+=("$key")
      fi
    done < "$IMPORTED_ENV_FILE"

    # Show summary (mask secret values)
    echo ""
    for key in "${ENV_VAR_KEYS[@]}"; do
      if [[ "$key" =~ (SECRET|TOKEN|PASSWORD|KEY|PRIVATE|AUTH) ]]; then
        echo -e "    ${key}=${DIM}****${NC}"
      else
        local val
        val=$(grep "^${key}=" "$IMPORTED_ENV_FILE" | head -1 | sed "s/^${key}=//" || true)
        echo -e "    ${key}=${val:0:60}"
      fi
    done
    echo ""

    if confirm "Edit any of these values?"; then
      ENV_VARS=()
      while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*) ]]; then
          local key="${BASH_REMATCH[1]}"
          local default_val="${BASH_REMATCH[2]}"
          default_val="${default_val#\"}"
          default_val="${default_val%\"}"
          default_val="${default_val#\'}"
          default_val="${default_val%\'}"
          local value
          if [[ "$key" =~ (SECRET|TOKEN|PASSWORD|KEY|PRIVATE|AUTH) ]]; then
            ask_secret value "$key" "$default_val"
          else
            ask value "$key" "$default_val"
          fi
          ENV_VARS+=("${key}=${value}")
        fi
      done < "$IMPORTED_ENV_FILE"
    fi
    return 0
  fi

  # ── Option B: No import — check for env example in repo, or ask manually ──

  # Also prompt: drag/drop an env file now
  echo ""
  box_line "Drag & drop a .env file here, paste a path, or press Enter to skip."
  box_render
  ask dropped_env_path "Path to .env file (or blank)" ""
  # Clean up drag-and-drop artifacts (quotes, whitespace)
  dropped_env_path=$(echo "$dropped_env_path" | sed "s/^['\"]//;s/['\"]$//;s/^[[:space:]]*//;s/[[:space:]]*$//")

  if [[ -n "$dropped_env_path" ]] && [[ -f "$dropped_env_path" ]]; then
    IMPORTED_ENV_FILE="$dropped_env_path"
    discover_env_vars "$repo"
    return 0
  fi

  # Look for env example files in repo
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
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ -z "${line// /}" ]] && continue

      if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*) ]]; then
        local key="${BASH_REMATCH[1]}"
        local default_val="${BASH_REMATCH[2]}"
        default_val="${default_val#\"}"
        default_val="${default_val%\"}"
        default_val="${default_val#\'}"
        default_val="${default_val%\'}"

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
    info "No .env.example found in repo."
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
  local is_node=0
  if [[ "$DETECTED_TYPE" == node/* ]] || [[ "$DETECTED_TYPE" == "node" ]]; then
    is_node=1
  fi

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

    # ── Dependency layer (cached) ──
    if [[ -n "$DETECTED_COPY_DEPS" ]]; then
      echo "# Dependencies (cached layer — install before source copy)"
      for dep_file in $DETECTED_COPY_DEPS; do
        echo "COPY ${dep_file} ./"
      done
      echo "RUN ${DETECTED_INSTALL_CMD}"
      echo ""
    fi

    # ── Source copy ──
    echo "# Application source"
    echo "COPY . ."
    echo ""

    # ── Post-copy: rebuild native modules now that source is present ──
    if [[ "$is_node" -eq 1 ]] && [[ -n "${DETECTED_NATIVE_MODULES:-}" ]]; then
      echo "# Rebuild native modules against source tree"
      echo "RUN npm rebuild ${DETECTED_NATIVE_MODULES}"
      echo ""
    fi

    # ── Build step ──
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

    # Start command
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
    env_file: ./${repo_dir}/.env
    expose:
      - "${DETECTED_PORT}"
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
    env_file: ./${repo_dir}/.env
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
# STATE DIRECTORY & CONFIG
# ═════════════════════════════════════════════════════════════════════════════

VOX_DIR=".vox"
VOX_CONFIG="$VOX_DIR/config.json"
VOX_DEPLOYS="$VOX_DIR/deploys"

vox_init_dirs() {
  mkdir -p "$VOX_DIR" "$VOX_DEPLOYS"
}

# Save config to .vox/config.json using python3
vox_save_config() {
  vox_init_dirs
  python3 - <<PYEOF
import json, os

cfg = {
    "project_name":          "$1",
    "repo_url":              "$2",
    "repo_branch":           "$3",
    "repo_dir":              "$4",
    "hostname":              "$5",
    "port":                  "$6",
    "type":                  "$7",
    "base_image":            "$8",
    "install_cmd":           "$9",
    "build_cmd":             "${10}",
    "start_cmd":             "${11}",
    "data_dirs":             "${12}",
    "tunnel_method":         "${13}",
    "use_existing_dockerfile": "${14}",
    "created_at":            "${15}",
    "compose_cmd":           "${16}",
}

with open("$VOX_CONFIG", "w") as f:
    json.dump(cfg, f, indent=2)
print("Config saved to $VOX_CONFIG")
PYEOF
}

# Load a single key from config.json using python3
vox_config_get() {
  local key="$1"
  python3 -c "
import json, sys
try:
    d = json.load(open('$VOX_CONFIG'))
    print(d.get('$key', ''))
except Exception:
    print('')
" 2>/dev/null || true
}

# Load all config keys into shell variables
vox_load_config() {
  if [[ ! -f "$VOX_CONFIG" ]]; then
    err "No config found at $VOX_CONFIG. Run './vox setup' first."
    exit 1
  fi

  CFG_PROJECT_NAME=$(vox_config_get "project_name")
  CFG_REPO_BRANCH=$(vox_config_get "repo_branch")
  CFG_REPO_DIR=$(vox_config_get "repo_dir")
  CFG_HOSTNAME=$(vox_config_get "hostname")
  CFG_TYPE=$(vox_config_get "type")
  CFG_COMPOSE_CMD=$(vox_config_get "compose_cmd")

  WORK_DIR="$(pwd)"
  REPO_PATH="$WORK_DIR/$CFG_REPO_DIR"
  COMPOSE_CMD="${CFG_COMPOSE_CMD:-docker compose}"
}

# Detect compose command (used during setup before config exists)
detect_compose_cmd() {
  if docker compose version &>/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose &>/dev/null; then
    echo "docker-compose"
  else
    echo "docker compose"
  fi
}

# Log a deploy entry to .vox/deploys/<timestamp>.json
vox_log_deploy() {
  local status="$1"
  local ts
  ts=$(date -Iseconds)
  local safe_ts
  safe_ts=$(echo "$ts" | tr ':' '-')
  local git_sha=""
  if [[ -d "$REPO_PATH/.git" ]]; then
    git_sha=$(git -C "$REPO_PATH" rev-parse --short HEAD 2>/dev/null || true)
  fi
  local image_tag="${2:-}"

  vox_init_dirs
  python3 - <<PYEOF
import json
entry = {
    "timestamp":  "$ts",
    "git_sha":    "$git_sha",
    "image_tag":  "$image_tag",
    "status":     "$status",
}
with open("$VOX_DEPLOYS/${safe_ts}.json", "w") as f:
    json.dump(entry, f, indent=2)
PYEOF
}

# Wait for container healthcheck to pass (up to N seconds)
wait_for_health() {
  local container="$1"
  local timeout="${2:-120}"
  local elapsed=0
  info "Waiting for container health ($container)..."
  while [[ "$elapsed" -lt "$timeout" ]]; do
    local health
    health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")
    case "$health" in
      healthy)
        info "Container is healthy."
        return 0
        ;;
      none|"")
        # No healthcheck configured — just check it's running
        local running
        running=$(docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null || echo "false")
        if [[ "$running" == "true" ]]; then
          info "Container is running (no healthcheck configured)."
          return 0
        fi
        ;;
      unhealthy)
        warn "Container reported unhealthy."
        return 1
        ;;
    esac
    sleep 5
    elapsed=$((elapsed + 5))
    echo -n "."
  done
  echo ""
  warn "Timed out waiting for health after ${timeout}s."
  return 1
}

# ═════════════════════════════════════════════════════════════════════════════
# SUBCOMMAND: setup
# ═════════════════════════════════════════════════════════════════════════════

cmd_setup() {
  # ── Parse CLI args for IMPORTED_ENV_FILE ──
  IMPORTED_ENV_FILE=""
  for arg in "$@"; do
    # Strip quotes/whitespace from drag-and-drop paths
    arg=$(echo "$arg" | sed "s/^['\"]//;s/['\"]$//;s/^[[:space:]]*//;s/[[:space:]]*$//")
    if [[ -f "$arg" ]]; then
      IMPORTED_ENV_FILE="$arg"
    fi
  done

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

  # ─────────────────────────────────────────────────────────────────────────
  # Step 1: Repository
  # ─────────────────────────────────────────────────────────────────────────
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

  # ─────────────────────────────────────────────────────────────────────────
  # Step 2: Auto-Detect
  # ─────────────────────────────────────────────────────────────────────────
  banner "Step 2 / 5 — Project Detection"

  USE_EXISTING_DOCKERFILE="false"

  if detect_project "$REPO_PATH"; then
    echo ""
    box_line "Detection Results"
    box_line ""
    box_line "  Type:     $DETECTED_TYPE"
    box_line "  Image:    $DETECTED_BASE_IMAGE"
    box_line "  Install:  ${DETECTED_INSTALL_CMD:-(none)}"
    box_line "  Build:    ${DETECTED_BUILD_CMD:-(none)}"
    box_line "  Start:    ${DETECTED_START_CMD:-(default entrypoint)}"
    box_line "  Port:     $DETECTED_PORT"
    if [[ -n "$DETECTED_DATA_DIRS" ]]; then
      box_line "  Volumes:  $DETECTED_DATA_DIRS"
    fi
    box_render
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
    box_line "Could not auto-detect project type"
    box_line "Configure manually below"
    box_render
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
      box_line "Common base images:"
      box_line "  node:20-alpine  | python:3.12-slim | golang:1.22-alpine"
      box_line "  ruby:3.3-slim   | php:8.3-apache   | nginx:alpine"
      box_render
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

  # ─────────────────────────────────────────────────────────────────────────
  # Step 3: Cloudflare Tunnel
  # ─────────────────────────────────────────────────────────────────────────
  banner "Step 3 / 5 — Cloudflare Tunnel"

  box_line "Expose your app on a domain you control — no open ports needed."
  box_line "You'll need a tunnel token from the Cloudflare Zero Trust dashboard."
  box_line ""
  box_line "Auth methods:"
  box_line "  1) Tunnel token  (recommended — one string from dashboard)"
  box_line "  2) Credentials file  (JSON from 'cloudflared tunnel create')"
  box_render
  echo ""

  ask CF_HOSTNAME "Public hostname (e.g. app.example.com)" ""
  echo ""
  ask CF_AUTH_METHOD "Auth method [1/2]" "1"

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

  # ─────────────────────────────────────────────────────────────────────────
  # Step 4: Environment Variables
  # ─────────────────────────────────────────────────────────────────────────
  banner "Step 4 / 5 — Environment Variables"

  discover_env_vars "$REPO_PATH"

  # ─────────────────────────────────────────────────────────────────────────
  # Step 5: Generate & Deploy
  # ─────────────────────────────────────────────────────────────────────────
  banner "Step 5 / 5 — Generate & Deploy"

  # ── .env → inside repo dir ──
  ENV_FILE="$REPO_PATH/.env"
  info "Writing $ENV_FILE"

  {
    echo "# Generated by vox setup.sh — $(date -Iseconds)"
    echo ""
    echo "# Cloudflare Tunnel"
    echo "CF_HOSTNAME=$CF_HOSTNAME"
    # TUNNEL_TOKEN is what cloudflared reads from environment
    [[ -n "$CF_TUNNEL_TOKEN" ]] && echo "TUNNEL_TOKEN=$CF_TUNNEL_TOKEN"
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
  CF_CREDS_DEST=""
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

  # ── Determine tunnel method string ──
  local tunnel_method="token"
  [[ "$CF_AUTH_METHOD" == "2" ]] && tunnel_method="credentials"

  # ── Save config to .vox/config.json ──
  vox_init_dirs
  vox_save_config \
    "$REPO_DIR" \
    "$REPO_URL" \
    "$REPO_BRANCH" \
    "$REPO_DIR" \
    "$CF_HOSTNAME" \
    "$DETECTED_PORT" \
    "$DETECTED_TYPE" \
    "$DETECTED_BASE_IMAGE" \
    "$DETECTED_INSTALL_CMD" \
    "$DETECTED_BUILD_CMD" \
    "$DETECTED_START_CMD" \
    "$DETECTED_DATA_DIRS" \
    "$tunnel_method" \
    "$USE_EXISTING_DOCKERFILE" \
    "$(date -Iseconds)" \
    "$COMPOSE_CMD"

  # ── Tag first image for rollback support ──
  local image_tag
  image_tag="${REPO_DIR}:initial-$(date +%Y%m%d%H%M%S)"

  # ── Summary ──
  echo ""
  box_line "Generated files:"
  box_line ""
  box_line "  $WORK_DIR/"
  box_line "    docker-compose.yml"
  box_line "    $REPO_DIR/.env"
  if [[ "$USE_EXISTING_DOCKERFILE" != "true" ]]; then
    box_line "    $REPO_DIR/Dockerfile"
  fi
  box_line "    $REPO_DIR/.dockerignore"
  [[ -n "$CF_CREDS_DEST" ]] && box_line "    .cloudflared/config.yml"
  box_line "    .vox/config.json"
  box_line ""
  box_line "  Stack: $DETECTED_TYPE → port $DETECTED_PORT → https://$CF_HOSTNAME"
  box_render

  echo ""

  if confirm "Build and start now?"; then
    cd "$WORK_DIR"

    info "Building container..."
    $COMPOSE_CMD build

    info "Starting services..."
    $COMPOSE_CMD up -d

    # Log initial deploy
    vox_log_deploy "success" "$image_tag"

    echo ""
    banner "Live"

    box_line "Internal: port ${DETECTED_PORT} (not exposed to host)"
    box_line "Public:   https://${CF_HOSTNAME} (via Cloudflare Tunnel)"
    box_line ""
    box_line "Commands:"
    box_line "  ./vox logs --follow   # follow logs"
    box_line "  ./vox status          # container status"
    box_line "  ./vox stop            # stop services"
    box_line "  ./vox deploy          # rebuild + redeploy"
    box_line "  ./vox rollback        # roll back to previous"
    box_line ""
    box_line "Edit $REPO_DIR/.env and run './vox deploy' to apply."
    box_render
  else
    echo ""
    info "When ready:"
    echo "    ./vox deploy"
  fi

  banner "Done"
}

# ═════════════════════════════════════════════════════════════════════════════
# SUBCOMMAND: deploy
# ═════════════════════════════════════════════════════════════════════════════

cmd_deploy() {
  vox_load_config
  banner "vox deploy"

  WORK_DIR="$(pwd)"
  REPO_PATH="$WORK_DIR/$CFG_REPO_DIR"

  # 1. Pull latest code
  if [[ -d "$REPO_PATH/.git" ]]; then
    info "Pulling latest from $CFG_REPO_BRANCH..."
    git -C "$REPO_PATH" pull origin "$CFG_REPO_BRANCH"
  else
    info "No git repo at $REPO_PATH — skipping pull"
  fi

  # 2. Tag current running image as rollback target
  local ts
  ts=$(date +%Y%m%d%H%M%S)
  local rollback_tag="${CFG_REPO_DIR}:rollback-${ts}"
  local container_name
  container_name=$(echo "$CFG_REPO_DIR" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/-*$//')
  local app_container="${container_name}-app"

  local current_image
  current_image=$(docker inspect --format='{{.Image}}' "$app_container" 2>/dev/null || true)
  if [[ -n "$current_image" ]]; then
    info "Tagging current image as rollback: $rollback_tag"
    docker tag "$current_image" "$rollback_tag" 2>/dev/null || true
  fi

  # 3. Build
  cd "$WORK_DIR"
  info "Building..."
  $COMPOSE_CMD build

  # 4. Zero-downtime restart
  info "Restarting services..."
  $COMPOSE_CMD up -d

  # 5. Wait for healthcheck
  local git_sha=""
  if [[ -d "$REPO_PATH/.git" ]]; then
    git_sha=$(git -C "$REPO_PATH" rev-parse --short HEAD 2>/dev/null || true)
  fi

  if wait_for_health "$app_container" 120; then
    vox_log_deploy "success" "$rollback_tag"
    box_line "Deploy successful"
    box_line "  Git SHA: ${git_sha:-(unknown)}"
    box_line "  Image:   $rollback_tag"
    box_line "  URL:     https://$CFG_HOSTNAME"
    box_render
  else
    vox_log_deploy "failed" "$rollback_tag"
    err "Deploy completed but healthcheck did not pass."
    info "Run './vox logs' to diagnose."
    exit 1
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
# SUBCOMMAND: logs
# ═════════════════════════════════════════════════════════════════════════════

cmd_logs() {
  vox_load_config
  WORK_DIR="$(pwd)"
  cd "$WORK_DIR"
  if [[ "${1:-}" == "--follow" ]] || [[ "${1:-}" == "-f" ]]; then
    $COMPOSE_CMD logs -f
  else
    $COMPOSE_CMD logs --tail=100
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
# SUBCOMMAND: status
# ═════════════════════════════════════════════════════════════════════════════

cmd_status() {
  vox_load_config
  WORK_DIR="$(pwd)"
  REPO_PATH="$WORK_DIR/$CFG_REPO_DIR"

  local git_sha=""
  if [[ -d "$REPO_PATH/.git" ]]; then
    git_sha=$(git -C "$REPO_PATH" rev-parse --short HEAD 2>/dev/null || true)
  fi

  local container_name
  container_name=$(echo "$CFG_REPO_DIR" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/-*$//')
  local app_container="${container_name}-app"
  local tunnel_container="${container_name}-tunnel"

  local app_status="not running"
  local app_health="n/a"
  local app_uptime=""
  local app_image=""
  if docker inspect "$app_container" &>/dev/null 2>&1; then
    app_status=$(docker inspect --format='{{.State.Status}}' "$app_container" 2>/dev/null || echo "unknown")
    app_health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no healthcheck{{end}}' "$app_container" 2>/dev/null || echo "n/a")
    app_uptime=$(docker inspect --format='{{.State.StartedAt}}' "$app_container" 2>/dev/null || true)
    app_image=$(docker inspect --format='{{.Config.Image}}' "$app_container" 2>/dev/null || true)
  fi

  local tunnel_status="not running"
  if docker inspect "$tunnel_container" &>/dev/null 2>&1; then
    tunnel_status=$(docker inspect --format='{{.State.Status}}' "$tunnel_container" 2>/dev/null || echo "unknown")
  fi

  # Find last deploy
  local last_deploy=""
  if [[ -d "$VOX_DEPLOYS" ]]; then
    local latest
    latest=$(ls "$VOX_DEPLOYS"/*.json 2>/dev/null | sort | tail -1 || true)
    if [[ -n "$latest" ]]; then
      last_deploy=$(python3 -c "
import json
d = json.load(open('$latest'))
print(d.get('timestamp','') + ' [' + d.get('status','') + ']')
" 2>/dev/null || true)
    fi
  fi

  banner "vox status"
  box_line "Project:    $CFG_PROJECT_NAME"
  box_line "Type:       $CFG_TYPE"
  box_line "Hostname:   $CFG_HOSTNAME"
  box_line ""
  box_line "app:        $app_status  (health: $app_health)"
  box_line "tunnel:     $tunnel_status"
  box_line ""
  box_line "Image:      ${app_image:-(none)}"
  box_line "Git SHA:    ${git_sha:-(unknown)}"
  box_line "Started:    ${app_uptime:-(not running)}"
  box_line "Last deploy:${last_deploy:-(none)}"
  box_render
}

# ═════════════════════════════════════════════════════════════════════════════
# SUBCOMMAND: stop / start / restart
# ═════════════════════════════════════════════════════════════════════════════

cmd_stop() {
  vox_load_config
  WORK_DIR="$(pwd)"
  cd "$WORK_DIR"
  info "Stopping services..."
  $COMPOSE_CMD down
}

cmd_start() {
  vox_load_config
  WORK_DIR="$(pwd)"
  cd "$WORK_DIR"
  info "Starting services..."
  $COMPOSE_CMD up -d
}

cmd_restart() {
  vox_load_config
  WORK_DIR="$(pwd)"
  cd "$WORK_DIR"
  info "Restarting services..."
  $COMPOSE_CMD restart
}

# ═════════════════════════════════════════════════════════════════════════════
# SUBCOMMAND: rollback [n]
# ═════════════════════════════════════════════════════════════════════════════

cmd_rollback() {
  vox_load_config
  WORK_DIR="$(pwd)"

  local steps="${1:-1}"

  # List rollback images from deploy history
  if [[ ! -d "$VOX_DEPLOYS" ]]; then
    err "No deploy history found in $VOX_DEPLOYS"
    exit 1
  fi

  local deploy_files
  deploy_files=$(ls "$VOX_DEPLOYS"/*.json 2>/dev/null | sort -r || true)
  if [[ -z "$deploy_files" ]]; then
    err "No deploys recorded yet."
    exit 1
  fi

  # Collect image tags from history (most recent first)
  local tags=()
  while IFS= read -r f; do
    local tag
    tag=$(python3 -c "
import json
d = json.load(open('$f'))
t = d.get('image_tag','')
if t:
    print(t)
" 2>/dev/null || true)
    [[ -n "$tag" ]] && tags+=("$tag")
  done <<< "$deploy_files"

  if [[ "${#tags[@]}" -eq 0 ]]; then
    err "No rollback image tags found in deploy history."
    exit 1
  fi

  # n-th step: index steps-1 (0 = most recent)
  local idx=$((steps - 1))
  if [[ "$idx" -ge "${#tags[@]}" ]]; then
    err "Only ${#tags[@]} rollback(s) available; cannot roll back $steps steps."
    exit 1
  fi

  local rollback_tag="${tags[$idx]}"

  # Check image actually exists
  if ! docker image inspect "$rollback_tag" &>/dev/null 2>&1; then
    err "Image '$rollback_tag' not found locally. Cannot roll back to it."
    exit 1
  fi

  info "Rolling back to: $rollback_tag"

  cd "$WORK_DIR"
  $COMPOSE_CMD down

  # Temporarily override the compose image — use docker tag to re-point
  local container_name
  container_name=$(echo "$CFG_REPO_DIR" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/-*$//')
  local current_tag="${CFG_REPO_DIR}:latest"
  docker tag "$rollback_tag" "$current_tag" 2>/dev/null || true

  $COMPOSE_CMD up -d

  local ts
  ts=$(date -Iseconds)
  vox_log_deploy "rollback:$rollback_tag" "$rollback_tag"

  info "Rollback complete to $rollback_tag"
}

# ═════════════════════════════════════════════════════════════════════════════
# SUBCOMMAND: env / env set / env unset
# ═════════════════════════════════════════════════════════════════════════════

cmd_env() {
  vox_load_config
  WORK_DIR="$(pwd)"
  REPO_PATH="$WORK_DIR/$CFG_REPO_DIR"
  local env_file="$REPO_PATH/.env"

  local subcmd="${1:-}"

  case "$subcmd" in
    set)
      # ./vox env set KEY=VALUE
      local kv="${2:-}"
      if [[ -z "$kv" ]] || [[ "$kv" != *"="* ]]; then
        err "Usage: ./vox env set KEY=VALUE"
        exit 1
      fi
      local key="${kv%%=*}"
      local value="${kv#*=}"

      if [[ ! -f "$env_file" ]]; then
        touch "$env_file"
      fi

      # Update or append
      if grep -q "^${key}=" "$env_file" 2>/dev/null; then
        # Replace existing
        python3 - <<PYEOF
import re
with open('$env_file', 'r') as f:
    content = f.read()
content = re.sub(r'^${key}=.*$', '${key}=${value}', content, flags=re.MULTILINE)
with open('$env_file', 'w') as f:
    f.write(content)
PYEOF
        info "Updated $key in $env_file"
      else
        echo "${key}=${value}" >> "$env_file"
        info "Added $key to $env_file"
      fi

      # Redeploy
      cd "$WORK_DIR"
      $COMPOSE_CMD up -d
      info "Services restarted with updated env."
      ;;

    unset)
      # ./vox env unset KEY
      local key="${2:-}"
      if [[ -z "$key" ]]; then
        err "Usage: ./vox env unset KEY"
        exit 1
      fi

      if [[ ! -f "$env_file" ]]; then
        err "No .env file found at $env_file"
        exit 1
      fi

      python3 - <<PYEOF
import re
with open('$env_file', 'r') as f:
    lines = f.readlines()
lines = [l for l in lines if not re.match(r'^${key}=', l)]
with open('$env_file', 'w') as f:
    f.writelines(lines)
PYEOF
      info "Removed $key from $env_file"

      # Redeploy
      cd "$WORK_DIR"
      $COMPOSE_CMD up -d
      info "Services restarted with updated env."
      ;;

    "")
      # ./vox env — show all vars, masking secrets
      if [[ ! -f "$env_file" ]]; then
        err "No .env file found at $env_file"
        exit 1
      fi

      banner "Environment: $CFG_REPO_DIR"
      while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*) ]]; then
          local k="${BASH_REMATCH[1]}"
          local v="${BASH_REMATCH[2]}"
          if [[ "$k" =~ (SECRET|TOKEN|PASSWORD|KEY|PRIVATE|AUTH) ]]; then
            echo -e "  ${CYAN}${k}${NC}=${DIM}****${NC}"
          else
            echo -e "  ${CYAN}${k}${NC}=${v}"
          fi
        fi
      done < "$env_file"
      ;;

    *)
      err "Unknown env subcommand: $subcmd"
      err "Usage: ./vox env [set KEY=VALUE | unset KEY]"
      exit 1
      ;;
  esac
}

# ═════════════════════════════════════════════════════════════════════════════
# SUBCOMMAND: history
# ═════════════════════════════════════════════════════════════════════════════

cmd_history() {
  vox_load_config

  if [[ ! -d "$VOX_DEPLOYS" ]]; then
    info "No deploy history yet."
    return 0
  fi

  local files
  files=$(ls "$VOX_DEPLOYS"/*.json 2>/dev/null | sort -r | head -20 || true)
  if [[ -z "$files" ]]; then
    info "No deploys recorded yet."
    return 0
  fi

  banner "Deploy History"
  printf "  %-30s %-10s %-40s %s\n" "Timestamp" "SHA" "Image Tag" "Status"
  printf "  %-30s %-10s %-40s %s\n" "─────────────────────────────" "─────────" "───────────────────────────────────────" "──────"

  while IFS= read -r f; do
    python3 - <<PYEOF
import json
d = json.load(open('$f'))
ts  = d.get('timestamp','')[:19]
sha = d.get('git_sha','')[:9]
img = d.get('image_tag','')[:39]
st  = d.get('status','')
print(f"  {ts:<30} {sha:<10} {img:<40} {st}")
PYEOF
  done <<< "$files"
  echo ""
}

# ═════════════════════════════════════════════════════════════════════════════
# SUBCOMMAND: watch
# ═════════════════════════════════════════════════════════════════════════════

cmd_watch() {
  vox_load_config
  WORK_DIR="$(pwd)"
  REPO_PATH="$WORK_DIR/$CFG_REPO_DIR"

  local interval="${VOX_WATCH_INTERVAL:-60}"
  local pidfile="$VOX_DIR/watch.pid"

  info "Starting watch loop (interval: ${interval}s, PID will be written to $pidfile)"
  info "Press Ctrl+C to stop."
  echo "$$" > "$pidfile"

  while true; do
    local ts
    ts=$(date -Iseconds)

    if [[ -d "$REPO_PATH/.git" ]]; then
      git -C "$REPO_PATH" fetch origin "$CFG_REPO_BRANCH" --quiet 2>/dev/null || true
      local local_sha remote_sha
      local_sha=$(git -C "$REPO_PATH" rev-parse HEAD 2>/dev/null || true)
      remote_sha=$(git -C "$REPO_PATH" rev-parse "origin/$CFG_REPO_BRANCH" 2>/dev/null || true)

      if [[ -n "$local_sha" ]] && [[ -n "$remote_sha" ]] && [[ "$local_sha" != "$remote_sha" ]]; then
        info "[$ts] New commits detected — deploying..."
        cmd_deploy
      else
        info "[$ts] No changes (${local_sha:0:8})."
      fi
    else
      warn "[$ts] Repo not found at $REPO_PATH — skipping check."
    fi

    sleep "$interval"
  done
}

# ═════════════════════════════════════════════════════════════════════════════
# SUBCOMMAND: destroy
# ═════════════════════════════════════════════════════════════════════════════

cmd_destroy() {
  vox_load_config
  WORK_DIR="$(pwd)"
  REPO_PATH="$WORK_DIR/$CFG_REPO_DIR"

  echo ""
  warn "This will stop and remove all containers, images, volumes, and vox state."
  warn "Project: $CFG_PROJECT_NAME  |  Repo: $REPO_PATH"
  echo ""

  if ! confirm "Are you SURE you want to destroy everything?"; then
    info "Aborted."
    return 0
  fi

  cd "$WORK_DIR"
  info "Taking down containers, volumes, and local images..."
  $COMPOSE_CMD down --volumes --rmi local 2>/dev/null || true

  info "Removing .vox/ state directory..."
  rm -rf "$VOX_DIR"

  if [[ -d "$REPO_PATH" ]]; then
    if confirm "Also remove the cloned repo at $REPO_PATH?"; then
      rm -rf "$REPO_PATH"
      info "Removed $REPO_PATH"
    fi
  fi

  info "Destroy complete."
}

# ═════════════════════════════════════════════════════════════════════════════
# SUBCOMMAND: help
# ═════════════════════════════════════════════════════════════════════════════

cmd_help() {
  banner "vox — Deploy Any Repo"
  box_line "Usage: ./vox <command> [options]"
  box_line ""
  box_line "Commands:"
  box_line "  setup               Interactive first-time setup"
  box_line "  deploy              Pull latest + rebuild + zero-downtime restart"
  box_line "  logs [--follow]     Show container logs"
  box_line "  status              Show container health, uptime, current SHA"
  box_line "  stop                Stop all services"
  box_line "  start               Start services"
  box_line "  restart             Restart services"
  box_line "  rollback [n]        Roll back n deploys (default: 1)"
  box_line "  env                 Show env vars (secrets masked)"
  box_line "  env set KEY=VALUE   Add/update an env var and redeploy"
  box_line "  env unset KEY       Remove an env var and redeploy"
  box_line "  history             Show last 20 deploys"
  box_line "  watch               Poll git every 60s and auto-deploy on changes"
  box_line "  destroy             Tear down everything (confirms first)"
  box_line "  help                Show this message"
  box_line ""
  box_line "State lives in .vox/  (config.json, deploys/)"
  box_render
}

# ═════════════════════════════════════════════════════════════════════════════
# COMMAND DISPATCHER
# ═════════════════════════════════════════════════════════════════════════════

# Determine subcommand: first arg that does not look like a file path
SUBCOMMAND="${1:-}"
shift 2>/dev/null || true

case "$SUBCOMMAND" in
  setup)
    cmd_setup "$@"
    ;;
  deploy)
    cmd_deploy "$@"
    ;;
  logs)
    cmd_logs "$@"
    ;;
  status)
    cmd_status "$@"
    ;;
  stop)
    cmd_stop "$@"
    ;;
  start)
    cmd_start "$@"
    ;;
  restart)
    cmd_restart "$@"
    ;;
  rollback)
    cmd_rollback "$@"
    ;;
  env)
    cmd_env "$@"
    ;;
  history)
    cmd_history "$@"
    ;;
  watch)
    cmd_watch "$@"
    ;;
  destroy)
    cmd_destroy "$@"
    ;;
  help|--help|-h)
    cmd_help
    ;;
  "")
    cmd_help
    ;;
  *)
    err "Unknown command: $SUBCOMMAND"
    echo ""
    cmd_help
    exit 1
    ;;
esac
