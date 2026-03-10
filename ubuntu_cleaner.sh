#!/usr/bin/env bash
set -euo pipefail

JOURNAL_DAYS="${JOURNAL_DAYS:-14}"
SNAP_RETAIN="${SNAP_RETAIN:-2}"

APPLY=0
ANALYZE=0
INSTALL_DEPS=0
INCLUDE_VSCODE=0
INCLUDE_ANTIGRAVITY=0
INCLUDE_GO=0
INCLUDE_LOGS=0
PRUNE_DUPLICATE_EXTENSIONS=0

PRIMARY_USER=""
PRIMARY_HOME=""
GO_MOD_CACHE=""
GO_BUILD_CACHE=""

declare -a REPORT_LABELS=()
declare -a REPORT_PATHS=()
declare -a TOUCHED_MOUNTS=()
declare -a REQUIRED_APT_PACKAGES=()
declare -A BEFORE_FREE=()
declare -A AFTER_FREE=()

usage() {
	cat <<'EOF'
Ubuntu-Cleaner

Uso:
  ./ubuntu_cleaner.sh [opcoes]
  sudo ./ubuntu_cleaner.sh --apply [opcoes]

Padrao:
  O script roda em dry-run por padrao. Ele mostra analise, espaco ocupando disco
  e o que seria limpo. Para aplicar de verdade, use --apply.

Opcoes:
  --apply                         Executa a limpeza.
  --apply-all                     Instala dependencias e executa a limpeza completa.
  --analyze                       Mostra analise detalhada do filesystem.
  --install-deps                  Instala dependencias de runtime no Ubuntu local.
  --include-vscode               Inclui caches do VSCode no home do usuario.
  --include-antigravity          Inclui caches do Antigravity no home do usuario.
  --include-go                   Inclui caches do Go (go clean).
  --include-logs                 Inclui logs e crash data de editores.
  --prune-duplicate-extensions   Remove versoes antigas duplicadas de extensoes.
  --journal-days N               Mantem N dias de logs do journal.
  --snap-retain N                Mantem N revisoes de pacotes Snap.
  --help                         Mostra esta ajuda.

Variaveis de ambiente:
  JOURNAL_DAYS                   Mesmo que --journal-days.
  SNAP_RETAIN                    Mesmo que --snap-retain.

Exemplos:
  ./ubuntu_cleaner.sh
  ./ubuntu_cleaner.sh --analyze --include-vscode --include-antigravity
  sudo ./ubuntu_cleaner.sh --install-deps
  sudo ./ubuntu_cleaner.sh --apply-all
  sudo ./ubuntu_cleaner.sh --apply
  sudo ./ubuntu_cleaner.sh --apply --include-vscode --include-antigravity --prune-duplicate-extensions
  sudo ./ubuntu_cleaner.sh --apply --include-go --journal-days 7 --snap-retain 3
EOF
}

log() {
	printf '[%s] %s\n' "$(date +'%F %T')" "$*"
}

die() {
	printf '[%s] ERROR: %s\n' "$(date +'%F %T')" "$*" >&2
	exit 1
}

cmd_exists() {
	command -v "$1" >/dev/null 2>&1
}

human_bytes() {
	local bytes="${1:-0}"

	if cmd_exists numfmt; then
		numfmt --to=iec --suffix=B "$bytes"
	else
		awk -v bytes="$bytes" '
      function human(x) {
        split("B KiB MiB GiB TiB PiB", units, " ")
        i = 1
        while (x >= 1024 && i < 6) {
          x /= 1024
          i++
        }
        return sprintf("%.1f %s", x, units[i])
      }
      BEGIN { print human(bytes) }
    '
	fi
}

path_size_bytes() {
	local path="$1"
	local size=""

	if [[ ! -e "$path" ]]; then
		echo 0
		return
	fi

	size="$(du -sb -- "$path" 2>/dev/null | awk '{print $1}' || true)"
	echo "${size:-0}"
}

add_report_target() {
	local label="$1"
	local path="$2"

	if [[ -e "$path" ]]; then
		REPORT_LABELS+=("$label")
		REPORT_PATHS+=("$path")
	fi
}

ensure_numeric_flag_value() {
	local flag="$1"
	local value="$2"

	if [[ -z "$value" || ! "$value" =~ ^[0-9]+$ ]]; then
		die "Valor invalido para ${flag}: ${value:-<vazio>}"
	fi
}

add_required_apt_package() {
	local package="$1"
	local existing

	for existing in "${REQUIRED_APT_PACKAGES[@]}"; do
		if [[ "$existing" == "$package" ]]; then
			return
		fi
	done

	REQUIRED_APT_PACKAGES+=("$package")
}

require_command_package() {
	local command_name="$1"
	local apt_package="$2"

	if ! cmd_exists "$command_name"; then
		add_required_apt_package "$apt_package"
	fi
}

resolve_primary_user() {
	local candidate=""

	if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
		candidate="${SUDO_USER}"
	elif [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
		candidate="${USER:-$(id -un)}"
	elif cmd_exists logname; then
		candidate="$(logname 2>/dev/null || true)"
		if [[ "$candidate" == "root" ]]; then
			candidate=""
		fi
	fi

	if [[ -n "$candidate" ]]; then
		PRIMARY_USER="$candidate"
		PRIMARY_HOME="$(getent passwd "$candidate" | cut -d: -f6 || true)"
	fi

	if [[ -n "$PRIMARY_HOME" && ! -d "$PRIMARY_HOME" ]]; then
		PRIMARY_HOME=""
	fi
}

run_as_primary_user() {
	if [[ -z "$PRIMARY_USER" || -z "$PRIMARY_HOME" ]]; then
		return 1
	fi

	if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
		sudo -u "$PRIMARY_USER" -H env HOME="$PRIMARY_HOME" PATH="$PATH" "$@"
	else
		HOME="$PRIMARY_HOME" PATH="$PATH" "$@"
	fi
}

detect_go_caches() {
	local env_output

	GO_MOD_CACHE=""
	GO_BUILD_CACHE=""

	if ((!INCLUDE_GO)); then
		return
	fi

	if ! cmd_exists go; then
		return
	fi

	if [[ -n "$PRIMARY_USER" && -n "$PRIMARY_HOME" ]]; then
		env_output="$(run_as_primary_user go env GOMODCACHE GOCACHE 2>/dev/null || true)"
	else
		env_output="$(go env GOMODCACHE GOCACHE 2>/dev/null || true)"
	fi

	if [[ -n "$env_output" ]]; then
		GO_MOD_CACHE="$(sed -n '1p' <<<"$env_output")"
		GO_BUILD_CACHE="$(sed -n '2p' <<<"$env_output")"
	fi
}

need_root() {
	if ((APPLY || INSTALL_DEPS)) && [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
		die "Execute com sudo para instalar dependencias ou aplicar a limpeza: sudo $0 --install-deps [--apply]"
	fi
}

collect_runtime_dependencies() {
	REQUIRED_APT_PACKAGES=()

	require_command_package awk gawk
	require_command_package find findutils
	require_command_package xargs findutils
	require_command_package grep grep
	require_command_package sed sed
	require_command_package pgrep procps
	require_command_package timeout coreutils
	require_command_package df coreutils
	require_command_package du coreutils
	require_command_package sort coreutils
	require_command_package tail coreutils
	require_command_package head coreutils
	require_command_package numfmt coreutils

	if ((INSTALL_DEPS || ANALYZE || INCLUDE_VSCODE || INCLUDE_ANTIGRAVITY || PRUNE_DUPLICATE_EXTENSIONS)); then
		require_command_package python3 python3
	fi
}

install_runtime_dependencies() {
	local package

	collect_runtime_dependencies

	if ((${#REQUIRED_APT_PACKAGES[@]} == 0)); then
		if ((INSTALL_DEPS)); then
			log "Dependencias de runtime ja estao disponiveis."
		fi
		INSTALL_DEPS=0
		return
	fi

	if ! cmd_exists apt-get; then
		die "apt-get nao encontrado. Este projeto foi feito para rodar no Ubuntu local."
	fi

	if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
		die "Dependencias ausentes (${REQUIRED_APT_PACKAGES[*]}). Rode com sudo e --install-deps."
	fi

	log "Instalando dependencias de runtime: ${REQUIRED_APT_PACKAGES[*]}"
	export DEBIAN_FRONTEND=noninteractive
	apt-get update
	apt-get install -y "${REQUIRED_APT_PACKAGES[@]}"

	for package in "${REQUIRED_APT_PACKAGES[@]}"; do
		log "Dependencia garantida: ${package}"
	done

	INSTALL_DEPS=0
}

warn_about_running_editors() {
	local proc count
	local -a active=()

	for proc in code code-insiders antigravity; do
		count="$(pgrep -xc "$proc" || true)"
		if [[ -n "$count" && "$count" != "0" ]]; then
			active+=("$proc=$count")
		fi
	done

	if [[ ${#active[@]} -gt 0 ]]; then
		echo "Warning: editores em execucao detectados: ${active[*]}"
		echo "Feche VSCode e Antigravity antes de aplicar a limpeza para melhor resultado."
		echo
	fi
}

print_filesystem_summary() {
	local label="${1:-atual}"

	echo "Filesystem usage (${label}):"
	df -h -x tmpfs -x devtmpfs 2>/dev/null | sed 's/^/  /'
	echo
}

print_inode_summary() {
	echo "Filesystem inodes:"
	df -hi -x tmpfs -x devtmpfs 2>/dev/null | sed 's/^/  /'
	echo
}

print_dir_breakdown() {
	local label="$1"
	local path="$2"
	local output=""

	if [[ ! -d "$path" ]]; then
		return
	fi

	echo "${label}:"

	if cmd_exists timeout; then
		if output="$(timeout 15s du -xhd1 -- "$path" 2>/dev/null | sort -h | tail -n 15)"; then
			:
		else
			output=""
		fi
	else
		output="$(du -xhd1 -- "$path" 2>/dev/null | sort -h | tail -n 15 || true)"
	fi

	if [[ -n "$output" ]]; then
		printf '  %s\n' "${output//$'\n'/$'\n  '}"
	else
		echo "  indisponivel ou expirou o tempo limite da analise"
	fi
	echo
}

print_large_files() {
	local path="$1"

	if [[ ! -d "$path" ]]; then
		return
	fi

	echo "Arquivos grandes em ${path} (>200 MiB):"
	find "$path" -xdev -type f -size +200M -printf '%s\t%p\n' 2>/dev/null |
		sort -nr |
		head -n 20 |
		awk -F '\t' '{printf "  %.1f MiB\t%s\n", $1/1024/1024, $2}' || true
	echo
}

print_extended_analysis() {
	local mountpoint

	echo "Analise detalhada:"
	df -hT -x tmpfs -x devtmpfs 2>/dev/null | sed 's/^/  /'
	echo

	print_inode_summary
	print_dir_breakdown "Top-level de /" "/"
	print_dir_breakdown "Top-level de /var" "/var"

	if [[ -n "$PRIMARY_HOME" ]]; then
		print_dir_breakdown "Top-level de ${PRIMARY_HOME}" "$PRIMARY_HOME"
		print_large_files "$PRIMARY_HOME"
	fi

	while read -r mountpoint; do
		[[ -z "$mountpoint" ]] && continue
		print_dir_breakdown "Top-level de ${mountpoint}" "$mountpoint"
	done < <(df -P -x tmpfs -x devtmpfs 2>/dev/null | awk 'NR > 1 && $6 ~ "^/mnt/" {print $6}' | sort -u)
}

register_mount_for_path() {
	local path="$1"
	local probe="$path"
	local mountpoint=""
	local existing

	if [[ -z "$probe" ]]; then
		return
	fi

	if [[ ! -e "$probe" ]]; then
		probe="$(dirname "$probe")"
	fi

	while [[ "$probe" != "/" && ! -e "$probe" ]]; do
		probe="$(dirname "$probe")"
	done

	mountpoint="$(df --output=target "$probe" 2>/dev/null | tail -n 1 | xargs || true)"
	if [[ -z "$mountpoint" ]]; then
		return
	fi

	for existing in "${TOUCHED_MOUNTS[@]}"; do
		if [[ "$existing" == "$mountpoint" ]]; then
			return
		fi
	done

	TOUCHED_MOUNTS+=("$mountpoint")
}

snapshot_mounts() {
	local phase="$1"
	local mountpoint available

	for mountpoint in "${TOUCHED_MOUNTS[@]}"; do
		available="$(df --output=avail -B1 "$mountpoint" 2>/dev/null | tail -n 1 | tr -d '[:space:]')"
		available="${available:-0}"

		if [[ "$phase" == "before" ]]; then
			BEFORE_FREE["$mountpoint"]="$available"
		else
			AFTER_FREE["$mountpoint"]="$available"
		fi
	done
}

copy_before_to_after() {
	local mountpoint

	for mountpoint in "${TOUCHED_MOUNTS[@]}"; do
		AFTER_FREE["$mountpoint"]="${BEFORE_FREE[$mountpoint]:-0}"
	done
}

print_reclaim_summary() {
	local total=0
	local mountpoint before after delta

	echo "Espaco liberado por filesystem:"
	for mountpoint in "${TOUCHED_MOUNTS[@]}"; do
		before="${BEFORE_FREE[$mountpoint]:-0}"
		after="${AFTER_FREE[$mountpoint]:-0}"
		delta=$((after - before))

		if ((delta >= 0)); then
			total=$((total + delta))
			printf '  %-32s %8s\n' "$mountpoint" "$(human_bytes "$delta")"
		else
			printf '  %-32s -%7s\n' "$mountpoint" "$(human_bytes "$((-delta))")"
		fi
	done
	echo
	echo "Total liberado: $(human_bytes "$total")"
	echo
}

collect_report_targets() {
	REPORT_LABELS=()
	REPORT_PATHS=()

	add_report_target "APT cache" "/var/cache/apt"
	add_report_target "systemd journal" "/var/log/journal"
	add_report_target "snapd cache" "/var/lib/snapd/cache"
	add_report_target "root cache" "/root/.cache"
	add_report_target "root npm cache" "/root/.npm"
	add_report_target "root trash" "/root/.local/share/Trash"

	if [[ -n "$PRIMARY_HOME" ]]; then
		add_report_target "user thumbnails" "$PRIMARY_HOME/.cache/thumbnails"
		add_report_target "user trash" "$PRIMARY_HOME/.local/share/Trash"
	fi

	if ((INCLUDE_VSCODE)) && [[ -n "$PRIMARY_HOME" ]]; then
		add_report_target "VSCode CachedExtensionVSIXs" "$PRIMARY_HOME/.config/Code/CachedExtensionVSIXs"
		add_report_target "VSCode Cache" "$PRIMARY_HOME/.config/Code/Cache"
		add_report_target "VSCode CachedData" "$PRIMARY_HOME/.config/Code/CachedData"
		add_report_target "VSCode Code Cache" "$PRIMARY_HOME/.config/Code/Code Cache"
		add_report_target "VSCode GPUCache" "$PRIMARY_HOME/.config/Code/GPUCache"
		add_report_target "VSCode DawnGraphiteCache" "$PRIMARY_HOME/.config/Code/DawnGraphiteCache"
		add_report_target "VSCode DawnWebGPUCache" "$PRIMARY_HOME/.config/Code/DawnWebGPUCache"
		add_report_target "VSCode CachedProfilesData" "$PRIMARY_HOME/.config/Code/CachedProfilesData"
		add_report_target "VSCode Service Worker cache" "$PRIMARY_HOME/.config/Code/Service Worker/CacheStorage"

		if ((INCLUDE_LOGS)); then
			add_report_target "VSCode logs" "$PRIMARY_HOME/.config/Code/logs"
			add_report_target "VSCode Crashpad" "$PRIMARY_HOME/.config/Code/Crashpad"
		fi
	fi

	if ((INCLUDE_ANTIGRAVITY)) && [[ -n "$PRIMARY_HOME" ]]; then
		add_report_target "Antigravity Cache" "$PRIMARY_HOME/.config/Antigravity/Cache"
		add_report_target "Antigravity CachedData" "$PRIMARY_HOME/.config/Antigravity/CachedData"
		add_report_target "Antigravity CachedExtensionVSIXs" "$PRIMARY_HOME/.config/Antigravity/CachedExtensionVSIXs"
		add_report_target "Antigravity Code Cache" "$PRIMARY_HOME/.config/Antigravity/Code Cache"
		add_report_target "Antigravity GPUCache" "$PRIMARY_HOME/.config/Antigravity/GPUCache"
		add_report_target "Antigravity DawnGraphiteCache" "$PRIMARY_HOME/.config/Antigravity/DawnGraphiteCache"
		add_report_target "Antigravity DawnWebGPUCache" "$PRIMARY_HOME/.config/Antigravity/DawnWebGPUCache"
		add_report_target "Antigravity CachedProfilesData" "$PRIMARY_HOME/.config/Antigravity/CachedProfilesData"
		add_report_target "Antigravity Service Worker cache" "$PRIMARY_HOME/.config/Antigravity/Service Worker/CacheStorage"
		add_report_target "Antigravity server CachedExtensionVSIXs" "$PRIMARY_HOME/.antigravity-server/data/CachedExtensionVSIXs"
		add_report_target "Antigravity server CachedProfilesData" "$PRIMARY_HOME/.antigravity-server/data/CachedProfilesData"
		add_report_target "Antigravity clangd install" "$PRIMARY_HOME/.config/Antigravity/User/globalStorage/llvm-vs-code-extensions.vscode-clangd/install"

		if ((INCLUDE_LOGS)); then
			add_report_target "Antigravity logs" "$PRIMARY_HOME/.config/Antigravity/logs"
			add_report_target "Antigravity Crashpad" "$PRIMARY_HOME/.config/Antigravity/Crashpad"
			add_report_target "Antigravity server logs" "$PRIMARY_HOME/.antigravity-server/data/logs"
		fi
	fi

	if ((INCLUDE_GO)); then
		if [[ -n "$GO_MOD_CACHE" ]]; then
			add_report_target "Go module cache" "$GO_MOD_CACHE"
		fi
		if [[ -n "$GO_BUILD_CACHE" ]]; then
			add_report_target "Go build cache" "$GO_BUILD_CACHE"
		fi
	fi
}

register_touched_mounts() {
	local i

	TOUCHED_MOUNTS=()
	register_mount_for_path "/"
	register_mount_for_path "/var/cache/apt"
	register_mount_for_path "/var/log/journal"
	register_mount_for_path "/var/lib/snapd/cache"
	register_mount_for_path "/root/.cache"
	register_mount_for_path "/root/.local/share/Trash"

	if [[ -n "$PRIMARY_HOME" ]]; then
		register_mount_for_path "$PRIMARY_HOME"
		register_mount_for_path "$PRIMARY_HOME/.cache/thumbnails"
		register_mount_for_path "$PRIMARY_HOME/.local/share/Trash"
	fi

	for i in "${!REPORT_PATHS[@]}"; do
		register_mount_for_path "${REPORT_PATHS[$i]}"
	done
}

report_candidates() {
	local total_bytes=0
	local i bytes autoremove_count disabled_snaps

	echo "Targets de limpeza medidos:"
	if [[ ${#REPORT_PATHS[@]} -eq 0 ]]; then
		echo "  Nenhum target encontrado."
	else
		for i in "${!REPORT_PATHS[@]}"; do
			bytes="$(path_size_bytes "${REPORT_PATHS[$i]}")"
			total_bytes=$((total_bytes + bytes))
			printf '  %-36s %8s  %s\n' "${REPORT_LABELS[$i]}" "$(human_bytes "$bytes")" "${REPORT_PATHS[$i]}"
		done
	fi
	echo

	if cmd_exists apt-get; then
		autoremove_count="$(apt-get -s autoremove 2>/dev/null | awk '/^Remv /{count++} END{print count+0}')"
		echo "Pacotes candidatos em apt autoremove: ${autoremove_count}"
	fi

	if cmd_exists snap; then
		disabled_snaps="$(snap list --all 2>/dev/null | awk '/disabled/{count++} END{print count+0}')"
		echo "Revisoes Snap disabled: ${disabled_snaps}"
	fi

	echo "Reclaim aproximado por diretorios medidos: $(human_bytes "$total_bytes")"
	echo
}

report_duplicate_extensions() {
	if [[ -z "$PRIMARY_HOME" ]]; then
		return
	fi

	if ((!ANALYZE && !INCLUDE_VSCODE && !INCLUDE_ANTIGRAVITY)); then
		return
	fi

	if ! cmd_exists python3; then
		echo "python3 nao encontrado. Pulando analise de extensoes duplicadas."
		echo
		return
	fi

	python3 - "$PRIMARY_HOME" "$APPLY" "$PRUNE_DUPLICATE_EXTENSIONS" "$INCLUDE_VSCODE" "$INCLUDE_ANTIGRAVITY" "$ANALYZE" <<'PY'
import re
import shutil
import sys
from pathlib import Path

home = Path(sys.argv[1])
apply = sys.argv[2] == "1"
prune = sys.argv[3] == "1"
include_vscode = sys.argv[4] == "1"
include_antigravity = sys.argv[5] == "1"
analyze = sys.argv[6] == "1"

bases = []
if include_vscode or analyze:
    bases.append(home / ".vscode" / "extensions")
if include_antigravity or analyze:
    bases.extend(
        [
            home / ".antigravity" / "extensions",
            home / ".antigravity-server" / "extensions",
        ]
    )

pattern = re.compile(r"^(?P<key>.+?)-(?P<version>\d.+)$")

def natural_key(value: str):
    parts = re.split(r"(\d+)", value)
    key = []
    for part in parts:
        if part.isdigit():
            key.append((0, int(part)))
        else:
            key.append((1, part))
    return key

def size_bytes(path: Path) -> int:
    total = 0
    for item in path.rglob("*"):
        try:
            if item.is_file():
                total += item.stat().st_size
        except FileNotFoundError:
            pass
    return total

total = 0
any_duplicates = False

print("Extensoes duplicadas:")

for base in bases:
    if not base.exists():
        continue

    groups = {}
    for child in sorted(base.iterdir()):
        if not child.is_dir():
            continue
        match = pattern.match(child.name)
        if not match:
            continue
        groups.setdefault(match.group("key"), []).append(child)

    base_printed = False
    for key, paths in sorted(groups.items()):
        if len(paths) < 2:
            continue

        any_duplicates = True
        if not base_printed:
            print(f"  {base}")
            base_printed = True

        paths = sorted(paths, key=lambda item: natural_key(pattern.match(item.name).group("version")))
        keep = paths[-1]
        remove = paths[:-1]
        print(f"    {key}")
        print(f"      keep:   {keep.name}")
        for candidate in remove:
            size = size_bytes(candidate)
            total += size
            print(f"      remove: {candidate.name} ({size / 1024 / 1024:.1f} MiB)")
            if apply and prune:
                shutil.rmtree(candidate, ignore_errors=True)

if not any_duplicates:
    print("  none found")

print(f"\nReclaim aproximado em extensoes duplicadas: {total / 1024 / 1024:.1f} MiB")

if any_duplicates and prune and not apply:
    print("Dry-run only: rerun with --apply --prune-duplicate-extensions to remove older duplicates.")
PY
	echo
}

clear_directory() {
	local path="$1"

	if [[ -d "$path" ]]; then
		find "$path" -mindepth 1 -xdev -exec rm -rf -- {} + 2>/dev/null || true
	fi
}

remove_path() {
	local path="$1"

	if [[ -e "$path" ]]; then
		rm -rf -- "$path"
	fi
}

reset_owned_directory() {
	local path="$1"
	local owner="$2"
	local group="$3"

	rm -rf -- "$path"
	install -d -o "$owner" -g "$group" "$path"
}

clean_apt() {
	if ! cmd_exists apt; then
		log "apt nao encontrado. Pulando APT."
		return
	fi

	log "Limpando APT: autoremove --purge + clean"
	apt autoremove --purge -y
	apt clean
}

clean_journal() {
	if ! cmd_exists journalctl; then
		log "journalctl nao encontrado. Pulando journal."
		return
	fi

	log "Limpando logs do journal mantendo ${JOURNAL_DAYS} dias"
	journalctl --vacuum-time="${JOURNAL_DAYS}d" || true
}

clean_snap_disabled_revisions() {
	local item name rev
	local -a disabled=()

	if ! cmd_exists snap; then
		log "snap nao encontrado. Pulando limpeza do Snap."
		return
	fi

	log "Removendo revisoes Snap marcadas como disabled"
	mapfile -t disabled < <(snap list --all 2>/dev/null | awk '/disabled/{print $1" "$3}')

	if [[ ${#disabled[@]} -eq 0 ]]; then
		log "Sem revisoes disabled."
	else
		for item in "${disabled[@]}"; do
			name="$(awk '{print $1}' <<<"$item")"
			rev="$(awk '{print $2}' <<<"$item")"
			log "Removendo: ${name} (rev ${rev})"
			snap remove "$name" --revision="$rev"
		done
	fi

	log "Configurando retencao de revisoes Snap: refresh.retain=${SNAP_RETAIN}"
	snap set system "refresh.retain=${SNAP_RETAIN}" || true
}

clean_snapd_cache() {
	local cache_dir="/var/lib/snapd/cache"

	if [[ ! -d "$cache_dir" ]]; then
		log "Diretorio nao existe: ${cache_dir} (ok)"
		return
	fi

	log "Limpando cache do snapd: ${cache_dir}"
	clear_directory "$cache_dir"
}

restart_snapd() {
	if cmd_exists systemctl && systemctl list-unit-files 2>/dev/null | grep -q '^snapd\.service'; then
		log "Reiniciando servico snapd"
		systemctl restart snapd || true
	fi
}

clean_root_caches() {
	log "Limpando caches do root"
	reset_owned_directory "/root/.cache" "root" "root"
	reset_owned_directory "/root/.npm" "root" "root"
	clear_directory "/root/.local/share/Trash"
}

clean_primary_user_trash_and_thumbs() {
	local thumbs_dir trash_dir

	if [[ -z "$PRIMARY_USER" || -z "$PRIMARY_HOME" ]]; then
		log "Sem usuario principal detectado. Pulando thumbs/lixeira do usuario."
		return
	fi

	thumbs_dir="${PRIMARY_HOME}/.cache/thumbnails"
	trash_dir="${PRIMARY_HOME}/.local/share/Trash"

	log "Limpando thumbnails do usuario ${PRIMARY_USER}: ${thumbs_dir}"
	clear_directory "$thumbs_dir"
	if [[ -d "$thumbs_dir" ]]; then
		chown "$PRIMARY_USER:$PRIMARY_USER" "$thumbs_dir" 2>/dev/null || true
	fi

	log "Limpando lixeira do usuario ${PRIMARY_USER}: ${trash_dir}"
	clear_directory "$trash_dir"
	if [[ -d "$trash_dir" ]]; then
		chown "$PRIMARY_USER:$PRIMARY_USER" "$trash_dir" 2>/dev/null || true
	fi
}

clean_vscode_caches() {
	local base="${PRIMARY_HOME}/.config/Code"

	if ((!INCLUDE_VSCODE)) || [[ -z "$PRIMARY_HOME" || ! -d "$base" ]]; then
		return
	fi

	log "Limpando caches do VSCode"
	remove_path "${base}/CachedExtensionVSIXs"
	remove_path "${base}/Cache"
	remove_path "${base}/CachedData"
	remove_path "${base}/Code Cache"
	remove_path "${base}/GPUCache"
	remove_path "${base}/DawnGraphiteCache"
	remove_path "${base}/DawnWebGPUCache"
	remove_path "${base}/CachedProfilesData"
	remove_path "${base}/Service Worker/CacheStorage"

	if ((INCLUDE_LOGS)); then
		remove_path "${base}/logs"
		remove_path "${base}/Crashpad"
	fi
}

clean_antigravity_caches() {
	local config_base="${PRIMARY_HOME}/.config/Antigravity"
	local server_base="${PRIMARY_HOME}/.antigravity-server/data"

	if ((!INCLUDE_ANTIGRAVITY)) || [[ -z "$PRIMARY_HOME" ]]; then
		return
	fi

	log "Limpando caches do Antigravity"
	remove_path "${config_base}/Cache"
	remove_path "${config_base}/CachedData"
	remove_path "${config_base}/CachedExtensionVSIXs"
	remove_path "${config_base}/Code Cache"
	remove_path "${config_base}/GPUCache"
	remove_path "${config_base}/DawnGraphiteCache"
	remove_path "${config_base}/DawnWebGPUCache"
	remove_path "${config_base}/CachedProfilesData"
	remove_path "${config_base}/Service Worker/CacheStorage"
	remove_path "${server_base}/CachedExtensionVSIXs"
	remove_path "${server_base}/CachedProfilesData"
	remove_path "${config_base}/User/globalStorage/llvm-vs-code-extensions.vscode-clangd/install"

	if ((INCLUDE_LOGS)); then
		remove_path "${config_base}/logs"
		remove_path "${config_base}/Crashpad"
		remove_path "${server_base}/logs"
	fi
}

clean_go_caches() {
	if ((!INCLUDE_GO)); then
		return
	fi

	if ! cmd_exists go; then
		log "go nao encontrado. Pulando caches do Go."
		return
	fi

	log "Limpando caches do Go"
	if [[ -n "$PRIMARY_USER" && -n "$PRIMARY_HOME" ]]; then
		run_as_primary_user go clean -cache -modcache -testcache -fuzzcache || true
	else
		go clean -cache -modcache -testcache -fuzzcache || true
	fi
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--apply)
			APPLY=1
			;;
		--apply-all)
			APPLY=1
			INSTALL_DEPS=1
			INCLUDE_VSCODE=1
			INCLUDE_ANTIGRAVITY=1
			INCLUDE_GO=1
			INCLUDE_LOGS=1
			PRUNE_DUPLICATE_EXTENSIONS=1
			;;
		--analyze)
			ANALYZE=1
			;;
		--install-deps)
			INSTALL_DEPS=1
			;;
		--include-vscode)
			INCLUDE_VSCODE=1
			;;
		--include-antigravity)
			INCLUDE_ANTIGRAVITY=1
			;;
		--include-go)
			INCLUDE_GO=1
			;;
		--include-logs)
			INCLUDE_LOGS=1
			;;
		--prune-duplicate-extensions)
			PRUNE_DUPLICATE_EXTENSIONS=1
			;;
		--journal-days)
			shift
			ensure_numeric_flag_value "--journal-days" "${1:-}"
			JOURNAL_DAYS="$1"
			;;
		--snap-retain)
			shift
			ensure_numeric_flag_value "--snap-retain" "${1:-}"
			SNAP_RETAIN="$1"
			;;
		--help | -h)
			usage
			exit 0
			;;
		*)
			die "Opcao desconhecida: $1"
			;;
		esac
		shift
	done
}

main() {
	parse_args "$@"
	resolve_primary_user
	detect_go_caches
	install_runtime_dependencies
	collect_report_targets
	register_touched_mounts
	need_root
	snapshot_mounts "before"

	print_filesystem_summary "before cleanup"
	warn_about_running_editors
	report_candidates
	if ((!APPLY || !PRUNE_DUPLICATE_EXTENSIONS)); then
		report_duplicate_extensions
	fi

	if ((ANALYZE)); then
		print_extended_analysis
	fi

	if ((!APPLY)); then
		copy_before_to_after
		print_filesystem_summary "after cleanup (dry-run, unchanged)"
		print_reclaim_summary
		echo "Dry-run only. Nada foi removido."
		echo "Use --apply para executar a limpeza."
		exit 0
	fi

	log "Iniciando limpeza"
	clean_apt
	clean_journal
	clean_snap_disabled_revisions
	clean_snapd_cache
	restart_snapd
	clean_root_caches
	clean_primary_user_trash_and_thumbs
	clean_vscode_caches
	clean_antigravity_caches
	clean_go_caches

	if ((PRUNE_DUPLICATE_EXTENSIONS)); then
		report_duplicate_extensions
	fi

	sync
	snapshot_mounts "after"

	echo
	print_filesystem_summary "after cleanup"
	print_reclaim_summary
	log "Finalizado"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
