#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci-common.sh
source "$SCRIPT_DIR/ci-common.sh"

cd "$CI_REPO_ROOT"
output="${1:-README.md}"
temp_file="$(mktemp)"
trap 'rm -f -- "$temp_file"' EXIT

repo_url="$(git remote get-url origin 2>/dev/null || true)"
repo_url="${repo_url%.git}"

source_override() {
	local package_dir="$1"
	local metadata="$CI_REPO_ROOT/.github/package-sources.tsv"

	[[ -f "$metadata" ]] || return 0
	awk -F '\t' -v package="$package_dir" '$1 == package { print $2; exit }' \
		"$metadata"
}

normalize_source_url() {
	local url="$1"

	url="${url%%\?*}"
	if [[ "$url" =~ ^https://codeload\.github\.com/([^/]+)/([^/]+)/ ]]; then
		printf 'https://github.com/%s/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
	elif [[ "$url" =~ ^https://github\.com/([^/]+)/([^/]+) ]]; then
		printf 'https://github.com/%s/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]%.git}"
	else
		printf '%s\n' "$url"
	fi
}

package_source_url() {
	local package_dir="$1"
	local makefile="$CI_REPO_ROOT/$package_dir/Makefile"
	local override source_url package_url go_pkg sibling dependency

	override="$(source_override "$package_dir")"
	[[ -z "$override" ]] || {
		printf '%s\n' "$override"
		return
	}

	if [[ "$package_dir" == luci-app-* ]]; then
		sibling="${package_dir#luci-app-}"
		if [[ -f "$CI_REPO_ROOT/$sibling/Makefile" ]]; then
			package_source_url "$sibling"
			return
		fi
		while IFS= read -r dependency; do
			if [[ -f "$CI_REPO_ROOT/$dependency/Makefile" ]]; then
				package_source_url "$dependency"
				return
			fi
		done < <(grep -oE '\+[A-Za-z0-9._+-]+' "$makefile" | sed 's/^+//' | sort -u)
	fi

	source_url="$(sed -n 's/^PKG_SOURCE_URL:=//p' "$makefile" | head -n1)"
	if [[ "$source_url" == http* ]]; then
		source_url="$(normalize_source_url "$source_url")"
		if [[ -n "$source_url" && "$source_url" != "$repo_url" ]]; then
			printf '%s\n' "$source_url"
			return
		fi
	fi

	package_url="$(sed -n 's/^[[:space:]]*URL:=//p' "$makefile" | head -n1)"
	if [[ "$package_url" == http* ]]; then
		printf '%s\n' "${package_url%/}"
		return
	fi

	go_pkg="$(ci_make_value "$package_dir" GO_PKG)"
	if [[ "$go_pkg" == github.com/*/* ]]; then
		printf 'https://%s\n' "$go_pkg"
		return
	fi

	printf '%s\n' "$repo_url"
}

source_label() {
	local url="$1"
	local label

	if [[ "$url" =~ ^https?://github\.com/([^/]+)/([^/]+) ]]; then
		label="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
	else
		label="${url#*://}"
		label="${label%%/*}"
	fi
	printf '[%s](%s)' "$label" "$url"
}

plugin_description() {
	local package_dir="$1"

	case "$package_dir" in
		luci-app-sbproxy)
			printf 'SBProxy 的 LuCI 管理界面，负责代理、节点、Tailscale 与核心管理。\n'
			;;
		sing-box)
			printf '带本项目 Tailscale 兼容补丁的 sing-box 核心，供固件打包和在线安装。\n'
			;;
		*)
			printf '%s。\n' "$package_dir"
			;;
	esac
}

mapfile -t package_dirs < <(ci_discover_packages)

{
	echo '# SBProxy'
	echo
	echo '**个人自用。** 本仓库只为作者自己的 OpenWrt / ImmortalWrt（ARM64、AMD64）路由器维护 SBProxy，公开代码仅用于自行同步与备份，不提供代理服务，也不对他人的下载、编译或安装负责。使用者须自行评估并承担网络访问、合规与安全风险。'
	echo
	echo 'LuCI 界面管理客户端、服务端、节点和核心；流量由 TUN 接管，Tailscale 可以跑在同一个 sing-box 进程里。'
	echo
	echo '## 说明'
	echo
	echo '- **代理模式**：关闭、大陆白名单、自定义路由、全局。大陆白名单支持域名、地址、端口和规则集分流。'
	echo '- **节点**：订阅导入、URLTest，以及在候选组内按延迟和短下载表现智能选节点。'
	echo '- **接入控制**：可按 Wi-Fi 或有线接口让部分来源不接管，其余来源继续走现有分流。'
	echo '- **Tailscale**：内置在 SBProxy 的 sing-box 进程中，可以不依赖代理节点单独运行。'
	echo '- **核心**：发布带本项目 Tailscale 兼容补丁的 sing-box 预编译核心。官方上游二进制不含这些补丁。'
	echo
	echo '行为细节见文档：'
	echo
	echo '- [TUN 接管与分流](docs/sbproxy-diversion.md)'
	echo '- [代理模式](docs/sbproxy-proxy-mode.md)'
	echo '- [智能选节点](docs/sbproxy-smart-selection.md)'
	echo '- [接入接口分流](docs/sbproxy-ingress-policy.md)'
	echo '- [独立核心构建与发布](docs/sbproxy-core.md)'
	echo '- [自适应规则移除](docs/sbproxy-adaptive-removal.md)'
	echo
	echo '## 软件包'
	echo
	echo '| 软件包 | 版本 | 说明 | 源码来源 |'
	echo '| --- | --- | --- | --- |'
	for package_dir in "${package_dirs[@]}"; do
		name="$(ci_package_name "$package_dir")"
		if [[ "$name" == sing-box ]]; then
			version="$(ci_make_value "$package_dir" PKG_VERSION)"
		else
			version="$(ci_package_version "$package_dir")"
		fi
		description="$(plugin_description "$package_dir")"
		source_url="$(package_source_url "$package_dir")"
		printf "| \`%s\` | \`%s\` | %s | %s |\n" \
			"$name" "$version" "$description" "$(source_label "$source_url")"
	done
	echo
	echo '## 自动维护'
	echo
	echo 'CI 每天两次检查 sing-box 上游稳定版和 SBProxy 规则数据（北京时间 02:17 和 14:47），仅在发现更新时继续构建、提交和发布。软件包目录通过 Makefile 自动发现；新增或删除软件包后，构建范围和发布资产清理会自动调整。'
	echo
	echo '独立 sing-box 核心按稳定版发布，最多保留 5 个版本。APK 发布按 ARM64 和 AMD64 分开维护；每个包名保留最近三个版本，并提供包含各软件包最新版的整合包。'
	echo
	echo '## License'
	echo
	echo '本仓库自有的 CI、脚本、文档及未另行声明的原创内容采用 [MIT License](LICENSE)。各插件、核心程序和预置第三方资源继续遵循其目录或上游项目声明的许可证。'
} > "$temp_file"

mv -f -- "$temp_file" "$output"
trap - EXIT
