#!/usr/bin/env bats

setup() {
	cd "$BATS_TEST_DIRNAME/.."
}

@test "--help mostra as opcoes principais" {
	run ./ubuntu_cleaner.sh --help

	[ "$status" -eq 0 ]
	[[ "$output" == *"--apply"* ]]
	[[ "$output" == *"--apply-all"* ]]
	[[ "$output" == *"--analyze"* ]]
	[[ "$output" == *"--install-deps"* ]]
	[[ "$output" == *"--include-vscode"* ]]
	[[ "$output" == *"--include-antigravity"* ]]
	[[ "$output" == *"--include-go"* ]]
}

@test "dry-run e o comportamento padrao" {
	run ./ubuntu_cleaner.sh

	[ "$status" -eq 0 ]
	[[ "$output" == *"Filesystem usage (before cleanup):"* ]]
	[[ "$output" == *"Filesystem usage (after cleanup (dry-run, unchanged)):"* ]]
	[[ "$output" == *"Total liberado: 0B"* ]]
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
