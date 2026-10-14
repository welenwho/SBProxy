#!/usr/bin/env bash
# Export the exact SDK-packaged binary, not an independently rebuilt binary.
set -Eeuo pipefail
stage=arguments
trap 'echo "::error::Core export failed at $stage (line $LINENO): $BASH_COMMAND" >&2' ERR
fail() { echo "::error::$*" >&2; exit 1; }
sdk="$1"
apk_output="$2"
output="$3"
arch="$4"
version="$5"
revision="$6"
[[ "$arch" == arm64 || "$arch" == amd64 ]]
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$revision" =~ ^[1-9][0-9]*$ ]]
apk="$sdk/staging_dir/host/bin/apk"
package="$apk_output/sing-box-$version-r$revision.apk"
# The SDK package keeps OpenWrt's release number. Published names do not.
name="sing-box-$version-linux-$arch"
mkdir -p "$output/$name/release/config"
extract="$(mktemp -d)"
trap 'rm -rf -- "$extract"' EXIT
stage=extract-apk
"$apk" --allow-untrusted extract --destination "$extract" "$package"
binary="$extract/usr/bin/sing-box"
# A portable archive must not need a target libc or dynamic interpreter.
stage=static-link-check
readelf -l "$binary" > "$extract/elf.txt"
if grep -q INTERP "$extract/elf.txt"; then fail 'Core requires a dynamic ELF interpreter'; fi
readelf -d "$binary" > "$extract/dynamic.txt"
if grep -q NEEDED "$extract/dynamic.txt"; then fail 'Core requires shared libraries'; fi
run_core() {
    if [[ "$arch" == arm64 ]]; then qemu-aarch64-static "$binary" "$@"; else "$binary" "$@"; fi
}
stage=version-and-features
run_core version > "$extract/version.txt"
cat "$extract/version.txt"
grep -Fxq "sing-box version $version" "$extract/version.txt"
for tag in with_acme with_clash_api with_dhcp with_gvisor with_quic with_tailscale with_utls with_wireguard; do
    tr ',' ' ' < "$extract/version.txt" | grep -w "$tag" >/dev/null || fail "Missing core tag: $tag"
done
stage=tailscale-route-api
run_core api tailscale route list --help > "$extract/route.txt"
grep -Fq 'List Tailscale peer subnet routes' "$extract/route.txt"
stage=configuration-check
run_core check -c "$extract/etc/sing-box/config.json"
cp "$binary" "$output/$name/sing-box"
cp "$extract/etc/sing-box/config.json" "$output/$name/release/config/config.json"
# SDK CONFIG_AUTOREMOVE may already have deleted the source tree. Read the
# license from the verified source archive retained by core-release.py prepare.
stage=source-license
source_archive="${RUNNER_TEMP:?}/sbproxy-core-source.tar.gz"
source_hash="$(sed -n 's/^PKG_HASH:=//p' sing-box/Makefile)"
[[ "$source_hash" =~ ^[0-9a-f]{64}$ ]] || fail 'Invalid source archive hash'
printf '%s  %s\n' "$source_hash" "$source_archive" | sha256sum -c -
tar -xOf "$source_archive" "sing-box-$version/LICENSE" > "$output/$name/LICENSE"
test -s "$output/$name/LICENSE"
cp "$extract/version.txt" "$output/$name/BUILD_INFO"
stage=package-and-manifest
binary_sha="$(sha256sum "$binary" | cut -d' ' -f1)"
jq -n --arg version "$version" --arg arch "$arch" --arg sha "$binary_sha" \
    --arg source "$CORE_SOURCE_SHA" '{profile:"sbproxy",version:$version,arch:$arch,binary_sha256:$sha,source_sha:$source}' \
    > "$output/$name/SBP_BUILD_INFO"
tar -C "$output" -czf "$output/$name.tar.gz" "$name"
cp "$package" "$output/sing-box-$version-$arch.apk"
apk_arch="$("$apk" adbdump "$package" | awk '/^  arch: / { print $2; exit }')"
python3 .github/scripts/core-release.py export "$output" "$arch" "$version" \
    "$apk_arch" "$binary_sha" "$extract/version.txt" \
    "$(sed -n 's/^PKG_HASH:=//p' sing-box/Makefile)" \
    "$(sed -n 's/^TAILSCALE_MODULE_VERSION:=//p' sing-box/Makefile)"
