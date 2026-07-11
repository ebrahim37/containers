#!/bin/sh
set -eu

script_path=$(realpath "$0")
repo_dir=$(dirname "$script_path")
host_name=$(basename "$repo_dir")

dest="$repo_dir/services-dist"
copier_config="$repo_dir/services/copier.yml"

root_dist="$dest/root"
rootless_dist="$dest/rootless"

root_quadlet_dir="/etc/containers/systemd/${host_name}-root"
rootless_quadlet_dir="$HOME/.config/containers/systemd/${host_name}-rootless"

{
	echo "_preserve_symlinks: true"
	echo "_envops:"
	echo "  undefined: jinja2.StrictUndefined"
} > "$copier_config"

podman run --rm --interactive --log-driver=none \
	--security-opt label=disable \
	--volume "$repo_dir:/src:ro" \
	--volume "$repo_dir/services:/services" \
	--workdir /src \
	docker.io/library/python:3.13-alpine \
	sh -eu -c '
		python -m pip install --quiet --root-user-action=ignore copier
		copier copy --quiet --data-file answers.yml services /services/.render
	'

rm -rf "$dest" "$copier_config"
mv "$repo_dir/services/.render" "$dest"

if [ -d "$root_dist" ]; then
	sudo rm -rf "$root_quadlet_dir"
	sudo install -d -m 0755 "$root_quadlet_dir"
	sudo cp -a "$root_dist"/. "$root_quadlet_dir"/
	sudo chown -R root:root "$root_quadlet_dir"
	sudo restorecon -RF "$root_quadlet_dir" 2>/dev/null || true
fi

if [ -d "$rootless_dist" ]; then
	rm -rf "$rootless_quadlet_dir"
	install -d -m 0755 "$rootless_quadlet_dir"
	cp -a "$rootless_dist"/. "$rootless_quadlet_dir"/
	restorecon -RF "$HOME/.config/containers" 2>/dev/null || true
fi

if command -v systemctl >/dev/null 2>&1; then
	install -d -m 0755 "$repo_dir/volumes"
	systemctl --user daemon-reload || true
	sudo -n systemctl daemon-reload || true
fi
