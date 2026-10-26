#!/bin/sh

set -eu

PACKAGE_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PATCH="$PACKAGE_ROOT/patches/010-api-expose-tailscale-peer-subnet-routes.patch"
TAILSCALE_PATCH="$PACKAGE_ROOT/tailscale-patches/010-restore-linux-policy-routing.patch"
MAKEFILE="$PACKAGE_ROOT/Makefile"
WORKFLOW="$PACKAGE_ROOT/../.github/scripts/core-release.py"

test -s "$PATCH"
grep -Fq 'PrimaryRoutes' "$PATCH"
grep -Fq 'primaryRoutes = 18' "$PATCH"
grep -Fq 'commandAPITailscaleRouteList' "$PATCH"
grep -Fq 'List Tailscale peer subnet routes' "$PATCH"

test -s "$TAILSCALE_PATCH"
grep -Fq 'r.ipRuleAvailable = (cmd.run("ip", "rule") == nil)' "$TAILSCALE_PATCH"
grep -Fq 'checkOpenWRTUsingMWAN3()' "$TAILSCALE_PATCH"
grep -Fq 'if err := r.addIPRules(); err != nil {' "$TAILSCALE_PATCH"
grep -Fq 'if err := r.delIPRules(); err != nil {' "$TAILSCALE_PATCH"
grep -Eq '^TAILSCALE_MODULE_VERSION:=v[^[:space:]]+$' "$MAKEFILE"
grep -Fq 'GO_PKG_INSTALL_EXTRA:=third_party/tailscale' "$MAKEFILE"
grep -Fq '$(GO_BIN_PATH) $(GO_PKG_BUILD_VARS) go mod download $(GO_MOD_ARGS) $(TAILSCALE_MODULE)' "$MAKEFILE"
grep -Fq '$(call PatchDir,$(PKG_BUILD_DIR)/third_party/tailscale,./tailscale-patches,)' "$MAKEFILE"
grep -Fq '$(GO_BIN_PATH) $(GO_PKG_BUILD_VARS) go mod edit' "$MAKEFILE"
grep -Fq -- '-replace github.com/sagernet/tailscale=./third_party/tailscale' "$MAKEFILE"
grep -Fq "version_channel(tag[1:]) != channel" "$WORKFLOW"
grep -Fq "Alpha releases must not replace the stable firmware pin" "$WORKFLOW"

golang_include_line="$(grep -nF 'include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk' "$MAKEFILE" | cut -d: -f1)"
module_dir_line="$(grep -nF 'TAILSCALE_MODULE_DIR:=$(GO_MOD_CACHE_DIR)/github.com/sagernet/tailscale@$(TAILSCALE_MODULE_VERSION)' "$MAKEFILE" | cut -d: -f1)"
[ -n "$golang_include_line" ] && [ -n "$module_dir_line" ] && [ "$module_dir_line" -gt "$golang_include_line" ]

echo 'sing-box Tailscale test passed: route API and patched local dependency build wiring are present'
