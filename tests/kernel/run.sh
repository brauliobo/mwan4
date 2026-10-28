#!/bin/sh
# Real-kernel checks of the seamless reload: needs nft, ip, python3, ucode and user + network + mount namespaces.
# Exit 0 with a "skipped" line when the host cannot run them.

here=$(cd "$(dirname "$0")" && pwd)

for tool in nft ip unshare python3 ucode; do
	command -v $tool > /dev/null || { echo "skipped: $tool not found"; exit 0; }
done
unshare -rnm true 2> /dev/null || { echo "skipped: no user namespaces"; exit 0; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
KERNEL_WORK=$work unshare -rnm sh "$here/scenario.sh"
