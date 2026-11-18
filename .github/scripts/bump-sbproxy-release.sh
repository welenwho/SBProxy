#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}"
PACKAGE_ROOT="$REPO_ROOT/luci-app-sbproxy"
MAKEFILE="$PACKAGE_ROOT/Makefile"
MENU="$PACKAGE_ROOT/root/usr/share/luci/menu.d/luci-app-sbproxy.json"
VIEW_DIR="$PACKAGE_ROOT/htdocs/luci-static/resources/view/sbproxy"
VIEWS=(client tailscale core status)

make_value() {
	sed -n "s/^$1:=//p" "$MAKEFILE" | head -n1
}

replace_once() {
	local file="$1"
	local old="$2"
	local new="$3"
	local count pattern

	count="$(awk -v needle="$old" '
		{
			line = $0
			while ((position = index(line, needle)) > 0) {
				count++
				line = substr(line, position + length(needle))
			}
		}
		END { print count + 0 }
	' "$file")"
	[[ "$count" -eq 1 ]] || {
		printf 'Expected exactly one %s reference in %s, found %s.\n' \
			"$old" "$file" "$count" >&2
		return 1
	}

	pattern="${old//./\\.}"
	sed -i.bak "s|$pattern|$new|" "$file"
	rm -f -- "$file.bak"
}

version="$(make_value PKG_VERSION)"
release="$(make_value PKG_RELEASE)"
mode="${1:-release}"
[[ -n "$version" ]] || {
	echo 'PKG_VERSION is missing from luci-app-sbproxy/Makefile.' >&2
	exit 1
}
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
	printf 'PKG_VERSION must be numeric semantic version: %s\n' "$version" >&2
	exit 1
}
[[ "$release" =~ ^[0-9]+$ ]] || {
	printf 'PKG_RELEASE must be numeric: %s\n' "$release" >&2
	exit 1
}

case "$mode" in
release)
	new_version="$version"
	new_release=$((10#$release + 1))
	;;
patch)
	new_version="$(printf '%s\n' "$version" | awk -F. '{ printf "%d.%d.%d\n", $1, $2, $3 + 1 }')"
	new_release=1
	;;
*)
	printf 'Usage: %s [release|patch]\n' "$0" >&2
	exit 1
	;;
esac
cache_version="$(printf '%s\n' "$version" | sed 's/[^A-Za-z0-9_-]/-/g')"
new_cache_version="$(printf '%s\n' "$new_version" | sed 's/[^A-Za-z0-9_-]/-/g')"
old_cache_key="${cache_version}-r${release}"
new_cache_key="${new_cache_version}-r${new_release}"
for view in "${VIEWS[@]}"; do
	old_view="$VIEW_DIR/$view-${old_cache_key}.js"
	new_view="$VIEW_DIR/$view-${new_cache_key}.js"
	[[ -L "$old_view" && "$(readlink "$old_view")" == "$view.js" ]] || {
		printf 'Invalid view cache symlink: %s\n' "$old_view" >&2
		exit 1
	}
	[[ ! -e "$new_view" && ! -L "$new_view" ]] || {
		printf 'Target view cache path already exists: %s\n' "$new_view" >&2
		exit 1
	}
done

for view in "${VIEWS[@]}"; do
	replace_once "$MENU" "sbproxy/$view-${old_cache_key}" "sbproxy/$view-${new_cache_key}"
	mv -- "$VIEW_DIR/$view-${old_cache_key}.js" "$VIEW_DIR/$view-${new_cache_key}.js"
	[[ "$(readlink "$VIEW_DIR/$view-${new_cache_key}.js")" == "$view.js" ]]
	grep -Fq "\"path\": \"sbproxy/$view-${new_cache_key}\"" "$MENU"
done

if [[ "$new_version" != "$version" ]]; then
	replace_once "$MAKEFILE" "PKG_VERSION:=$version" "PKG_VERSION:=$new_version"
fi
replace_once "$MAKEFILE" "PKG_RELEASE:=$release" "PKG_RELEASE:=$new_release"

[[ "$(make_value PKG_VERSION)" == "$new_version" ]]
[[ "$(make_value PKG_RELEASE)" == "$new_release" ]]

printf 'SBProxy package %s: %s-r%s -> %s-r%s (LuCI cache key: %s)\n' \
	"$mode" "$version" "$release" "$new_version" "$new_release" "$new_cache_key"
