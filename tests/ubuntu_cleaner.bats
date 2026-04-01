#!/usr/bin/env bats

setup() {
	cd "$BATS_TEST_DIRNAME/.."
}

@test "--help mostra as opcoes principais" {
	run ./ubuntu_cleaner.sh --help

	[ "$status" -eq 0 ]
	[[ "$output" == *"--apply"* ]]
	[[ "$output" == *"--apply-all"* ]]
	[[ "$output" == *"--dry-run"* ]]
	[[ "$output" == *"--analyze"* ]]
	[[ "$output" == *"--quiet"* ]]
	[[ "$output" == *"--install-deps"* ]]
	[[ "$output" == *"--include-vscode"* ]]
	[[ "$output" == *"--include-antigravity"* ]]
	[[ "$output" == *"--include-go"* ]]
	[[ "$output" == *"--include-tmp"* ]]
	[[ "$output" == *"--include-docker"* ]]
	[[ "$output" == *"--include-flatpak"* ]]
	[[ "$output" == *"--include-npm"* ]]
	[[ "$output" == *"--include-pip"* ]]
}

@test "dry-run e o comportamento padrao" {
	run ./ubuntu_cleaner.sh

	[ "$status" -eq 0 ]
	[[ "$output" == *"Filesystem usage (before cleanup):"* ]]
	[[ "$output" == *"Filesystem usage (after cleanup (dry-run, unchanged)):"* ]]
	[[ "$output" == *"Total liberado: 0B"* ]]
	[[ "$output" == *"Dry-run only. Nada foi removido."* ]]
}

@test "--dry-run e equivalente ao comportamento padrao" {
	run ./ubuntu_cleaner.sh --dry-run

	[ "$status" -eq 0 ]
	[[ "$output" == *"Dry-run only. Nada foi removido."* ]]
	[[ "$output" == *"Total liberado:"* ]]
}

@test "--quiet suprime tabela de filesystem mas mostra sumario" {
	run ./ubuntu_cleaner.sh --quiet

	[ "$status" -eq 0 ]
	[[ "$output" != *"Filesystem usage"* ]]
	[[ "$output" == *"Total liberado:"* ]]
	[[ "$output" == *"Dry-run only. Nada foi removido."* ]]
}

@test "opcao desconhecida falha" {
	run ./ubuntu_cleaner.sh --nao-existe

	[ "$status" -ne 0 ]
	[[ "$output" == *"Opcao desconhecida:"* ]]
}

@test "flags opcionais sao aceitas em dry-run" {
	run ./ubuntu_cleaner.sh --include-vscode --include-antigravity --include-go --analyze

	[ "$status" -eq 0 ]
	[[ "$output" == *"Targets de limpeza medidos:"* ]]
	[[ "$output" == *"Extensoes duplicadas:"* ]]
	[[ "$output" == *"Analise detalhada:"* ]]
}

@test "novas flags de limpeza sao aceitas em dry-run" {
	run ./ubuntu_cleaner.sh --include-tmp --include-docker --include-flatpak --include-npm --include-pip

	[ "$status" -eq 0 ]
	[[ "$output" == *"Dry-run only. Nada foi removido."* ]]
}

@test "--journal-days 0 falha com erro de validacao" {
	run ./ubuntu_cleaner.sh --journal-days 0

	[ "$status" -ne 0 ]
	[[ "$output" == *"deve ser >= 1"* ]]
}

@test "--snap-retain 0 falha com erro de validacao" {
	run ./ubuntu_cleaner.sh --snap-retain 0

	[ "$status" -ne 0 ]
	[[ "$output" == *"deve ser >= 1"* ]]
}

@test "--journal-days valor nao numerico falha" {
	run ./ubuntu_cleaner.sh --journal-days abc

	[ "$status" -ne 0 ]
	[[ "$output" == *"Valor invalido"* ]]
}

@test "--journal-days valor valido e aceito" {
	run ./ubuntu_cleaner.sh --journal-days 7

	[ "$status" -eq 0 ]
	[[ "$output" == *"Dry-run only. Nada foi removido."* ]]
}

@test "--snap-retain valor valido e aceito" {
	run ./ubuntu_cleaner.sh --snap-retain 3

	[ "$status" -eq 0 ]
	[[ "$output" == *"Dry-run only. Nada foi removido."* ]]
}
