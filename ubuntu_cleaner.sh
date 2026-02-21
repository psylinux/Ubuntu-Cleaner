#!/usr/bin/env bash
set -euo pipefail

# Script de limpeza para Ubuntu.
# Requer privilégios de root (sudo).
#
# Uso:
#   chmod +x clean-ubuntu.sh
#   sudo ./clean-ubuntu.sh
#
# Ajustes por variáveis de ambiente:
#   sudo JOURNAL_DAYS=7 ./clean-ubuntu.sh   # Mantém 7 dias de logs do journal
#   sudo SNAP_RETAIN=3 ./clean-ubuntu.sh    # Mantém 3 revisões do Snap


JOURNAL_DAYS="${JOURNAL_DAYS:-14}"
SNAP_RETAIN="${SNAP_RETAIN:-2}"

log() { printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$(date +'%F %T')" "$*" >&2; exit 1; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Execute com sudo: sudo $0"
  fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

disk_report() {
  log "Uso de disco (/) agora:"
  df -h / || true
}

clean_apt() {
  if ! cmd_exists apt; then
    log "apt não encontrado. Pulando APT."
    return 0
  fi
  log "Limpando APT: autoremove --purge + clean"
  apt autoremove --purge -y
  apt clean
}

clean_journal() {
  if ! cmd_exists journalctl; then
    log "journalctl não encontrado. Pulando limpeza do journal."
    return 0
  fi
  log "Limpando logs do journal (systemd) mantendo ${JOURNAL_DAYS} dias"
  journalctl --vacuum-time="${JOURNAL_DAYS}d" || true
}

clean_snap_disabled_revisions() {
  if ! cmd_exists snap; then
    log "snap não encontrado. Pulando limpeza do Snap."
    return 0
  fi

  log "Removendo revisões Snap marcadas como disabled (se existirem)"
  # Lista pares no formato: <nome> <rev>
  mapfile -t disabled < <(snap list --all 2>/dev/null | awk '/disabled/{print $1" "$3}')
  if [[ "${#disabled[@]}" -eq 0 ]]; then
    log "Sem revisões disabled."
  else
    for item in "${disabled[@]}"; do
      name="$(awk '{print $1}' <<<"$item")"
      rev="$(awk '{print $2}' <<<"$item")"
      log "Removendo: $name (rev $rev)"
      snap remove "$name" --revision="$rev"
    done
  fi

  log "Configurando retenção de revisões Snap: refresh.retain=${SNAP_RETAIN}"
  snap set system "refresh.retain=${SNAP_RETAIN}" || true
}

clean_snapd_cache() {
  local cache_dir="/var/lib/snapd/cache"
  if [[ -d "$cache_dir" ]]; then
    log "Limpando cache do snapd (inclui arquivos ocultos): $cache_dir"
    # Remove todo o conteúdo sem apagar o diretório.
    find "$cache_dir" -mindepth 1 -xdev -exec rm -rf -- {} + || true
  else
    log "Diretório não existe: $cache_dir (ok)"
  fi
}

restart_snapd() {
  if cmd_exists systemctl && systemctl list-unit-files 2>/dev/null | grep -q '^snapd\.service'; then
    log "Reiniciando serviço snapd (systemd)"
    systemctl restart snapd || true
  fi
}

clean_root_caches() {
  log "Limpando caches do root: /root/.cache e /root/.npm"
  rm -rf /root/.cache /root/.npm
  mkdir -p /root/.cache /root/.npm
  chown -R root:root /root/.cache /root/.npm

  log "Limpando lixeira do root (se existir)"
  rm -rf /root/.local/share/Trash/* 2>/dev/null || true
}

clean_sudo_user_trash_and_thumbs() {
  # Usuário que executou o comando com sudo.
  local u="${SUDO_USER:-}"
  if [[ -z "$u" || "$u" == "root" ]]; then
    log "SUDO_USER vazio ou root. Pulando limpeza de thumbnails/lixeira do usuário."
    return 0
  fi

  local home_dir
  home_dir="$(getent passwd "$u" | cut -d: -f6 || true)"
  if [[ -z "$home_dir" || ! -d "$home_dir" ]]; then
    log "Home do usuário $u não encontrada. Pulando."
    return 0
  fi

  log "Limpando thumbnails do usuário $u: $home_dir/.cache/thumbnails"
  rm -rf "$home_dir/.cache/thumbnails/"* 2>/dev/null || true

  log "Limpando lixeira do usuário $u: $home_dir/.local/share/Trash"
  rm -rf "$home_dir/.local/share/Trash/"* 2>/dev/null || true

  # Reaplica ownership para evitar arquivos do usuário com dono root.
  chown -R "$u:$u" "$home_dir/.cache" "$home_dir/.local" 2>/dev/null || true
}

main() {
  need_root
  log "Iniciando limpeza"
  disk_report

  clean_apt
  clean_journal
  clean_snap_disabled_revisions
  clean_snapd_cache
  restart_snapd
  clean_root_caches
  clean_sudo_user_trash_and_thumbs

  log "Finalizado"
  disk_report
}

main "$@"
