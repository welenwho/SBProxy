#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}"
PACKAGE_ROOT="$REPO_ROOT/luci-app-sbproxy"
MAKEFILE="$PACKAGE_ROOT/Makefile"
MENU="$PACKAGE_ROOT/root/usr/share/luci/menu.d/luci-app-sbproxy.json"
CLIENT="$PACKAGE_ROOT/htdocs/luci-static/resources/view/sbproxy/client.js"
TAILSCALE="$PACKAGE_ROOT/htdocs/luci-static/resources/view/sbproxy/tailscale.js"
CORE="$PACKAGE_ROOT/htdocs/luci-static/resources/view/sbproxy/core.js"

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
old_client="$PACKAGE_ROOT/htdocs/luci-static/resources/view/sbproxy/client-${old_cache_key}.js"
new_client="$PACKAGE_ROOT/htdocs/luci-static/resources/view/sbproxy/client-${new_cache_key}.js"
old_tailscale="$PACKAGE_ROOT/htdocs/luci-static/resources/view/sbproxy/tailscale-${old_cache_key}.js"
new_tailscale="$PACKAGE_ROOT/htdocs/luci-static/resources/view/sbproxy/tailscale-${new_cache_key}.js"
old_core="$PACKAGE_ROOT/htdocs/luci-static/resources/view/sbproxy/core-${old_cache_key}.js"
new_core="$PACKAGE_ROOT/htdocs/luci-static/resources/view/sbproxy/core-${new_cache_key}.js"

[[ -L "$old_client" && "$(readlink "$old_client")" == 'client.js' ]] || {
	printf 'Invalid client cache symlink: %s\n' "$old_client" >&2
	exit 1
}
[[ -L "$old_tailscale" && "$(readlink "$old_tailscale")" == 'tailscale.js' ]] || {
	printf 'Invalid Tailscale cache symlink: %s\n' "$old_tailscale" >&2
	exit 1
}
[[ -L "$old_core" && "$(readlink "$old_core")" == 'core.js' ]] || {
	printf 'Invalid core management cache symlink: %s\n' "$old_core" >&2
	exit 1
}
[[ ! -e "$new_client" && ! -L "$new_client" ]] || {
	printf 'Target client cache path already exists: %s\n' "$new_client" >&2
	exit 1
}
[[ ! -e "$new_tailscale" && ! -L "$new_tailscale" ]] || {
	printf 'Target Tailscale cache path already exists: %s\n' "$new_tailscale" >&2
	exit 1
}
[[ ! -e "$new_core" && ! -L "$new_core" ]] || {
	printf 'Target core management cache path already exists: %s\n' "$new_core" >&2
	exit 1
}

replace_once "$MENU" "sbproxy/client-${old_cache_key}" "sbproxy/client-${new_cache_key}"
replace_once "$MENU" "sbproxy/tailscale-${old_cache_key}" "sbproxy/tailscale-${new_cache_key}"
replace_once "$MENU" "sbproxy/core-${old_cache_key}" "sbproxy/core-${new_cache_key}"
if [[ "$new_version" != "$version" ]]; then
	replace_once "$MAKEFILE" "PKG_VERSION:=$version" "PKG_VERSION:=$new_version"
fi
replace_once "$MAKEFILE" "PKG_RELEASE:=$release" "PKG_RELEASE:=$new_release"
mv -- "$old_client" "$new_client"
mv -- "$old_tailscale" "$new_tailscale"
mv -- "$old_core" "$new_core"

[[ "$(make_value PKG_VERSION)" == "$new_version" ]]
[[ "$(make_value PKG_RELEASE)" == "$new_release" ]]
[[ "$(readlink "$new_client")" == 'client.js' ]]
[[ "$(readlink "$new_tailscale")" == 'tailscale.js' ]]
[[ "$(readlink "$new_core")" == 'core.js' ]]
grep -Fq "\"path\": \"sbproxy/client-${new_cache_key}\"" "$MENU"
grep -Fq "\"path\": \"sbproxy/tailscale-${new_cache_key}\"" "$MENU"
grep -Fq "\"path\": \"sbproxy/core-${new_cache_key}\"" "$MENU"

printf 'SBProxy package %s: %s-r%s -> %s-r%s (LuCI cache key: %s)\n' \
	"$mode" "$version" "$release" "$new_version" "$new_release" "$new_cache_key"
