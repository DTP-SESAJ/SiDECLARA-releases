#!/usr/bin/env bash
# SideClara — menú de instalación y administración (español)
# Uso recomendado (repo público de releases; el código fuente es privado):
#   curl -fsSL https://raw.githubusercontent.com/DTP-SESAJ/SiDECLARA-releases/main/sideclara-cli.sh | sudo bash
# O:
#   sudo bash sideclara-cli.sh
set -euo pipefail

GITHUB_OWNER="${SIDECLARA_GITHUB_OWNER:-DTP-SESAJ}"
GITHUB_REPO="${SIDECLARA_GITHUB_REPO:-SiDECLARA-releases}"
GITHUB_BRANCH="${SIDECLARA_GITHUB_BRANCH:-main}"
RAW_CLI_URL="https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/${GITHUB_BRANCH}/sideclara-cli.sh"
API_RELEASES="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases"

INSTALL_ROOT="${SIDECLARA_HOME:-/opt/sideclara}"
CLI_PATH="${SIDECLARA_CLI_PATH:-/usr/local/bin/sideclara}"
COMPOSE_FILE="${INSTALL_ROOT}/docker-compose.yml"
ENV_FILE="${INSTALL_ROOT}/.env"
VERSION_FILE="${INSTALL_ROOT}/VERSION"
LOG_DIR="${INSTALL_ROOT}/logs"
BACKUP_DIR="${INSTALL_ROOT}/data/backups"
CACHE_DIR="${SIDECLARA_CACHE_DIR:-${INSTALL_ROOT}/cache/releases}"
LAST_ERROR_LINK="${LOG_DIR}/ultimo-error.txt"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Este programa debe ejecutarse como root (use sudo).${NC}"
    exit 1
  fi
}

# Si llega por pipe (curl | bash), guardar e invocar con TTY interactivo.
bootstrap_if_piped() {
  if [ -n "${SIDECLARA_CLI_BOOTSTRAPPED:-}" ]; then
    return 0
  fi
  local src="${BASH_SOURCE[0]:-}"
  local from_pipe=0

  case "$src" in
    /dev/fd/*|/proc/self/fd/*|/dev/stdin|"")
      from_pipe=1
      ;;
  esac
  # Algunos sistemas reportan /dev/fd/N como "-f" aunque sea un pipe
  if [ "$from_pipe" -eq 0 ] && [ -n "$src" ] && [ -f "$src" ] && [ -t 0 ]; then
    return 0
  fi
  if [ "$from_pipe" -eq 0 ] && [ -t 0 ]; then
    return 0
  fi

  echo "Preparando CLI interactivo..."
  tmp="$(mktemp)"
  # Preferir el propio script si ya está en disco; si no, descargar
  if [ -n "$src" ] && [ -f "$src" ] && [[ "$src" != /dev/fd/* && "$src" != /proc/self/fd/* ]]; then
    cp "$src" "$tmp"
  elif ! curl -fsSL "$RAW_CLI_URL" -o "$tmp"; then
    echo -e "${RED}No se pudo descargar el CLI desde GitHub.${NC}"
    echo "Descargue manualmente: $RAW_CLI_URL"
    echo "O ejecute: curl -fsSL \"$RAW_CLI_URL\" -o /tmp/sideclara-cli.sh && sudo bash /tmp/sideclara-cli.sh"
    exit 1
  fi
  install -m 0755 "$tmp" "$CLI_PATH"
  rm -f "$tmp"
  export SIDECLARA_CLI_BOOTSTRAPPED=1
  if [ -r /dev/tty ]; then
    exec "$CLI_PATH" "$@" </dev/tty >/dev/tty 2>&1
  else
    echo -e "${RED}No hay terminal interactiva (/dev/tty).${NC}"
    echo "Ejecute: curl -fsSL \"$RAW_CLI_URL\" -o /tmp/sideclara-cli.sh && sudo bash /tmp/sideclara-cli.sh"
    exit 1
  fi
}

# Leer siempre desde la terminal real (evita que curl|bash cierre el menú al instante)
read_tty() {
  # usage: read_tty [-p prompt] var
  if [ -r /dev/tty ]; then
    read "$@" </dev/tty
  else
    read "$@"
  fi
}

ensure_cli_installed() {
  mkdir -p "$(dirname "$CLI_PATH")"
  if [ -f "${BASH_SOURCE[0]}" ] && [ "${BASH_SOURCE[0]}" != "$CLI_PATH" ] \
    && [[ "${BASH_SOURCE[0]}" != /dev/fd/* && "${BASH_SOURCE[0]}" != /proc/self/fd/* ]]; then
    install -m 0755 "${BASH_SOURCE[0]}" "$CLI_PATH" 2>/dev/null || true
  fi
}

pause() {
  echo
  read_tty -r -p "Presione ENTER para continuar..." _
}

ask() {
  local prompt="$1"
  local default="${2:-}"
  local reply=""
  if [ -n "$default" ]; then
    read_tty -r -p "$prompt [$default]: " reply || true
    echo "${reply:-$default}"
  else
    read_tty -r -p "$prompt: " reply || true
    echo "$reply"
  fi
}

yes_no() {
  local prompt="$1"
  local reply=""
  read_tty -r -p "$prompt [s/N]: " reply || true
  case "${reply:-}" in
    s|S|si|Si|SI|y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

compose() {
  (cd "$INSTALL_ROOT" && docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@")
}

# Nombres fijos en deploy/docker-compose.yml. Una instalación anterior en otra
# carpeta deja contenedores con el mismo nombre y `compose up` falla con
# "already in use", aunque a veces no aparezcan en `docker ps` (solo en -a).
FIXED_CONTAINER_NAMES=(
  declaraciones_db
  declaraciones_cache
  declaraciones_django
  declaraciones_nginx
  declaraciones_phpmyadmin
)

reclaim_fixed_container_names() {
  local name id workdir ours
  ours="$(cd "$INSTALL_ROOT" 2>/dev/null && pwd -P || echo "$INSTALL_ROOT")"
  for name in "${FIXED_CONTAINER_NAMES[@]}"; do
    id="$(docker inspect -f '{{.Id}}' "$name" 2>/dev/null || true)"
    if [ -z "$id" ]; then
      continue
    fi
    workdir="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$name" 2>/dev/null || true)"
    if [ -n "$workdir" ]; then
      workdir="$(cd "$workdir" 2>/dev/null && pwd -P || echo "$workdir")"
    fi
    if [ -n "$workdir" ] && [ "$workdir" = "$ours" ]; then
      continue
    fi
    echo -e "${YELLOW}Eliminando contenedor conflictivo de otra instalación: ${name}${NC}"
    if [ -n "$workdir" ]; then
      echo "  (pertenecía a: $workdir)"
    fi
    docker rm -f "$name" >/dev/null || true
  done
}

compose_up() {
  reclaim_fixed_container_names
  compose up -d "$@"
}

env_get() {
  local key="$1"
  local default="${2:-}"
  if [ -f "$ENV_FILE" ]; then
    local val
    val="$(grep -E "^${key}=" "$ENV_FILE" | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
    if [ -n "$val" ]; then
      echo "$val"
      return
    fi
  fi
  echo "$default"
}

env_set() {
  local key="$1"
  local value="$2"
  mkdir -p "$INSTALL_ROOT"
  touch "$ENV_FILE"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    # portable in-place replace
    local tmp
    tmp="$(mktemp)"
    awk -v k="$key" -v v="$value" 'BEGIN{FS=OFS="="} $1==k{$0=k"="v} {print}' "$ENV_FILE" >"$tmp"
    mv "$tmp" "$ENV_FILE"
  else
    echo "${key}=${value}" >>"$ENV_FILE"
  fi
}

redact_env_for_log() {
  sed -E \
    -e 's/(PASSWORD|SECRET|TOKEN|KEY|API_KEY)=.*/\1=***REDACTED***/Ig' \
    "$ENV_FILE" 2>/dev/null || true
}

write_error_report() {
  local title="${1:-Error}"
  local detail="${2:-}"
  mkdir -p "$LOG_DIR"
  local stamp file
  stamp="$(date +%Y%m%d-%H%M%S)"
  file="${LOG_DIR}/error-${stamp}.txt"
  {
    echo "===== SideClara — reporte de error ====="
    echo "Fecha: $(date -Iseconds)"
    echo "Título: $title"
    echo
    echo "--- Sistema ---"
    uname -a || true
    echo "OS: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo desconocido)"
    echo "Usuario: $(whoami) / id=$(id)"
    echo
    echo "--- Docker ---"
    docker version 2>&1 || true
    docker compose version 2>&1 || true
    echo
    echo "--- Versión instalada ---"
    cat "$VERSION_FILE" 2>/dev/null || echo "(sin VERSION)"
    echo "HTTP_PORT=$(env_get HTTP_PORT 80)"
    echo
    echo "--- .env (secretos ocultos) ---"
    redact_env_for_log
    echo
    echo "--- Contenedores ---"
    (cd "$INSTALL_ROOT" && docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" ps -a) 2>&1 || true
    echo
    echo "--- Últimos logs (200 líneas) ---"
    (cd "$INSTALL_ROOT" && docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" logs --tail=200) 2>&1 || true
    echo
    echo "--- Detalle ---"
    echo "$detail"
  } >"$file"
  ln -sfn "$file" "$LAST_ERROR_LINK"
  echo -e "${RED}Se generó un reporte de error:${NC}"
  echo -e "  ${BOLD}$file${NC}"
  echo "Puede compartirlo con soporte (menú Herramientas → ver error)."
  echo "$file"
}

require_installed() {
  if [ ! -f "$COMPOSE_FILE" ] || [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}SideClara no parece instalado en ${INSTALL_ROOT}.${NC}"
    echo "Use Instalación → Instalar / preinstalar primero."
    return 1
  fi
  return 0
}

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn "( sport = :$port )" 2>/dev/null | grep -q ":$port" && return 0
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  fi
  return 1
}

# True if the host port is published by our nginx container (safe to reuse on reinstall).
port_held_by_sideclara() {
  local port="$1"
  docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null \
    | grep -E '^declaraciones_nginx[[:space:]]' \
    | grep -qE "[:.]${port}->"
}

# Busy only if something other than SideClara holds the port.
port_busy_by_others() {
  local port="$1"
  if ! port_in_use "$port"; then
    return 1
  fi
  if port_held_by_sideclara "$port"; then
    return 1
  fi
  return 0
}

# Stop current stack so reinstall can keep the same HTTP_PORT.
stop_stack_to_free_ports() {
  if [ ! -f "$COMPOSE_FILE" ]; then
    return 0
  fi
  echo "Deteniendo servicios actuales para liberar / reutilizar puertos..."
  compose stop >/dev/null 2>&1 || true
  # Contenedores huérfanos con los mismos nombres también pueden ocupar el puerto
  docker stop declaraciones_nginx 2>/dev/null || true
}

choose_http_port() {
  local port reuse_msg=""
  port="$(env_get HTTP_PORT 80)"
  if port_held_by_sideclara "$port"; then
    echo -e "${GREEN}El puerto ${port} ya lo usa SideClara; se reutilizará.${NC}"
    env_set HTTP_PORT "$port"
    echo "$port"
    return 0
  fi
  if port_busy_by_others "$port"; then
    echo -e "${YELLOW}El puerto ${port} ya está en uso por otro proceso.${NC}"
    while true; do
      port="$(ask "Ingrese otro puerto HTTP" "8080")"
      if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "Puerto inválido."
        continue
      fi
      if port_busy_by_others "$port"; then
        echo "El puerto $port también está ocupado. Pruebe otro."
        continue
      fi
      if port_held_by_sideclara "$port"; then
        echo "Ese puerto es de SideClara; se reutilizará."
      fi
      break
    done
  fi
  env_set HTTP_PORT "$port"
  echo "$port"
}

install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo -e "${GREEN}Docker y Compose ya están instalados.${NC}"
    return 0
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    echo -e "${RED}Docker no está instalado y no se puede instalar automáticamente en este sistema.${NC}"
    echo "Instale Docker Engine + Compose e intente de nuevo."
    return 1
  fi
  echo "Instalando Docker Engine y el plugin Compose..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  local codename
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
  echo -e "${GREEN}Docker instalado.${NC}"
}

check_prereqs() {
  if [ ! -f /etc/os-release ] || ! grep -qi ubuntu /etc/os-release; then
    echo -e "${YELLOW}Advertencia: este instalador está pensado para Ubuntu.${NC}"
    if [ "${SIDECLARA_NONINTERACTIVE:-0}" = "1" ]; then
      echo "Continuando en modo no interactivo..."
    elif ! yes_no "¿Desea continuar de todos modos?"; then
      return 1
    fi
  fi
  local mem_kb
  mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  if [ "$mem_kb" -gt 0 ] && [ "$mem_kb" -lt 1800000 ]; then
    echo -e "${YELLOW}Advertencia: se recomienda al menos 2 GB de RAM (detectados ~$((mem_kb/1024)) MB).${NC}"
  fi
  local free_kb
  free_kb="$(df -Pk / | awk 'NR==2{print $4}')"
  if [ "${free_kb:-0}" -lt 5000000 ]; then
    echo -e "${YELLOW}Advertencia: se recomienda al menos 5 GB libres en disco.${NC}"
  fi
  return 0
}

latest_release_tag() {
  curl -fsSL "$API_RELEASES/latest" 2>/dev/null \
    | grep -oE '"tag_name":[[:space:]]*"[^"]+"' \
    | head -n1 \
    | sed -E 's/.*"([^"]+)".*/\1/' || true
}

asset_download_url() {
  local tag="$1"
  local name_pattern="$2"
  curl -fsSL "$API_RELEASES/tags/${tag}" 2>/dev/null \
    | python3 -c "
import json,sys
data=json.load(sys.stdin)
pat=sys.argv[1]
for a in data.get('assets',[]):
    if pat in a.get('name',''):
        print(a.get('browser_download_url',''))
        break
" "$name_pattern" 2>/dev/null || true
}

download_release_assets() {
  local tag="$1"
  local tmpdir="$2"
  local ver="${tag#v}"
  echo "Descargando release ${tag}..."

  local img_url bundle_url
  img_url="$(asset_download_url "$tag" "sideclara-app-")"
  bundle_url="$(asset_download_url "$tag" "sideclara-bundle-")"

  if [ -z "$img_url" ] || [ -z "$bundle_url" ]; then
    echo -e "${RED}No se encontraron los archivos de la release ${tag}.${NC}"
    echo "Se esperan assets: sideclara-app-*.tar.gz y sideclara-bundle-*.zip"
    return 1
  fi

  curl -fL --progress-bar -o "${tmpdir}/app.tar.gz" "$img_url"
  curl -fL --progress-bar -o "${tmpdir}/bundle.zip" "$bundle_url"
  echo "$ver" >"${tmpdir}/VERSION"
}

cache_version() {
  if [ -f "$CACHE_DIR/VERSION" ]; then
    tr -d '[:space:]' <"$CACHE_DIR/VERSION"
  fi
}

cache_paths_for_version() {
  local ver="${1#v}"
  CACHE_APP_TAR="$CACHE_DIR/sideclara-app-${ver}.tar.gz"
  CACHE_BUNDLE_ZIP="$CACHE_DIR/sideclara-bundle-${ver}.zip"
}

cache_has_complete() {
  local ver="${1#v}"
  cache_paths_for_version "$ver"
  [ "$(cache_version)" = "$ver" ] && [ -f "$CACHE_APP_TAR" ] && [ -f "$CACHE_BUNDLE_ZIP" ]
}

save_tmpdir_to_cache() {
  local tmpdir="$1"
  local ver
  ver="$(tr -d '[:space:]' <"${tmpdir}/VERSION")"
  ver="${ver#v}"
  mkdir -p "$CACHE_DIR"
  # Mantener solo la versión actual en caché (ahorra disco)
  rm -f "$CACHE_DIR"/sideclara-app-*.tar.gz "$CACHE_DIR"/sideclara-bundle-*.zip
  cp -f "${tmpdir}/app.tar.gz" "$CACHE_DIR/sideclara-app-${ver}.tar.gz"
  cp -f "${tmpdir}/bundle.zip" "$CACHE_DIR/sideclara-bundle-${ver}.zip"
  echo "$ver" >"$CACHE_DIR/VERSION"
  echo "Paquetes guardados en caché: $CACHE_DIR (versión ${ver})"
}

# Rellena tmpdir con app.tar.gz + bundle.zip + VERSION.
# Usa caché local si coincide con el tag; si no, descarga y actualiza la caché.
prepare_release_tmpdir() {
  local tag="$1"
  local tmpdir="$2"
  local ver="${tag#v}"

  if cache_has_complete "$ver"; then
    echo -e "${GREEN}Usando paquetes en caché (${ver}); no se vuelve a descargar.${NC}"
    cache_paths_for_version "$ver"
    cp -f "$CACHE_APP_TAR" "${tmpdir}/app.tar.gz"
    cp -f "$CACHE_BUNDLE_ZIP" "${tmpdir}/bundle.zip"
    echo "$ver" >"${tmpdir}/VERSION"
    return 0
  fi

  if [ -n "$(cache_version)" ] && [ "$(cache_version)" != "$ver" ]; then
    echo "Caché local: $(cache_version) — se necesita ${ver}; descargando..."
  else
    echo "Caché incompleta o vacía; descargando ${tag}..."
  fi
  if ! download_release_assets "$tag" "$tmpdir"; then
    return 1
  fi
  save_tmpdir_to_cache "$tmpdir"
}

refresh_cli_from_github() {
  local tmp
  tmp="$(mktemp)"
  echo "Actualizando CLI en ${CLI_PATH}..."
  if curl -fsSL "$RAW_CLI_URL" -o "$tmp"; then
    install -m 0755 "$tmp" "$CLI_PATH"
    echo -e "${GREEN}CLI instalado.${NC}"
  else
    echo -e "${YELLOW}No se pudo descargar el CLI remoto; se usa el script actual.${NC}"
    ensure_cli_installed
  fi
  rm -f "$tmp"
}

# Resolve offline assets from a directory or explicit file paths.
# Sets globals: OFFLINE_APP_TAR OFFLINE_BUNDLE_ZIP OFFLINE_VERSION
resolve_offline_assets() {
  local dir="${1:-${SIDECLARA_OFFLINE_DIR:-}}"
  local app_tar="${SIDECLARA_APP_TAR:-}"
  local bundle_zip="${SIDECLARA_BUNDLE_ZIP:-}"
  local ver="${SIDECLARA_OFFLINE_VERSION:-}"

  if [ -n "$dir" ]; then
    if [ ! -d "$dir" ]; then
      echo -e "${RED}Directorio offline no encontrado: $dir${NC}"
      return 1
    fi
    if [ -z "$app_tar" ]; then
      app_tar="$(ls -1t "$dir"/sideclara-app-*.tar.gz 2>/dev/null | head -n1 || true)"
    fi
    if [ -z "$bundle_zip" ]; then
      bundle_zip="$(ls -1t "$dir"/sideclara-bundle-*.zip 2>/dev/null | head -n1 || true)"
    fi
    if [ -z "$ver" ] && [ -f "$dir/VERSION" ]; then
      ver="$(tr -d '[:space:]' <"$dir/VERSION")"
    fi
  fi

  if [ -z "$app_tar" ] || [ ! -f "$app_tar" ]; then
    echo -e "${RED}No se encontró sideclara-app-*.tar.gz${NC}"
    echo "Indique el directorio (SIDECLARA_OFFLINE_DIR) o SIDECLARA_APP_TAR=/ruta/al/archivo.tar.gz"
    return 1
  fi
  if [ -z "$bundle_zip" ] || [ ! -f "$bundle_zip" ]; then
    echo -e "${RED}No se encontró sideclara-bundle-*.zip${NC}"
    echo "Indique SIDECLARA_BUNDLE_ZIP=/ruta/al/archivo.zip"
    return 1
  fi

  if [ -z "$ver" ]; then
    ver="$(basename "$app_tar" | sed -E 's/^sideclara-app-//; s/\.tar\.gz$//')"
  fi
  ver="${ver#v}"

  OFFLINE_APP_TAR="$app_tar"
  OFFLINE_BUNDLE_ZIP="$bundle_zip"
  OFFLINE_VERSION="$ver"
  echo "Modo offline: imagen=$(basename "$app_tar") bundle=$(basename "$bundle_zip") versión=$ver"
}

prepare_assets_tmpdir_from_offline() {
  local tmpdir="$1"
  cp -f "$OFFLINE_APP_TAR" "${tmpdir}/app.tar.gz"
  cp -f "$OFFLINE_BUNDLE_ZIP" "${tmpdir}/bundle.zip"
  echo "$OFFLINE_VERSION" >"${tmpdir}/VERSION"
}

ensure_host_tools() {
  local need=()
  command -v curl >/dev/null 2>&1 || need+=(curl)
  command -v unzip >/dev/null 2>&1 || need+=(unzip)
  command -v python3 >/dev/null 2>&1 || need+=(python3)
  command -v openssl >/dev/null 2>&1 || need+=(openssl)
  if [ "${#need[@]}" -eq 0 ]; then
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then
    echo "Instalando herramientas: ${need[*]}"
    apt-get update -y
    apt-get install -y "${need[@]}"
  else
    echo -e "${RED}Faltan herramientas: ${need[*]}${NC}"
    echo "Instálelas manualmente e intente de nuevo."
    return 1
  fi
}

extract_bundle_to_install_root() {
  local zipfile="$1"
  local tmp
  tmp="$(mktemp -d)"
  unzip -qo "$zipfile" -d "$tmp"
  # bundle may contain deploy/ or files at root
  if [ -d "$tmp/deploy" ]; then
    cp -a "$tmp/deploy/." "$INSTALL_ROOT/"
  else
    cp -a "$tmp/." "$INSTALL_ROOT/"
  fi
  rm -rf "$tmp"
  mkdir -p "$BACKUP_DIR" "$LOG_DIR" "$INSTALL_ROOT/data"
}

# Apply install from tmpdir containing app.tar.gz, bundle.zip, VERSION
apply_install_from_tmpdir() {
  local tmp="$1"
  local skip_cleanup="${2:-0}"

  # Liberar puertos de una instalación previa (evita pedir otro HTTP_PORT al reinstalar)
  stop_stack_to_free_ports

  # Preservar .env existente al reinstalar
  local env_bak=""
  if [ -f "$ENV_FILE" ]; then
    env_bak="$(mktemp)"
    cp "$ENV_FILE" "$env_bak"
  fi

  extract_bundle_to_install_root "${tmp}/bundle.zip"

  if [ -n "$env_bak" ]; then
    mv "$env_bak" "$ENV_FILE"
  elif [ -f "$INSTALL_ROOT/.env.example" ]; then
    cp "$INSTALL_ROOT/.env.example" "$ENV_FILE"
    local sk
    sk="$(openssl rand -hex 24 2>/dev/null || head -c 48 /dev/urandom | xxd -p | tr -d '\n')"
    env_set SECRET_KEY "$sk"
  else
    write_error_report "Falta .env.example" "El bundle no incluyó .env.example"
    return 1
  fi

  local http_port
  if [ -n "${SIDECLARA_HTTP_PORT:-}" ]; then
    env_set HTTP_PORT "$SIDECLARA_HTTP_PORT"
    http_port="$SIDECLARA_HTTP_PORT"
    if port_busy_by_others "$http_port"; then
      echo -e "${YELLOW}Advertencia: el puerto ${http_port} parece ocupado por otro proceso.${NC}"
    fi
  elif [ "${SIDECLARA_NONINTERACTIVE:-0}" = "1" ]; then
    http_port="$(env_get HTTP_PORT 8080)"
    if port_busy_by_others 80 && [ "$http_port" = "80" ]; then
      http_port=8080
    fi
    while port_busy_by_others "$http_port"; do
      http_port=$((http_port + 1))
    done
    env_set HTTP_PORT "$http_port"
  else
    # Si ya había HTTP_PORT en .env (reinstalación), preferirlo sin preguntar
    if [ -n "$env_bak" ] && [ -n "$(env_get HTTP_PORT "")" ]; then
      http_port="$(env_get HTTP_PORT 80)"
      if port_busy_by_others "$http_port"; then
        echo -e "${YELLOW}El puerto configurado ${http_port} está ocupado por otro proceso.${NC}"
        http_port="$(choose_http_port)"
      else
        echo -e "${GREEN}Reutilizando puerto HTTP ${http_port} de la instalación anterior.${NC}"
        env_set HTTP_PORT "$http_port"
      fi
    else
      http_port="$(choose_http_port)"
    fi
  fi

  local ver
  ver="$(tr -d '[:space:]' <"${tmp}/VERSION")"
  ver="${ver#v}"
  env_set SIDECLARA_VERSION "$ver"
  env_set DBHOST db
  env_set REDIS_HOST redis
  env_set LOAD_INITIAL_DATA 1
  echo "$ver" >"$VERSION_FILE"

  echo "Cargando imagen Docker (puede tardar)..."
  if ! docker load -i "${tmp}/app.tar.gz"; then
    write_error_report "docker load falló" "archivo=${tmp}/app.tar.gz"
    return 1
  fi
  if docker image inspect "sideclara-app:${ver}" >/dev/null 2>&1; then
    docker tag "sideclara-app:${ver}" sideclara-app:latest || true
  else
    docker tag sideclara-app:latest "sideclara-app:${ver}" 2>/dev/null || true
  fi

  if [ "$skip_cleanup" != "1" ]; then
    rm -rf "$tmp"
  fi

  echo "Iniciando servicios..."
  if ! compose_up; then
    write_error_report "compose up falló" "HTTP_PORT=$http_port"
    return 1
  fi

  echo "Esperando a que la aplicación responda..."
  local i ok=0
  for i in $(seq 1 120); do
    if curl -fsS -o /dev/null "http://127.0.0.1:${http_port}/" 2>/dev/null; then
      ok=1
      break
    fi
    # Si el contenedor de la app está en bucle de reinicio, fallar antes
    local django_status
    django_status="$(docker ps -a --filter name=declaraciones_django --format '{{.Status}}' 2>/dev/null || true)"
    if echo "$django_status" | grep -qi 'Restarting'; then
      if [ "$i" -ge 12 ]; then
        echo -e "${YELLOW}El contenedor de la aplicación se reinicia repetidamente.${NC}"
        break
      fi
    fi
    sleep 5
  done

  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  ip="${ip:-127.0.0.1}"

  if [ "$ok" -eq 1 ]; then
    echo -e "${GREEN}Instalación completada.${NC}"
  else
    echo -e "${YELLOW}Los contenedores arrancaron, pero aún no hay respuesta HTTP.${NC}"
    echo "Revise el menú Estado (salud) o Herramientas → ver error."
    write_error_report "Sin respuesta HTTP" "Se esperó ~5 minutos en el puerto $http_port"
  fi

  if [ "$http_port" = "80" ]; then
    echo -e "Abra en el navegador: ${BOLD}http://${ip}/${NC}"
  else
    echo -e "Abra en el navegador: ${BOLD}http://${ip}:${http_port}/${NC}"
  fi
  echo "CLI instalado en: $CLI_PATH (ejecute: sudo sideclara)"
  return 0
}

do_install_online() {
  local tag
  tag="$(latest_release_tag)"
  if [ -z "$tag" ]; then
    echo -e "${RED}No hay releases en GitHub (${GITHUB_OWNER}/${GITHUB_REPO}).${NC}"
    echo "Publique una release, use instalación offline, o indique un tag."
    if [ "${SIDECLARA_NONINTERACTIVE:-0}" = "1" ]; then
      write_error_report "Sin release" "No se pudo obtener el tag de release"
      return 1
    fi
    tag="$(ask "Tag de release (ej. v1.0.0)" "")"
    if [ -z "$tag" ]; then
      write_error_report "Sin release" "No se pudo obtener el tag de release"
      return 1
    fi
  else
    echo "Última release: ${tag}"
    local cached
    cached="$(cache_version)"
    if [ -n "$cached" ]; then
      if [ "$cached" = "${tag#v}" ] && cache_has_complete "$cached"; then
        echo -e "Caché local: ${GREEN}${cached} (lista para usar)${NC}"
      else
        echo -e "Caché local: ${YELLOW}${cached}${NC}"
      fi
    fi
    if [ "${SIDECLARA_NONINTERACTIVE:-0}" != "1" ]; then
      if ! yes_no "¿Instalar la versión ${tag}?"; then
        tag="$(ask "Indique el tag a instalar" "$tag")"
      fi
    fi
  fi

  local tmp
  tmp="$(mktemp -d)"
  if ! prepare_release_tmpdir "$tag" "$tmp"; then
    write_error_report "Descarga fallida" "tag=$tag"
    rm -rf "$tmp"
    return 1
  fi
  apply_install_from_tmpdir "$tmp"
}

do_preinstall() {
  echo -e "${BOLD}=== Preinstalar (CLI + paquetes en caché) ===${NC}"
  echo "No arranca contenedores. Solo instala el comando sideclara y descarga"
  echo "los instaladores de la última release para reutilizarlos al instalar."
  echo
  check_prereqs || return 1
  ensure_host_tools || return 1
  mkdir -p "$INSTALL_ROOT" "$CACHE_DIR" "$LOG_DIR"
  refresh_cli_from_github

  local tag
  tag="$(latest_release_tag)"
  if [ -z "$tag" ]; then
    echo -e "${RED}No se pudo obtener la última release.${NC}"
    return 1
  fi
  echo "Última release: ${tag}"

  if cache_has_complete "${tag#v}"; then
    echo -e "${GREEN}Ya tiene los paquetes de ${tag#v} en caché.${NC}"
    echo "Ubicación: $CACHE_DIR"
    if [ "${SIDECLARA_NONINTERACTIVE:-0}" != "1" ] && yes_no "¿Volver a descargar de todos modos?"; then
      rm -f "$CACHE_DIR"/sideclara-app-*.tar.gz "$CACHE_DIR"/sideclara-bundle-*.zip "$CACHE_DIR/VERSION"
    else
      echo "Listo. Use Instalación → Instalar para aplicar estos paquetes."
      return 0
    fi
  fi

  local tmp
  tmp="$(mktemp -d)"
  if ! prepare_release_tmpdir "$tag" "$tmp"; then
    write_error_report "Preinstalación: descarga fallida" "tag=$tag"
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
  echo -e "${GREEN}Preinstalación completada.${NC}"
  echo "Caché: $CACHE_DIR"
  echo "Siguiente paso: menú Instalación → Instalar / reinstalar"
}

do_install_offline() {
  local dir="${1:-${SIDECLARA_OFFLINE_DIR:-}}"
  if [ -z "$dir" ] && [ -z "${SIDECLARA_APP_TAR:-}" ]; then
    if [ "${SIDECLARA_NONINTERACTIVE:-0}" = "1" ]; then
      echo -e "${RED}Falta SIDECLARA_OFFLINE_DIR o SIDECLARA_APP_TAR/SIDECLARA_BUNDLE_ZIP.${NC}"
      return 1
    fi
    dir="$(ask "Ruta al directorio con sideclara-app-*.tar.gz y sideclara-bundle-*.zip" ".")"
  fi

  if ! resolve_offline_assets "$dir"; then
    write_error_report "Assets offline inválidos" "dir=$dir"
    return 1
  fi

  local tmp
  tmp="$(mktemp -d)"
  prepare_assets_tmpdir_from_offline "$tmp"
  apply_install_from_tmpdir "$tmp"
}

do_install() {
  echo -e "${BOLD}=== Instalar / reinstalar SideClara ===${NC}"
  check_prereqs || return 1
  ensure_host_tools
  install_docker_if_needed

  mkdir -p "$INSTALL_ROOT" "$LOG_DIR" "$BACKUP_DIR"
  ensure_cli_installed

  # Auto-offline if env points to local assets
  if [ -n "${SIDECLARA_OFFLINE_DIR:-}" ] || [ -n "${SIDECLARA_APP_TAR:-}" ]; then
    echo "Detectado modo offline (variables de entorno)."
    do_install_offline
    return $?
  fi

  if [ "${SIDECLARA_NONINTERACTIVE:-0}" = "1" ]; then
    do_install_online
    return $?
  fi

  echo
  echo "¿Cómo desea instalar?"
  echo "  1) Desde GitHub Releases (requiere Internet)"
  echo "  2) Desde archivos locales / offline (tar.gz + zip)"
  local mode
  mode="$(ask "Elija" "1")"
  case "$mode" in
    2) do_install_offline ;;
    *) do_install_online ;;
  esac
}

do_health() {
  echo -e "${BOLD}=== Estado del sistema ===${NC}"
  if [ ! -f "$COMPOSE_FILE" ]; then
    echo -e "${RED}ERROR${NC}: SideClara no parece instalado en $INSTALL_ROOT"
    return 1
  fi
  local ver http_port
  ver="$(cat "$VERSION_FILE" 2>/dev/null || echo desconocida)"
  http_port="$(env_get HTTP_PORT 80)"
  echo "Versión: $ver"
  echo "Puerto HTTP: $http_port"
  echo
  echo "--- Contenedores ---"
  compose ps || true
  echo
  local status
  status="$(compose ps --format json 2>/dev/null || true)"
  for svc in db redis declaraciones nginx; do
    if compose ps --status running 2>/dev/null | grep -q "$svc\|declaraciones_"; then
      echo -e "Servicio relacionado con ${svc}: ${GREEN}OK${NC}"
    else
      # fallback simpler check
      if docker ps --format '{{.Names}}' | grep -qE "declaraciones_(db|cache|django|nginx)|${svc}"; then
        echo -e "${svc}: ${GREEN}OK${NC}"
      else
        echo -e "${svc}: ${RED}ERROR / no en ejecución${NC}"
      fi
    fi
  done
  echo
  if curl -fsS -o /dev/null "http://127.0.0.1:${http_port}/" 2>/dev/null; then
    echo -e "HTTP :${http_port}: ${GREEN}OK${NC}"
  else
    echo -e "HTTP :${http_port}: ${RED}ERROR${NC}"
  fi
  if docker exec declaraciones_db mysqladmin ping -h127.0.0.1 --silent 2>/dev/null; then
    echo -e "Base de datos: ${GREEN}OK${NC}"
  else
    echo -e "Base de datos: ${RED}ERROR${NC}"
  fi
  if docker exec declaraciones_cache redis-cli ping 2>/dev/null | grep -q PONG; then
    echo -e "Redis: ${GREEN}OK${NC}"
  else
    echo -e "Redis: ${RED}ERROR${NC}"
  fi
  echo
  df -h / | awk 'NR==1 || NR==2'
}

do_check_updates() {
  echo -e "${BOLD}=== Buscar actualizaciones ===${NC}"
  local current latest
  current="$(cat "$VERSION_FILE" 2>/dev/null || echo "0.0.0")"
  latest="$(latest_release_tag)"
  if [ -z "$latest" ]; then
    echo -e "${RED}No se pudo consultar GitHub Releases.${NC}"
    write_error_report "Fallo al buscar actualizaciones" "API $API_RELEASES/latest"
    return 1
  fi
  local latest_ver="${latest#v}"
  echo "Versión instalada: $current"
  echo "Última disponible: $latest_ver ($latest)"
  if [ "$current" = "$latest_ver" ] || [ "v$current" = "$latest" ]; then
    echo -e "${GREEN}Ya tiene la última versión.${NC}"
  else
    echo -e "${YELLOW}Hay una versión nueva. Use Instalación → Actualizar.${NC}"
  fi
}

do_update() {
  echo -e "${BOLD}=== Actualizar SideClara ===${NC}"
  if [ ! -f "$COMPOSE_FILE" ]; then
    echo "Primero debe instalar (opción 1)."
    return 1
  fi
  ensure_host_tools
  local tag
  tag="$(latest_release_tag)"
  tag="$(ask "Tag a instalar" "${tag:-}")"
  if [ -z "$tag" ]; then
    echo "Cancelado."
    return 1
  fi
  if ! yes_no "Se creará un respaldo de la BD antes de actualizar. ¿Continuar?"; then
    return 1
  fi
  do_backup || {
    echo -e "${RED}No se pudo respaldar; se cancela la actualización.${NC}"
    return 1
  }

  local tmp
  tmp="$(mktemp -d)"
  if ! prepare_release_tmpdir "$tag" "$tmp"; then
    write_error_report "Descarga de actualización fallida" "tag=$tag"
    rm -rf "$tmp"
    return 1
  fi

  local env_bak
  env_bak="$(mktemp)"
  cp "$ENV_FILE" "$env_bak"

  extract_bundle_to_install_root "${tmp}/bundle.zip"
  mv "$env_bak" "$ENV_FILE"
  local ver
  ver="$(tr -d '[:space:]' <"${tmp}/VERSION")"
  env_set SIDECLARA_VERSION "$ver"
  env_set LOAD_INITIAL_DATA 0
  echo "$ver" >"$VERSION_FILE"

  if ! docker load -i "${tmp}/app.tar.gz"; then
    write_error_report "docker load en actualización falló" "tag=$tag"
    rm -rf "$tmp"
    return 1
  fi
  docker tag "sideclara-app:${ver}" sideclara-app:latest 2>/dev/null || \
    docker tag sideclara-app:latest "sideclara-app:${ver}" 2>/dev/null || true
  rm -rf "$tmp"

  if ! compose_up; then
    write_error_report "compose up tras actualizar falló" "tag=$tag"
    return 1
  fi
  echo -e "${GREEN}Actualización a ${ver} completada.${NC}"
  echo "Las migraciones se aplican al arrancar el contenedor de la aplicación."
}

do_backup() {
  echo -e "${BOLD}=== Respaldo de base de datos ===${NC}"
  if ! docker ps --format '{{.Names}}' | grep -qx declaraciones_db; then
    echo -e "${RED}El contenedor de base de datos no está en ejecución.${NC}"
    write_error_report "Backup: DB no corre" ""
    return 1
  fi
  mkdir -p "$BACKUP_DIR"
  local stamp out user pass dbname
  stamp="$(date +%Y%m%d-%H%M%S)"
  out="${BACKUP_DIR}/sideclara-${stamp}.sql.gz"
  user="$(env_get MYSQL_USER declaracionesus)"
  pass="$(env_get MYSQL_PASSWORD)"
  dbname="$(env_get MYSQL_DATABASE declaracionesdb)"

  if docker exec declaraciones_db \
      mysqldump -u"$user" -p"$pass" --single-transaction --routines --triggers "$dbname" \
      | gzip -c >"$out"; then
    echo -e "${GREEN}Respaldo guardado en:${NC} $out"
    ls -lh "$out"
  else
    rm -f "$out"
    write_error_report "mysqldump falló" "user=$user db=$dbname"
    return 1
  fi
}

do_restore() {
  echo -e "${BOLD}=== Restaurar base de datos ===${NC}"
  mkdir -p "$BACKUP_DIR"
  echo "Respaldos disponibles en $BACKUP_DIR:"
  local files=()
  local i=0
  local f
  shopt -s nullglob
  for f in "$BACKUP_DIR"/sideclara-*.sql.gz "$BACKUP_DIR"/*.sql.gz "$BACKUP_DIR"/*.sql; do
    i=$((i + 1))
    files+=("$f")
    echo "  $i) $(basename "$f")"
  done
  shopt -u nullglob
  if [ "$i" -eq 0 ]; then
    echo "No hay archivos de respaldo."
    local path
    path="$(ask "Ruta completa del archivo .sql o .sql.gz" "")"
    [ -n "$path" ] || return 1
    files=("$path")
    i=1
  fi
  local choice
  choice="$(ask "Número de archivo a restaurar" "1")"
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$i" ]; then
    echo "Selección inválida."
    return 1
  fi
  local src="${files[$((choice - 1))]}"
  echo -e "${YELLOW}ADVERTENCIA: esto reemplazará los datos actuales de la base.${NC}"
  if ! yes_no "¿Continuar con la restauración de $(basename "$src")?"; then
    return 1
  fi
  do_backup || true

  local user pass dbname
  user="$(env_get MYSQL_USER declaracionesus)"
  pass="$(env_get MYSQL_PASSWORD)"
  dbname="$(env_get MYSQL_DATABASE declaracionesdb)"

  if [[ "$src" == *.gz ]]; then
    if gunzip -c "$src" | docker exec -i declaraciones_db mysql -u"$user" -p"$pass" "$dbname"; then
      echo -e "${GREEN}Restauración completada.${NC}"
    else
      write_error_report "Restauración falló" "archivo=$src"
      return 1
    fi
  else
    if docker exec -i declaraciones_db mysql -u"$user" -p"$pass" "$dbname" <"$src"; then
      echo -e "${GREEN}Restauración completada.${NC}"
    else
      write_error_report "Restauración falló" "archivo=$src"
      return 1
    fi
  fi
}

do_change_port() {
  echo -e "${BOLD}=== Cambiar puerto HTTP ===${NC}"
  if [ ! -f "$ENV_FILE" ]; then
    echo "SideClara no está instalado."
    return 1
  fi
  local current new
  current="$(env_get HTTP_PORT 80)"
  echo "Puerto actual: $current"
  new="$(ask "Nuevo puerto HTTP" "$current")"
  if ! [[ "$new" =~ ^[0-9]+$ ]]; then
    echo "Puerto inválido."
    return 1
  fi
  if [ "$new" != "$current" ] && port_busy_by_others "$new"; then
    echo "El puerto $new está ocupado."
    return 1
  fi
  env_set HTTP_PORT "$new"
  compose up -d nginx
  echo -e "${GREEN}Puerto actualizado a ${new}.${NC}"
}

do_show_error() {
  echo -e "${BOLD}=== Ver / compartir último error ===${NC}"
  if [ ! -e "$LAST_ERROR_LINK" ] && [ ! -d "$LOG_DIR" ]; then
    echo "No hay reportes de error todavía."
    return 0
  fi
  local file=""
  if [ -L "$LAST_ERROR_LINK" ] || [ -f "$LAST_ERROR_LINK" ]; then
    file="$(readlink -f "$LAST_ERROR_LINK" 2>/dev/null || echo "$LAST_ERROR_LINK")"
  else
    file="$(ls -1t "$LOG_DIR"/error-*.txt 2>/dev/null | head -n1 || true)"
  fi
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    echo "No hay reportes de error."
    return 0
  fi
  echo "Archivo: $file"
  echo "---------- inicio del reporte ----------"
  cat "$file"
  echo "---------- fin del reporte ----------"
  echo
  echo "Para compartirlo, copie el archivo o envíe su contenido por correo/chat."
  echo "Ruta: $file"
}

do_phpmyadmin() {
  echo -e "${BOLD}=== phpMyAdmin (opcional) ===${NC}"
  if [ ! -f "$COMPOSE_FILE" ]; then
    echo "Primero debe instalar SideClara."
    return 1
  fi
  local pma_port
  pma_port="$(env_get PHPMYADMIN_PORT 8080)"
  if docker ps --format '{{.Names}}' | grep -qx declaraciones_phpmyadmin; then
    echo "phpMyAdmin ya está en ejecución en el puerto $pma_port"
    if yes_no "¿Desea detenerlo?"; then
      compose stop phpmyadmin || true
      echo "Detenido."
    fi
    return 0
  fi
  if port_in_use "$pma_port"; then
    pma_port="$(ask "Puerto para phpMyAdmin (el $pma_port está ocupado)" "8081")"
    env_set PHPMYADMIN_PORT "$pma_port"
  fi
  if yes_no "¿Activar phpMyAdmin en el puerto ${pma_port}?"; then
    compose up -d phpmyadmin
    local ip
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    echo -e "${GREEN}phpMyAdmin:${NC} http://${ip:-127.0.0.1}:${pma_port}/"
    echo "Host del servidor en phpMyAdmin: db"
  fi
}

do_start() {
  echo -e "${BOLD}=== Iniciar servicios ===${NC}"
  require_installed || return 1
  if ! compose_up; then
    write_error_report "No se pudieron iniciar los servicios" ""
    return 1
  fi
  echo -e "${GREEN}Servicios iniciados.${NC}"
}

do_restart() {
  echo -e "${BOLD}=== Reiniciar servicios ===${NC}"
  require_installed || return 1
  echo "Esto reinicia los contenedores de SideClara (la BD también se reinicia brevemente)."
  if [ "${SIDECLARA_NONINTERACTIVE:-0}" != "1" ] && ! yes_no "¿Continuar?"; then
    echo "Cancelado."
    return 1
  fi
  if compose restart; then
    echo -e "${GREEN}Servicios reiniciados.${NC}"
  else
    echo -e "${YELLOW}compose restart falló; intentando compose up -d...${NC}"
    if ! compose_up; then
      write_error_report "Reinicio falló" ""
      return 1
    fi
    echo -e "${GREEN}Servicios levantados de nuevo.${NC}"
  fi
}

do_stop() {
  echo -e "${BOLD}=== Detener servicios ===${NC}"
  require_installed || return 1
  echo -e "${YELLOW}Los contenedores se detendrán. Los datos en volúmenes se conservan.${NC}"
  echo "La web dejará de responder hasta que inicie de nuevo."
  if [ "${SIDECLARA_NONINTERACTIVE:-0}" != "1" ] && ! yes_no "¿Detener SideClara ahora?"; then
    echo "Cancelado."
    return 1
  fi
  compose stop || true
  echo -e "${GREEN}Servicios detenidos.${NC}"
}

do_uninstall() {
  echo -e "${BOLD}=== Desinstalar SideClara ===${NC}"
  echo
  echo -e "${RED}${BOLD}ADVERTENCIA${NC}"
  echo "Esta acción puede eliminar contenedores, el directorio de instalación"
  echo "y, si lo confirma, también la base de datos y archivos subidos."
  echo "Directorio: $INSTALL_ROOT"
  echo
  if ! yes_no "¿Desea continuar con la desinstalación?"; then
    echo "Cancelado."
    return 1
  fi

  local remove_volumes=0
  if [ -f "$COMPOSE_FILE" ]; then
    echo
    echo -e "${YELLOW}¿Eliminar también los VOLÚMENES (BD MySQL, media, static)?${NC}"
    echo "Si responde sí, se pierde la información de declaraciones. Haga un respaldo antes."
    if yes_no "¿Borrar volúmenes de datos? (irreversible)"; then
      if yes_no "Confirme de nuevo: ¿borrar definitivamente la base de datos y archivos?"; then
        remove_volumes=1
      fi
    fi
    echo "Deteniendo contenedores..."
    if [ "$remove_volumes" -eq 1 ]; then
      (cd "$INSTALL_ROOT" && docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down -v) || true
    else
      (cd "$INSTALL_ROOT" && docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down) || true
    fi
  fi

  for name in "${FIXED_CONTAINER_NAMES[@]}"; do
    docker rm -f "$name" >/dev/null 2>&1 || true
  done

  local remove_dir=0
  if [ -d "$INSTALL_ROOT" ]; then
    if yes_no "¿Eliminar el directorio ${INSTALL_ROOT} (config, logs, caché, respaldos)?"; then
      remove_dir=1
    fi
  fi
  if [ "$remove_dir" -eq 1 ]; then
    rm -rf "$INSTALL_ROOT"
    echo "Directorio eliminado."
  fi

  if [ -e "$CLI_PATH" ] && yes_no "¿Eliminar el comando ${CLI_PATH}?"; then
    rm -f "$CLI_PATH"
    echo "CLI eliminado."
  fi

  echo
  if [ "$remove_volumes" -eq 1 ]; then
    echo -e "${GREEN}Desinstalación completada (incluidos volúmenes).${NC}"
  else
    echo -e "${GREEN}Desinstalación de contenedores completada.${NC}"
    if [ "$remove_dir" -eq 0 ]; then
      echo "Los datos/config pueden seguir en $INSTALL_ROOT"
    fi
    echo "Volúmenes Docker de SideClara pueden seguir en el sistema si no los borró."
  fi
}

do_clean_temp() {
  echo -e "${BOLD}=== Limpiar archivos temporales ===${NC}"
  echo "Se pueden borrar:"
  echo "  • /tmp/sideclara* (descargas temporales)"
  echo "  • Caché de paquetes: $CACHE_DIR"
  echo "  • Reportes de error antiguos en $LOG_DIR (opcional)"
  echo
  local freed=0

  if yes_no "¿Limpiar /tmp/sideclara* ?"; then
    rm -rf /tmp/sideclara /tmp/sideclara-* /tmp/sideclara_cli* 2>/dev/null || true
    echo "Temporales /tmp/sideclara* eliminados (si existían)."
    freed=1
  fi

  if [ -d "$CACHE_DIR" ]; then
    local cver size
    cver="$(cache_version)"
    size="$(du -sh "$CACHE_DIR" 2>/dev/null | awk '{print $1}')"
    echo "Caché actual: versión=${cver:-vacía} tamaño=${size:-?} ($CACHE_DIR)"
    if yes_no "¿Vaciar la caché de instaladores? (la próxima instalación descargará de nuevo)"; then
      rm -rf "$CACHE_DIR"
      mkdir -p "$CACHE_DIR"
      echo "Caché vaciada."
      freed=1
    fi
  else
    echo "No hay caché de paquetes."
  fi

  if [ -d "$LOG_DIR" ] && yes_no "¿Borrar reportes de error antiguos (conservar el último)?"; then
    local last=""
    if [ -L "$LAST_ERROR_LINK" ] || [ -f "$LAST_ERROR_LINK" ]; then
      last="$(readlink -f "$LAST_ERROR_LINK" 2>/dev/null || true)"
    fi
    if [ -n "$last" ]; then
      find "$LOG_DIR" -maxdepth 1 -type f -name 'error-*.txt' ! -samefile "$last" -delete 2>/dev/null || \
        find "$LOG_DIR" -maxdepth 1 -type f -name 'error-*.txt' ! -path "$last" -delete 2>/dev/null || true
    else
      find "$LOG_DIR" -maxdepth 1 -type f -name 'error-*.txt' -delete 2>/dev/null || true
    fi
    echo "Reportes antiguos eliminados."
    freed=1
  fi

  if [ "$freed" -eq 0 ]; then
    echo "No se eliminó nada."
  else
    echo -e "${GREEN}Limpieza terminada.${NC}"
  fi
}

do_load_catalogs() {
  echo -e "${BOLD}=== Cargar catálogos iniciales ===${NC}"
  require_installed || return 1
  if ! docker ps --format '{{.Names}}' | grep -qx declaraciones_django; then
    echo -e "${RED}El contenedor de la aplicación no está en ejecución.${NC}"
    echo "Use Servicios → Iniciar y vuelva a intentar."
    return 1
  fi

  echo "Esto ejecuta loaddata de catálogos (estados, municipios, tipos, FAQ, etc.)."
  echo -e "${YELLOW}Si ya hay datos, pueden aparecer errores de clave duplicada en algunos fixtures.${NC}"
  echo "También carga dumpAuthUser (usuarios de ejemplo del fixture)."
  echo
  if [ "${SIDECLARA_NONINTERACTIVE:-0}" != "1" ] && ! yes_no "¿Cargar catálogos ahora?"; then
    echo "Cancelado."
    return 1
  fi

  echo "Cargando catálogos (puede tardar varios minutos)..."
  if docker exec -e LOAD_INITIAL_DATA=1 declaraciones_django sh /code/scripts/loaddata-catalog.sh; then
    docker exec declaraciones_django touch /var/lib/sideclara/.initialized 2>/dev/null || true
    env_set LOAD_INITIAL_DATA 0
    echo -e "${GREEN}Carga de catálogos finalizada.${NC}"
    echo "Marcador de inicialización actualizado; no se volverán a cargar solos al reiniciar."
    return 0
  fi

  write_error_report "Carga de catálogos falló" "loaddata-catalog.sh"
  echo -e "${YELLOW}La carga terminó con errores. Revise el reporte o los logs del contenedor.${NC}"
  echo "Si solo fallaron fixtures ya existentes, parte de los catálogos puede estar bien."
  return 1
}

menu_instalacion() {
  while true; do
    echo
    echo -e "${BOLD}--- Instalación ---${NC}"
    echo "1) Instalar / reinstalar"
    echo "2) Preinstalar (CLI + descargar paquetes a caché)"
    echo "3) Buscar actualizaciones"
    echo "4) Actualizar a una nueva versión"
    echo "5) Instalar desde archivos locales (offline)"
    echo "6) Cargar catálogos iniciales"
    echo "0) Volver"
    local opt
    opt="$(ask "Elija" "")"
    case "$opt" in
      1) do_install; pause ;;
      2) do_preinstall; pause ;;
      3) do_check_updates; pause ;;
      4) do_update; pause ;;
      5)
        echo -e "${BOLD}=== Instalación offline ===${NC}"
        check_prereqs || { pause; continue; }
        ensure_host_tools || { pause; continue; }
        install_docker_if_needed || { pause; continue; }
        mkdir -p "$INSTALL_ROOT" "$LOG_DIR" "$BACKUP_DIR"
        ensure_cli_installed
        do_install_offline
        pause
        ;;
      6) do_load_catalogs; pause ;;
      0|"") return 0 ;;
      *) echo "Opción no válida." ;;
    esac
  done
}

menu_servicios() {
  while true; do
    echo
    echo -e "${BOLD}--- Servicios ---${NC}"
    echo "1) Iniciar"
    echo "2) Reiniciar"
    echo "3) Detener"
    echo "0) Volver"
    local opt
    opt="$(ask "Elija" "")"
    case "$opt" in
      1) do_start; pause ;;
      2) do_restart; pause ;;
      3) do_stop; pause ;;
      0|"") return 0 ;;
      *) echo "Opción no válida." ;;
    esac
  done
}

menu_datos() {
  while true; do
    echo
    echo -e "${BOLD}--- Datos ---${NC}"
    echo "1) Respaldo de base de datos"
    echo "2) Restaurar base de datos"
    echo "3) Cargar catálogos iniciales"
    echo "0) Volver"
    local opt
    opt="$(ask "Elija" "")"
    case "$opt" in
      1) do_backup; pause ;;
      2) do_restore; pause ;;
      3) do_load_catalogs; pause ;;
      0|"") return 0 ;;
      *) echo "Opción no válida." ;;
    esac
  done
}

menu_herramientas() {
  while true; do
    echo
    echo -e "${BOLD}--- Herramientas ---${NC}"
    echo "1) Cambiar puerto HTTP"
    echo "2) Ver / compartir último error"
    echo "3) Activar / gestionar phpMyAdmin"
    echo "4) Limpiar archivos temporales / caché"
    echo "0) Volver"
    local opt
    opt="$(ask "Elija" "")"
    case "$opt" in
      1) do_change_port; pause ;;
      2) do_show_error; pause ;;
      3) do_phpmyadmin; pause ;;
      4) do_clean_temp; pause ;;
      0|"") return 0 ;;
      *) echo "Opción no válida." ;;
    esac
  done
}

show_menu() {
  clear 2>/dev/null || true
  local ver cached
  ver="$(cat "$VERSION_FILE" 2>/dev/null || echo "no instalado")"
  cached="$(cache_version)"
  echo -e "${CYAN}${BOLD}"
  echo "========================================"
  echo "           SideClara"
  echo "========================================"
  echo -e "${NC}"
  echo "Versión instalada: $ver"
  echo "Directorio: $INSTALL_ROOT"
  if [ -n "$cached" ]; then
    echo "Caché de paquetes: $cached ($CACHE_DIR)"
  fi
  echo
  echo "1) Instalación (instalar, preinstalar, actualizar…)"
  echo "2) Servicios (iniciar, reiniciar, detener)"
  echo "3) Estado del sistema (salud)"
  echo "4) Datos (respaldo / restaurar)"
  echo "5) Herramientas (puerto, errores, phpMyAdmin, limpiar)"
  echo "6) Desinstalar"
  echo "0) Salir"
  echo
}

main_menu() {
  while true; do
    show_menu
    local opt
    opt="$(ask "Elija una opción" "")"
    case "$opt" in
      1) menu_instalacion ;;
      2) menu_servicios ;;
      3) do_health; pause ;;
      4) menu_datos ;;
      5) menu_herramientas ;;
      6) do_uninstall; pause ;;
      0) echo "Hasta luego."; exit 0 ;;
      "")
        echo -e "${YELLOW}No se recibió opción. Si usó curl|bash, pruebe:${NC}"
        echo "  curl -fsSL \"$RAW_CLI_URL\" -o /tmp/sideclara-cli.sh && sudo bash /tmp/sideclara-cli.sh"
        pause
        ;;
      *) echo "Opción no válida."; pause ;;
    esac
  done
}

main() {
  require_root
  bootstrap_if_piped "$@"
  ensure_cli_installed
  mkdir -p "$INSTALL_ROOT" "$LOG_DIR"

  case "${1:-}" in
    install) shift; do_install "$@"; exit $? ;;
    preinstall) do_preinstall; exit $? ;;
    install-offline|offline)
      shift
      check_prereqs || exit 1
      ensure_host_tools || exit 1
      install_docker_if_needed || exit 1
      mkdir -p "$INSTALL_ROOT" "$LOG_DIR" "$BACKUP_DIR"
      do_install_offline "${1:-}"
      exit $?
      ;;
    health|status) do_health; exit $? ;;
    start) do_start; exit $? ;;
    restart) do_restart; exit $? ;;
    stop) do_stop; exit $? ;;
    update) shift; do_update "$@"; exit $? ;;
    backup) do_backup; exit $? ;;
    load-catalogs|catalogs) do_load_catalogs; exit $? ;;
    uninstall) do_uninstall; exit $? ;;
    clean|clean-temp) do_clean_temp; exit $? ;;
    *) main_menu ;;
  esac
}

main "$@"
