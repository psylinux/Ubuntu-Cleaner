#!/usr/bin/env python3
"""Remove older duplicate VSCode/Antigravity extension versions."""

import re
import shutil
import sys
from pathlib import Path


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


def main():
	if len(sys.argv) < 7:
		print(
			"Uso: prune_extensions.py <home> <apply> <prune>"
			" <include_vscode> <include_antigravity> <analyze>"
		)
		sys.exit(1)

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

	total = 0
	any_duplicates = False

	print("Extensoes duplicadas:")

	for base in bases:
		if not base.exists():
			continue

		groups: dict[str, list[Path]] = {}
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

			paths = sorted(
				paths,
				key=lambda item: natural_key(
					pattern.match(item.name).group("version")  # type: ignore[union-attr]
				),
			)
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
		print(
			"Dry-run only: rerun with --apply --prune-duplicate-extensions"
			" to remove older duplicates."
		)


if __name__ == "__main__":
	main()
