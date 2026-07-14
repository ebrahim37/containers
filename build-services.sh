#!/bin/sh
set -eu

[ "$#" -eq 1 ] || { echo "usage: $0 <host>" >&2; exit 2; }

script_path=$(realpath "$0")
repo_dir=$(dirname "$script_path")

host_name=$1
host_dir="$repo_dir/$host_name"
current_host=$(cat /etc/hostname)

[ "$host_name" = "$current_host" ] || { echo "refusing to deploy $host_name on $current_host" >&2; exit 1; }

[ -d "$host_dir" ] || { echo "host directory not found: $host_dir" >&2; exit 1; }
[ -f "$repo_dir/answers.yml" ] || { echo "missing shared answers: $repo_dir/answers.yml" >&2; exit 1; }
[ -f "$host_dir/answers.yml" ] || { echo "missing $host_name answers: $host_dir/answers.yml" >&2; exit 1; }

data_file=$(mktemp)
dest="$host_dir/services-dist"

sync_tree() {
	sync_src=$1
	sync_dest=$2

	install -d -m 0755 "$sync_dest"
	if [ -d "$sync_dest" ]; then
		find "$sync_dest" -depth -mindepth 1 -exec sh -eu -c '
			sync_src=$1
			sync_dest=$2
			shift 2
			for path do
				rel=${path#"$sync_dest"/}
				src_path=$sync_src/$rel
				if [ ! -e "$src_path" ] && [ ! -L "$src_path" ]; then
					rm -rf "$path"
					continue
				fi
				if [ -d "$path" ] && [ ! -d "$src_path" ]; then
					rm -rf "$path"
					continue
				fi
				if [ ! -d "$path" ] && [ -d "$src_path" ]; then
					rm -rf "$path"
				fi
			done
		' sh "$sync_src" "$sync_dest" {} +
	fi
	cp -a --no-preserve=context "$sync_src"/. "$sync_dest"/
}

sudo_sync_tree() {
	sync_src=$1
	sync_dest=$2

	sudo install -d -m 0755 "$sync_dest"
	if sudo test -d "$sync_dest"; then
		sudo find "$sync_dest" -depth -mindepth 1 -exec sh -eu -c '
			sync_src=$1
			sync_dest=$2
			shift 2
			for path do
				rel=${path#"$sync_dest"/}
				src_path=$sync_src/$rel
				if [ ! -e "$src_path" ] && [ ! -L "$src_path" ]; then
					rm -rf "$path"
					continue
				fi
				if [ -d "$path" ] && [ ! -d "$src_path" ]; then
					rm -rf "$path"
					continue
				fi
				if [ ! -d "$path" ] && [ -d "$src_path" ]; then
					rm -rf "$path"
				fi
			done
		' sh "$sync_src" "$sync_dest" {} +
	fi
	sudo cp -a --no-preserve=context "$sync_src"/. "$sync_dest"/
}

relabel_rootless_mounts() {
	quadlet_dir=$1

	find "$quadlet_dir" -name '*.container' -type f | while IFS= read -r unit; do
		container_name=$(
			awk -F= '$1 == "ContainerName" { print $2; exit }' "$unit"
		)
		[ -n "$container_name" ] || container_name=$(basename "$unit" .container)

		mount_label=$(podman inspect --format '{{ .MountLabel }}' "$container_name" 2>/dev/null || true)
		[ -n "$mount_label" ] || continue

		unit_dir=$(dirname "$unit")
		awk -F= '$1 == "Volume" { print substr($0, index($0, "=") + 1) }' "$unit" |
			while IFS= read -r volume; do
				source=${volume%%:*}
				case $source in
					./*) chcon -R "$mount_label" "$unit_dir/${source#./}" 2>/dev/null || true ;;
				esac
			done
	done
}

{
	cat "$repo_dir/answers.yml"
	printf '\n'
	cat "$host_dir/answers.yml"
} > "$data_file"

printf '%s\n' "_envops:" "  undefined: jinja2.StrictUndefined" |
	tee "$host_dir/services/copier.yml" "$repo_dir/shared/copier.yml" >/dev/null

rm -rf "$dest"
podman run --rm --interactive \
	--security-opt label=disable \
	--volume "$repo_dir:/work" \
	--volume "$data_file:/answers.yml:ro" \
	--workdir /work \
	docker.io/library/python:alpine \
	sh -eu -c '
		if [ ! -x .venv/bin/python ] || ! .venv/bin/python -c "import sys" >/dev/null 2>&1; then
			rm -rf .venv
			python -m venv .venv
		fi
		if ! .venv/bin/python -m pip show copier >/dev/null 2>&1; then
			.venv/bin/python -m pip install copier
		fi
		.venv/bin/copier copy --quiet --data-file /answers.yml "$1/services" "$1/services-dist"
		.venv/bin/copier copy --quiet --data-file /answers.yml shared "$1/services-dist/root/artix-cnc/shared"
	' sh "$host_name"
rm -f "$data_file" "$host_dir/services/copier.yml" "$repo_dir/shared/copier.yml"

root_quadlet_dir="/etc/containers/systemd/${host_name}-root"
sudo_sync_tree "$dest/root" "$root_quadlet_dir"
sudo chown -R root:root "$root_quadlet_dir"
sudo restorecon -RF "$root_quadlet_dir" 2>/dev/null || true

sync_tree "$dest/rootless" "$HOME/.config/containers/systemd/${host_name}-rootless"
relabel_rootless_mounts "$HOME/.config/containers/systemd/${host_name}-rootless"

install -d -m 0755 "$host_dir/volumes"
systemctl --user daemon-reload || true
sudo -n systemctl daemon-reload || true
