#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2022-2025 ImmortalWrt.org

NAME="sbproxy"

RESOURCES_DIR="${RESOURCES_DIR:-/etc/$NAME/resources}"
DASHBOARD_DIR="${DASHBOARD_DIR:-/etc/$NAME/dashboard}"
SINGBOX_DASHBOARD_DIR="${SINGBOX_DASHBOARD_DIR:-/etc/$NAME/dashboard-singbox}"
YACD_DASHBOARD_DIR="${YACD_DASHBOARD_DIR:-/etc/$NAME/dashboard-yacd}"
METACUBEXD_DASHBOARD_DIR="${METACUBEXD_DASHBOARD_DIR:-/etc/$NAME/dashboard-metacubexd}"
RUN_DIR="${RUN_DIR:-/var/run/$NAME}"
LOG_PATH="$RUN_DIR/$NAME.log"
RESULT_PATH="$RUN_DIR/update_resources.result"
GEOIP_SOURCE="${GEOIP_SOURCE:-https://cdn.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-cn.srs}"
GEOIP_VERSION_URL="${GEOIP_VERSION_URL:-https://github.com/SagerNet/sing-geoip/releases/latest}"
GEOSITE_SOURCE="${GEOSITE_SOURCE:-https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set-unstable/geosite-cn.srs}"
GEOSITE_VERSION_URL="${GEOSITE_VERSION_URL:-https://github.com/SagerNet/sing-geosite/releases/latest}"
DASHBOARD_SOURCE="${DASHBOARD_SOURCE:-https://codeload.github.com/SagerNet/sing-box-dashboard/zip/refs/heads/gh-pages}"
DASHBOARD_VERSION_URL="${DASHBOARD_VERSION_URL:-https://github.com/SagerNet/sing-box-dashboard/commits/gh-pages.atom}"
YACD_SOURCE="${YACD_SOURCE:-https://codeload.github.com/MetaCubeX/Yacd-meta/zip/refs/heads/gh-pages}"
YACD_VERSION_URL="${YACD_VERSION_URL:-https://github.com/MetaCubeX/Yacd-meta/commits/gh-pages.atom}"
METACUBEXD_SOURCE="${METACUBEXD_SOURCE:-https://codeload.github.com/MetaCubeX/metacubexd/zip/refs/heads/gh-pages}"
METACUBEXD_VERSION_URL="${METACUBEXD_VERSION_URL:-https://github.com/MetaCubeX/metacubexd/commits/gh-pages.atom}"
USER_AGENT="SBProxy resource updater"
UPDATE_PROXY="${SBPROXY_UPDATE_PROXY:-}"
SING_BOX="${SING_BOX:-/usr/bin/sing-box}"
DASHBOARD_SELECT="${DASHBOARD_SELECT:-/usr/libexec/sbproxy-dashboard-select}"

if ! mkdir -p "$RESOURCES_DIR" "$SINGBOX_DASHBOARD_DIR" "$YACD_DASHBOARD_DIR" "$METACUBEXD_DASHBOARD_DIR" "$RUN_DIR"; then
	printf '%s\n' "Failed to prepare SBProxy resource directories." >&2
	exit 1
fi

log() {
	printf '%s %s\n' "$(date "+%Y-%m-%d %H:%M:%S")" "$*" >> "$LOG_PATH"
}

UPDATED_BRANCHES=""
FAILED_BRANCHES=""
CORE_UPDATED=0
DASHBOARD_UPDATED=0

append_result() {
	local current="$1" value="$2"

	if [ -n "$current" ]; then
		printf '%s,%s' "$current" "$value"
	else
		printf '%s' "$value"
	fi
}

mark_updated() {
	UPDATED_BRANCHES="$(append_result "$UPDATED_BRANCHES" "$1")"
}

mark_failed() {
	FAILED_BRANCHES="$(append_result "$FAILED_BRANCHES" "$1")"
}

write_result() {
	local status="$1"

	printf 'status=%s\ncore_updated=%s\ndashboard_updated=%s\nupdated=%s\nfailed=%s\n' \
		"$status" "$CORE_UPDATED" "$DASHBOARD_UPDATED" \
		"$UPDATED_BRANCHES" "$FAILED_BRANCHES" > "$RESULT_PATH"
}

finish() {
	write_result "$1"
	exit "$1"
}

run_curl() {
	if [ -n "$UPDATE_PROXY" ]; then
		/usr/bin/curl --proxy "$UPDATE_PROXY" "$@"
	else
		/usr/bin/curl "$@"
	fi
}

download() {
	local source_url="$1"
	local target_file="$2"

	run_curl -fsSL --compressed --retry 3 --retry-all-errors --retry-delay 1 \
		--connect-timeout 10 --max-time 60 \
		-A "$USER_AGENT" \
		-o "$target_file" "$source_url" && [ -s "$target_file" ]
}

validate_rule_set() {
	[ -x "$SING_BOX" ] &&
		"$SING_BOX" rule-set decompile "$1" -o /dev/null >"/dev/null" 2>&1
}

fetch_release_version() {
	local release_url="$1"
	local effective_url

	effective_url="$(run_curl -fsSL --compressed --retry 3 --retry-all-errors --retry-delay 1 \
		--connect-timeout 10 --max-time 30 \
		-A "$USER_AGENT" -o "/dev/null" -w '%{url_effective}' "$release_url")" || return 1
	local release_version="${effective_url##*/}"
	case "$release_version" in
	''|*[!0-9]*) return 1 ;;
	esac
	printf '%s\n' "$release_version"
}

fetch_feed_version() {
	local feed_url="$1"
	local feed version

	feed="$(run_curl -fsSL --compressed --retry 3 --retry-all-errors --retry-delay 1 \
		--connect-timeout 10 --max-time 30 -A "$USER_AGENT" "$feed_url")" || return 1
	version="$(printf '%s\n' "$feed" | awk -F '[<>]' '
		/<updated>/ {
			version = $3
			gsub(/[-:TZ]/, "", version)
			print version
			exit
		}
	')"
	case "$version" in
	??????????????) case "$version" in *[!0-9]*) return 1 ;; esac ;;
	*) return 1 ;;
	esac
	printf '%s\n' "$version"
}

fetch_dashboard_version() {
	fetch_feed_version "$DASHBOARD_VERSION_URL"
}

fetch_yacd_version() {
	fetch_feed_version "$YACD_VERSION_URL"
}

fetch_metacubexd_version() {
	fetch_feed_version "$METACUBEXD_VERSION_URL"
}

install_dashboard_archive() {
	local label="$1" source_url="$2" version="$3" target_dir="$4"
	local ready=1 source_dir="" index stage_dir="${target_dir}.new.$$"

	if ! download "$(versioned_url "$source_url" "$version")" "$TMP_DIR/$label.zip"; then
		log "[$label] Update failed while downloading the dashboard."
		return 1
	elif ! mkdir -p "$TMP_DIR/$label" || \
	   ! unzip -q "$TMP_DIR/$label.zip" -d "$TMP_DIR/$label"; then
		log "[$label] Update failed while extracting the dashboard."
		return 1
	fi
	for index in "$TMP_DIR/$label/index.html" "$TMP_DIR"/$label/*/index.html; do
		if [ -f "$index" ]; then
			source_dir="${index%/index.html}"
			break
		fi
	done
	if [ ! -f "$source_dir/index.html" ]; then
		log "[$label] Update failed: invalid dashboard archive."
		return 1
	fi
	rm -rf "$stage_dir"
	if ! mkdir -p "$stage_dir" || ! cp -a "$source_dir/." "$stage_dir/"; then
		log "[$label] Update failed while staging the dashboard."
		ready=0
	elif ! printf '%s\n' "$version" > "$stage_dir/dashboard.ver"; then
		log "[$label] Update failed while writing its version."
		ready=0
	else
		chmod -R a+rX "$stage_dir"
	fi
	if [ "$ready" -ne 1 ]; then
		rm -rf "$stage_dir"
		return 1
	fi
	rm -rf "$target_dir"
	if mv "$stage_dir" "$target_dir"; then
		log "[$label] Successfully updated."
		return 0
	fi
	log "[$label] Update failed: unable to replace dashboard files."
	return 1
}

versioned_url() {
	case "$1" in
	http://*|https://*) printf '%s?v=%s' "$1" "$2" ;;
	*) printf '%s' "$1" ;;
	esac
}

install_rule_set() {
	local source_file="$1" version="$2" resource="$3"
	local stage_dir="$RESOURCES_DIR/.update.$$.tmp"
	mkdir -p "$stage_dir" || return 1
	cp "$source_file" "$stage_dir/$resource.srs" || return 1
	printf '%s\n' "$version" > "$stage_dir/$resource.ver" || return 1
	chmod 0644 "$stage_dir/$resource.srs" "$stage_dir/$resource.ver" || return 1
	local had_data=0 had_version=0
	if [ -f "$RESOURCES_DIR/$resource.srs" ]; then
		cp "$RESOURCES_DIR/$resource.srs" "$stage_dir/previous.srs" || return 1
		had_data=1
	fi
	if [ -f "$RESOURCES_DIR/$resource.ver" ]; then
		cp "$RESOURCES_DIR/$resource.ver" "$stage_dir/previous.ver" || return 1
		had_version=1
	fi
	if mv -f "$stage_dir/$resource.srs" "$RESOURCES_DIR/$resource.srs" &&
	   mv -f "$stage_dir/$resource.ver" "$RESOURCES_DIR/$resource.ver"; then
		return 0
	fi
	if [ "$had_data" = 1 ]; then mv -f "$stage_dir/previous.srs" "$RESOURCES_DIR/$resource.srs";
	else rm -f "$RESOURCES_DIR/$resource.srs"; fi
	if [ "$had_version" = 1 ]; then mv -f "$stage_dir/previous.ver" "$RESOURCES_DIR/$resource.ver";
	else rm -f "$RESOURCES_DIR/$resource.ver"; fi
	return 1
}

exec 9>"$RUN_DIR/update_resources.lock"
if ! flock -n 9 > "/dev/null" 2>&1; then
	log "[RESOURCES] A task is already running."
	exit 2
fi
rm -f "$RESULT_PATH"
if [ -e "$SINGBOX_DASHBOARD_DIR/.etag" ] || [ -e "$YACD_DASHBOARD_DIR/.etag" ] || \
   [ -e "$METACUBEXD_DASHBOARD_DIR/.etag" ] || \
   { [ -e "$DASHBOARD_DIR" ] && [ ! -L "$DASHBOARD_DIR" ] && [ -e "$DASHBOARD_DIR/.etag" ]; }; then
	rm -f "$SINGBOX_DASHBOARD_DIR/.etag" "$YACD_DASHBOARD_DIR/.etag" "$METACUBEXD_DASHBOARD_DIR/.etag"
	[ -L "$DASHBOARD_DIR" ] || rm -f "$DASHBOARD_DIR/.etag"
	DASHBOARD_UPDATED=1
fi

GEOIP_CURRENT=1
GEOSITE_CURRENT=1
DASHBOARD_CURRENT=1
YACD_CURRENT=1
METACUBEXD_CURRENT=1

if NEW_GEOIP_VER="$(fetch_release_version "$GEOIP_VERSION_URL")"; then
	OLD_VER="$(cat "$RESOURCES_DIR/geoip_cn.ver" 2>/dev/null || echo "NOT FOUND")"
	if [ -s "$RESOURCES_DIR/geoip_cn.srs" ] && \
	   validate_rule_set "$RESOURCES_DIR/geoip_cn.srs" && \
	   [ "$OLD_VER" = "$NEW_GEOIP_VER" ]; then
		log "[geoip_cn] Current version: $NEW_GEOIP_VER."
	else
		GEOIP_CURRENT=0
		log "[geoip_cn] Local version: $OLD_VER, latest version: $NEW_GEOIP_VER."
	fi
else
	GEOIP_CURRENT=-1
	mark_failed "geoip_cn"
	log "[geoip_cn] Failed to get the latest version; continuing with other resources."
fi

if NEW_GEOSITE_VER="$(fetch_release_version "$GEOSITE_VERSION_URL")"; then
	OLD_VER="$(cat "$RESOURCES_DIR/geosite_cn.ver" 2>/dev/null || echo "NOT FOUND")"
	if [ -s "$RESOURCES_DIR/geosite_cn.srs" ] && \
	   validate_rule_set "$RESOURCES_DIR/geosite_cn.srs" && \
	   [ "$OLD_VER" = "$NEW_GEOSITE_VER" ]; then
		log "[geosite_cn] Current version: $NEW_GEOSITE_VER."
	else
		GEOSITE_CURRENT=0
		log "[geosite_cn] Local version: $OLD_VER, latest version: $NEW_GEOSITE_VER."
	fi
else
	GEOSITE_CURRENT=-1
	mark_failed "geosite_cn"
	log "[geosite_cn] Failed to get the latest version; continuing with other resources."
fi

if NEW_DASHBOARD_VER="$(fetch_dashboard_version)"; then
	OLD_VER="$(cat "$SINGBOX_DASHBOARD_DIR/dashboard.ver" 2>/dev/null || echo "NOT FOUND")"
	if [ -s "$SINGBOX_DASHBOARD_DIR/index.html" ] && [ "$OLD_VER" = "$NEW_DASHBOARD_VER" ]; then
		log "[dashboard] Current version: $NEW_DASHBOARD_VER."
	else
		DASHBOARD_CURRENT=0
		log "[dashboard] Local version: $OLD_VER, latest version: $NEW_DASHBOARD_VER."
	fi
else
	DASHBOARD_CURRENT=-1
	mark_failed "dashboard"
	log "[dashboard] Failed to get the latest version; continuing with other resources."
fi

if NEW_YACD_VER="$(fetch_yacd_version)"; then
	OLD_VER="$(cat "$YACD_DASHBOARD_DIR/dashboard.ver" 2>/dev/null || echo "NOT FOUND")"
	if [ -s "$YACD_DASHBOARD_DIR/index.html" ] && [ "$OLD_VER" = "$NEW_YACD_VER" ]; then
		log "[yacd] Current version: $NEW_YACD_VER."
	else
		YACD_CURRENT=0
		log "[yacd] Local version: $OLD_VER, latest version: $NEW_YACD_VER."
	fi
else
	YACD_CURRENT=-1
	mark_failed "yacd"
	log "[yacd] Failed to get the latest version; continuing with other resources."
fi

if NEW_METACUBEXD_VER="$(fetch_metacubexd_version)"; then
	OLD_VER="$(cat "$METACUBEXD_DASHBOARD_DIR/dashboard.ver" 2>/dev/null || echo "NOT FOUND")"
	if [ -s "$METACUBEXD_DASHBOARD_DIR/index.html" ] && [ "$OLD_VER" = "$NEW_METACUBEXD_VER" ]; then
		log "[metacubexd] Current version: $NEW_METACUBEXD_VER."
	else
		METACUBEXD_CURRENT=0
		log "[metacubexd] Local version: $OLD_VER, latest version: $NEW_METACUBEXD_VER."
	fi
else
	METACUBEXD_CURRENT=-1
	mark_failed "metacubexd"
	log "[metacubexd] Failed to get the latest version; continuing with other resources."
fi

if [ "$GEOIP_CURRENT" -eq 1 ] && [ "$GEOSITE_CURRENT" -eq 1 ] && \
	[ "$DASHBOARD_CURRENT" -eq 1 ] && [ "$YACD_CURRENT" -eq 1 ] && \
	[ "$METACUBEXD_CURRENT" -eq 1 ]; then
	log "[RESOURCES] You're already at the latest version."
	finish 3
fi

TMP_DIR="$(mktemp -d "$RUN_DIR/resources-update.XXXXXX")" || {
	log "[RESOURCES] Failed to prepare the temporary update directory."
	finish 1
}
cleanup() {
	rm -rf "$TMP_DIR" "${SINGBOX_DASHBOARD_DIR}.new.$$" "${YACD_DASHBOARD_DIR}.new.$$" \
		"${METACUBEXD_DASHBOARD_DIR}.new.$$" \
		"$RESOURCES_DIR/.update.$$.tmp"
}
trap cleanup EXIT INT TERM

if [ "$GEOIP_CURRENT" -eq 0 ]; then
	if ! download "$(versioned_url "$GEOIP_SOURCE" "$NEW_GEOIP_VER")" "$TMP_DIR/geoip_cn.srs"; then
		log "[geoip_cn] Update failed while downloading the IP rule set."
		mark_failed "geoip_cn"
	elif ! validate_rule_set "$TMP_DIR/geoip_cn.srs"; then
		log "[geoip_cn] Update failed: invalid binary rule set."
		mark_failed "geoip_cn"
	elif ! install_rule_set "$TMP_DIR/geoip_cn.srs" "$NEW_GEOIP_VER" "geoip_cn"; then
		log "[geoip_cn] Update failed while installing the IP rule set."
		mark_failed "geoip_cn"
	else
		log "[geoip_cn] Successfully updated."
		CORE_UPDATED=1
		mark_updated "geoip_cn"
	fi
fi

if [ "$GEOSITE_CURRENT" -eq 0 ]; then
	if ! download "$(versioned_url "$GEOSITE_SOURCE" "$NEW_GEOSITE_VER")" "$TMP_DIR/geosite_cn.srs"; then
		log "[geosite_cn] Update failed while downloading the domain rule set."
		mark_failed "geosite_cn"
	elif ! validate_rule_set "$TMP_DIR/geosite_cn.srs"; then
		log "[geosite_cn] Update failed: invalid binary rule set."
		mark_failed "geosite_cn"
	elif ! install_rule_set "$TMP_DIR/geosite_cn.srs" "$NEW_GEOSITE_VER" "geosite_cn"; then
		log "[geosite_cn] Update failed while installing the domain rule set."
		mark_failed "geosite_cn"
	else
		log "[geosite_cn] Successfully updated."
		CORE_UPDATED=1
		mark_updated "geosite_cn"
	fi
fi

if [ "$DASHBOARD_CURRENT" -eq 0 ]; then
	if install_dashboard_archive "dashboard" "$DASHBOARD_SOURCE" "$NEW_DASHBOARD_VER" "$SINGBOX_DASHBOARD_DIR"; then
		DASHBOARD_UPDATED=1
		mark_updated "dashboard"
	else
		mark_failed "dashboard"
	fi
fi

if [ "$YACD_CURRENT" -eq 0 ]; then
	if install_dashboard_archive "yacd" "$YACD_SOURCE" "$NEW_YACD_VER" "$YACD_DASHBOARD_DIR"; then
		DASHBOARD_UPDATED=1
		mark_updated "yacd"
	else
		mark_failed "yacd"
	fi
fi

if [ "$METACUBEXD_CURRENT" -eq 0 ]; then
	if install_dashboard_archive "metacubexd" "$METACUBEXD_SOURCE" "$NEW_METACUBEXD_VER" "$METACUBEXD_DASHBOARD_DIR"; then
		DASHBOARD_UPDATED=1
		mark_updated "metacubexd"
	else
		mark_failed "metacubexd"
	fi
fi

if [ -x "$DASHBOARD_SELECT" ]; then
	"$DASHBOARD_SELECT" || \
		log "[dashboard] Failed to point the active dashboard at the selected UI."
elif [ ! -e "$DASHBOARD_DIR" ] && [ -s "$SINGBOX_DASHBOARD_DIR/index.html" ]; then
	ln -s "$SINGBOX_DASHBOARD_DIR" "$DASHBOARD_DIR" || \
		log "[dashboard] Failed to point the active dashboard at the official UI."
fi

if [ -n "$FAILED_BRANCHES" ]; then
	if [ -n "$UPDATED_BRANCHES" ]; then
		log "[RESOURCES] Partially updated ($UPDATED_BRANCHES); failed branches: $FAILED_BRANCHES."
		finish 4
	fi
	log "[RESOURCES] Update failed for: $FAILED_BRANCHES."
	finish 1
fi

finish 0
