#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}"
RESOURCES_DIR="$REPO_ROOT/luci-app-sbproxy/root/etc/sbproxy/resources"
DASHBOARD_DIR="$REPO_ROOT/luci-app-sbproxy/root/etc/sbproxy/dashboard"

GEOIP_SOURCE="${GEOIP_SOURCE:-https://cdn.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-cn.srs}"
GEOIP_VERSION_URL="${GEOIP_VERSION_URL:-https://github.com/SagerNet/sing-geoip/releases/latest}"
GEOSITE_SOURCE="${GEOSITE_SOURCE:-https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set-unstable/geosite-cn.srs}"
GEOSITE_VERSION_URL="${GEOSITE_VERSION_URL:-https://github.com/SagerNet/sing-geosite/releases/latest}"
DASHBOARD_SOURCE="${DASHBOARD_SOURCE:-https://codeload.github.com/SagerNet/sing-box-dashboard/zip/refs/heads/gh-pages}"
DASHBOARD_VERSION_URL="${DASHBOARD_VERSION_URL:-https://github.com/SagerNet/sing-box-dashboard/commits/gh-pages.atom}"
USER_AGENT="${USER_AGENT:-SBProxy resource preset}"
SING_BOX="${SING_BOX:-}"

TEMP_DIR="$(mktemp -d)" || {
	echo "Failed to prepare temporary resource directory." >&2
	exit 1
}
DASHBOARD_STAGE="${DASHBOARD_DIR}.new.$$"
trap 'rm -rf -- "$TEMP_DIR" "$DASHBOARD_STAGE"' EXIT INT TERM

warn() {
	echo "WARNING: $*" >&2
	if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
		echo "::warning::$*"
	fi
}

set_output() {
	local name="$1"
	local value="$2"
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
	fi
}

fetch_release_version() {
	local effective_url version
	effective_url="$(curl -fsSL --compressed --retry 3 --retry-all-errors \
		--retry-delay 1 --connect-timeout 10 --max-time 30 \
		-A "$USER_AGENT" -o /dev/null -w '%{url_effective}' "$1")" || return 1
	version="${effective_url##*/}"
	case "$version" in
		''|*[!0-9]*) return 1 ;;
	esac
	printf '%s\n' "$version"
}

fetch_dashboard_version() {
	local feed version
	feed="$(curl -fsSL --compressed --retry 3 --retry-all-errors \
		--retry-delay 1 --connect-timeout 10 --max-time 30 \
		-A "$USER_AGENT" "$DASHBOARD_VERSION_URL")" || return 1
	version="$(awk -F '[<>]' '
		/<updated>/ {
			version = $3
			gsub(/[-:TZ]/, "", version)
			print version
			exit
		}
	' <<<"$feed")"
	case "$version" in
		??????????????) case "$version" in *[!0-9]*) return 1 ;; esac ;;
		*) return 1 ;;
	esac
	printf '%s\n' "$version"
}

download() {
	curl -fsSL --compressed --retry 3 --retry-all-errors --retry-delay 1 \
		--connect-timeout 10 --max-time 60 -A "$USER_AGENT" -o "$2" "$1" &&
		test -s "$2"
}

normalize_dashboard_javascript() {
	local dashboard_root="$1"
	local file

	while IFS= read -r -d '' file; do
		# Preserve the JSON editor's two-space indent without trailing whitespace.
		# shellcheck disable=SC2016
		sed -i -E 's/^(`\+[^`]+\+`)  $/\1\\x20\\x20/' "$file" || return 1
		if grep -nE '[[:blank:]]+$' "$file" >&2; then
			echo "Unsupported trailing whitespace remains in dashboard JavaScript: $file" >&2
			return 1
		fi
	done < <(find "$dashboard_root" -type f -name '*.js' -print0)
}

decompile_rule_set() {
	local rule_set="$1"
	local json="$2"

	[[ -s "$rule_set" ]] || return 1
	[[ "$(head -c 3 "$rule_set")" == SRS ]] || return 1
	[[ -n "$SING_BOX" && -x "$SING_BOX" ]] || return 1
	"$SING_BOX" rule-set decompile "$rule_set" -o "$json" >/dev/null
}

rule_set_fingerprint() {
	python3 "$SCRIPT_DIR/rule-set-identity.py" "$1"
}

# Replace a rule-set only when the decoded match set changes. A new upstream
# release tag, or a rebuild that only reorders regexes, must not dirty git.
install_rule_set_if_changed() {
	local resource="$1"
	local version="$2"
	local candidate="$TEMP_DIR/${resource}.srs"
	local candidate_json="$TEMP_DIR/${resource}.candidate.json"
	local current="$RESOURCES_DIR/${resource}.srs"
	local current_json="$TEMP_DIR/${resource}.current.json"
	local current_ver="$RESOURCES_DIR/${resource}.ver"
	local candidate_fp current_fp current_version

	decompile_rule_set "$candidate" "$candidate_json" || return 1
	candidate_fp="$(rule_set_fingerprint "$candidate_json")" || return 1
	if [[ -s "$current" && -s "$current_ver" ]] &&
		decompile_rule_set "$current" "$current_json"; then
		current_fp="$(rule_set_fingerprint "$current_json")" || current_fp=""
		if [[ -n "$current_fp" && "$current_fp" == "$candidate_fp" ]]; then
			current_version="$(tr -d '\n' < "$current_ver")"
			echo "SBProxy resources: ${resource} unchanged (upstream ${version}, rules match ${current_version})"
			return 0
		fi
	fi

	printf '%s\n' "$version" > "$TEMP_DIR/${resource}.ver" || return 1
	install -m 0644 "$candidate" "$current" || return 1
	install -m 0644 "$TEMP_DIR/${resource}.ver" "$current_ver" || return 1
	echo "SBProxy resources: ${resource} ${version}"
	changed_notes+=("${resource} ${version}")
}

dashboard_manifest() {
	python3 - "$1" << 'PY'
import hashlib
import os
import sys

root = sys.argv[1]
rows = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort()
    for name in sorted(filenames):
        if name in {"dashboard.ver", ".etag"}:
            continue
        path = os.path.join(dirpath, name)
        if not os.path.isfile(path):
            continue
        digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
        rows.append("%s  %s" % (digest, os.path.relpath(path, root)))
print("\n".join(rows))
PY
}

mkdir -p -- "$RESOURCES_DIR" "$DASHBOARD_DIR"
update_failed=0
geoip_version=""
geosite_version=""
dashboard_version=""
changed_notes=()

geoip_ready=1
geoip_version="$(fetch_release_version "$GEOIP_VERSION_URL")" || geoip_ready=0
if [[ "$geoip_ready" -eq 1 ]] && \
	! download "${GEOIP_SOURCE}?v=${geoip_version}" "$TEMP_DIR/geoip_cn.srs"; then
	geoip_ready=0
fi
if [[ "$geoip_ready" -eq 1 ]] && \
	! install_rule_set_if_changed geoip_cn "$geoip_version"; then
	geoip_ready=0
fi
if [[ "$geoip_ready" -eq 1 ]]; then
	rm -f -- "$RESOURCES_DIR/china_ip4.txt" "$RESOURCES_DIR/china_ip4.ver" \
		"$RESOURCES_DIR/china_ip6.txt" "$RESOURCES_DIR/china_ip6.ver" \
		"$RESOURCES_DIR/geoip_cn.json"
else
	warn "Failed to update SBProxy geoip resource; continuing."
	update_failed=1
fi

geosite_ready=1
geosite_version="$(fetch_release_version "$GEOSITE_VERSION_URL")" || geosite_ready=0
if [[ "$geosite_ready" -eq 1 ]] && \
	download "${GEOSITE_SOURCE}?v=${geosite_version}" "$TEMP_DIR/geosite_cn.srs" && \
	install_rule_set_if_changed geosite_cn "$geosite_version"; then
	:
else
	warn "Failed to update SBProxy geosite; continuing."
	update_failed=1
fi

dashboard_ready=1
dashboard_version="$(fetch_dashboard_version)" || dashboard_ready=0
if [[ "$dashboard_ready" -eq 1 ]] && \
	! download "${DASHBOARD_SOURCE}?v=${dashboard_version}" "$TEMP_DIR/dashboard.zip"; then
	dashboard_ready=0
fi
if [[ "$dashboard_ready" -eq 1 ]] && ! unzip -q "$TEMP_DIR/dashboard.zip" -d "$TEMP_DIR/dashboard"; then
	dashboard_ready=0
fi
dashboard_source_dir=""
if [[ "$dashboard_ready" -eq 1 ]]; then
	for dashboard_index in "$TEMP_DIR/dashboard/index.html" "$TEMP_DIR"/dashboard/*/index.html; do
		if [[ -f "$dashboard_index" ]]; then
			dashboard_source_dir="${dashboard_index%/index.html}"
			break
		fi
	done
	[[ -f "$dashboard_source_dir/index.html" ]] || dashboard_ready=0
fi
if [[ "$dashboard_ready" -eq 1 ]]; then
	rm -rf -- "$DASHBOARD_STAGE"
	if mkdir -p -- "$DASHBOARD_STAGE" && \
		cp -a -- "$dashboard_source_dir/." "$DASHBOARD_STAGE/" && \
		normalize_dashboard_javascript "$DASHBOARD_STAGE" && \
		printf '%s\n' "$dashboard_version" > "$DASHBOARD_STAGE/dashboard.ver"; then
		rm -f -- "$DASHBOARD_STAGE/.etag"
		chmod -R a+rX "$DASHBOARD_STAGE"
	else
		dashboard_ready=0
	fi
fi
if [[ "$dashboard_ready" -eq 1 ]]; then
	current_manifest="$(dashboard_manifest "$DASHBOARD_DIR")" || dashboard_ready=0
	stage_manifest="$(dashboard_manifest "$DASHBOARD_STAGE")" || dashboard_ready=0
fi
if [[ "$dashboard_ready" -eq 1 ]]; then
	if [[ -f "$DASHBOARD_DIR/index.html" && "$current_manifest" == "$stage_manifest" ]]; then
		echo "SBProxy dashboard unchanged (upstream ${dashboard_version})"
		rm -rf -- "$DASHBOARD_STAGE"
	elif rm -rf -- "$DASHBOARD_DIR" && mv -- "$DASHBOARD_STAGE" "$DASHBOARD_DIR"; then
		echo "SBProxy dashboard: $dashboard_version"
		changed_notes+=("dashboard ${dashboard_version}")
	else
		dashboard_ready=0
	fi
fi
if [[ "$dashboard_ready" -ne 1 ]]; then
	warn "Failed to update SBProxy dashboard; continuing."
	update_failed=1
fi

resource_version="${changed_notes[*]:-unchanged}"
set_output version "$resource_version"
if (( ${#changed_notes[@]} > 0 )); then
	set_output changed true
else
	set_output changed false
fi
if [[ "$update_failed" -ne 0 ]]; then
	echo "SBProxy resource update failed; refusing to commit partial data." >&2
	exit 1
fi
