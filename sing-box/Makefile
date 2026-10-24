# SPDX-License-Identifier: GPL-3.0-only
#
# Copyright (C) 2022-2023 ImmortalWrt.org

include $(TOPDIR)/rules.mk

PKG_NAME:=sing-box
PKG_UPSTREAM_VERSION:=1.14.4
PKG_VERSION:=1.14.4
PKG_RELEASE:=1

PKG_SOURCE:=$(PKG_NAME)-$(PKG_UPSTREAM_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/SagerNet/sing-box/tar.gz/v$(PKG_UPSTREAM_VERSION)?
PKG_HASH:=0958ccd23b1ea9a141d715d15478b1e040fd04bcca19d8ff5529636b1b753e18
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_UPSTREAM_VERSION)

# Written only after both architectures have been published successfully.
# No pin yet (bootstrap), unsupported targets and tiny/custom builds use source.
-include ./core-prebuilt.mk
CORE_ARCH:=$(if $(filter aarch64,$(ARCH)),arm64,$(if $(filter x86_64,$(ARCH)),amd64))
# Legacy pins are 1.14.2-r1. New pins are the upstream version only.
CORE_PIN_IDENTITY:=$(if $(findstring -r,$(CORE_PIN_VERSION)),$(PKG_VERSION)-r$(PKG_RELEASE),$(PKG_VERSION))
CORE_PREBUILT:=$(if $(filter $(CORE_PIN_IDENTITY),$(CORE_PIN_VERSION)),$(CORE_SHA256_$(CORE_ARCH)))
ifneq ($(filter 1 y,$(SBPROXY_CORE_SOURCE_BUILD) $(CONFIG_SING_BOX_BUILD_FROM_SOURCE)),)
  CORE_PREBUILT:=
endif
ifneq ($(filter tiny,$(BUILD_VARIANT)),)
  CORE_PREBUILT:=
endif
ifneq ($(CORE_PREBUILT),)
  PKG_SOURCE:=sing-box-$(CORE_PIN_VERSION)-linux-$(CORE_ARCH).tar.gz
  PKG_SOURCE_URL:=https://github.com/welenwho/packages/releases/download/sbproxy-core-v$(CORE_PIN_VERSION)
  PKG_HASH:=$(CORE_PREBUILT)
  PKG_BUILD_DIR:=$(BUILD_DIR)/sing-box-$(CORE_PIN_VERSION)-linux-$(CORE_ARCH)
  # The archive already contains the patched core.
  PATCH_DIR:=/nonexistent-sbproxy-prebuilt-patches
endif

PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Tianling Shen <cnsztl@immortalwrt.org>
PKG_CPE_ID:=cpe:/a:sagernet:sing-box

PKG_CONFIG_DEPENDS:= \
	CONFIG_SING_BOX_BUILD_FROM_SOURCE \
	CONFIG_SING_BOX_TINY_BUILD_ACME \
	CONFIG_SING_BOX_TINY_BUILD_CLASH_API \
	CONFIG_SING_BOX_TINY_BUILD_DHCP \
	CONFIG_SING_BOX_TINY_BUILD_EMBEDDED_TOR \
	CONFIG_SING_BOX_TINY_BUILD_GRPC \
	CONFIG_SING_BOX_TINY_BUILD_GVISOR \
	CONFIG_SING_BOX_TINY_BUILD_QUIC \
	CONFIG_SING_BOX_TINY_BUILD_TAILSCALE \
	CONFIG_SING_BOX_TINY_BUILD_UTLS \
	CONFIG_SING_BOX_TINY_BUILD_V2RAY_API \
	CONFIG_SING_BOX_TINY_BUILD_WIREGUARD

ifeq ($(CORE_PREBUILT),)
  PKG_BUILD_DEPENDS:=golang/host
endif
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

GO_PKG:=github.com/sagernet/sing-box
GO_PKG_BUILD_PKG:=$(GO_PKG)/cmd/sing-box
GO_PKG_LDFLAGS_X:=$(GO_PKG)/constant.Version=$(PKG_UPSTREAM_VERSION)
GO_PKG_INSTALL_EXTRA:=third_party/tailscale

TAILSCALE_MODULE_VERSION:=v1.102.1-sing-box-1.14-mod.5.0.20261019070639-79c1732442a9
TAILSCALE_MODULE:=github.com/sagernet/tailscale@$(TAILSCALE_MODULE_VERSION)

include $(INCLUDE_DIR)/package.mk
ifeq ($(CORE_PREBUILT),)
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk
# Release binaries use a baseline CPU and no libc dependency. Firmware builds
# of other packages remain unaffected by these package-local overrides.
ifeq ($(SBPROXY_CORE_SOURCE_BUILD),1)
GO_PKG_TARGET_VARS+=CGO_ENABLED=0 GOAMD64=v1 GOARM64=v8.0
GO_PKG_DEFAULT_LDFLAGS:=
GO_PKG_ENABLE_PIE:=
endif
else
GO_ARCH_DEPENDS:=@aarch64||x86_64
# SDK Go packaging has already stripped this binary. Generic sstrip corrupts
# Go ELF headers on some targets; do not strip a verified archive a second time.
STRIP:=true
endif

TAILSCALE_MODULE_DIR:=$(GO_MOD_CACHE_DIR)/github.com/sagernet/tailscale@$(TAILSCALE_MODULE_VERSION)

define Package/sing-box/Default
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  TITLE:=The universal proxy platform
  URL:=https://sing-box.sagernet.org/
  DEPENDS:=+ca-bundle +kmod-inet-diag
  USERID:=sing-box=5566:sing-box=5566
endef

define Package/sing-box
  $(call Package/sing-box/Default)
  TITLE+= (full version)
  DEPENDS+= +kmod-netlink-diag +kmod-tun
  CONFLICTS:=sing-box-tiny
  VARIANT:=full
  DEFAULT_VARIANT:=1
endef

define Package/sing-box/description
  Sing-box is a universal proxy platform which supports hysteria, SOCKS, Shadowsocks,
  ShadowTLS, Tor, trojan, VLess, VMess, WireGuard and so on.
endef

define Package/sing-box/config
  depends on $(subst @,,$(GO_ARCH_DEPENDS))
  config SING_BOX_BUILD_FROM_SOURCE
    bool "Build sing-box from source instead of using the pinned SBProxy core"
    default n
endef

define Package/sing-box-tiny
  $(call Package/sing-box/Default)
  TITLE+= (tiny/custom version)
  PROVIDES:=sing-box
  VARIANT:=tiny
endef

Package/sing-box-tiny/description:=$(Package/sing-box/description)

define Package/sing-box-tiny/config
  depends on $(subst @,,$(GO_ARCH_DEPENDS))

  if PACKAGE_sing-box-tiny
    config SING_BOX_TINY_BUILD_ACME
    bool "Build with ACME TLS certificate issuer support"

    config SING_BOX_TINY_BUILD_CLASH_API
    bool "Build with Clash API support"
    default y

    config SING_BOX_TINY_BUILD_DHCP
    bool "Build with DHCP support"

    config SING_BOX_TINY_BUILD_EMBEDDED_TOR
    bool "Build with embedded Tor support"
    depends on BROKEN

    config SING_BOX_TINY_BUILD_GRPC
    bool "Build with standard gPRC support"
    help
      Standard gRPC has good compatibility but poor performance.

    config SING_BOX_TINY_BUILD_GVISOR
    bool "Build with gVisor support"
    default y if aarch64||arm||i386||x86_64

    config SING_BOX_TINY_BUILD_QUIC
    bool "Build with QUIC support"
    default y
    help
      Required by HTTP3 DNS transports, Naive inbound,
      Hysteria inbound / outbound, and v2ray QUIC transport.

    config SING_BOX_TINY_BUILD_TAILSCALE
    bool "Build with Tailscale support"

    config SING_BOX_TINY_BUILD_UTLS
    bool "Build with uTLS support"
    default y

    config SING_BOX_TINY_BUILD_V2RAY_API
    bool "Build with V2Ray API support"

    config SING_BOX_TINY_BUILD_WIREGUARD
    bool "Build with WireGuard support"
    default y if aarch64||arm||i386||x86_64
  endif
endef

ifeq ($(BUILD_VARIANT),full)
  GO_PKG_TAGS:=with_acme,with_clash_api,with_dhcp,with_gvisor,with_quic,with_tailscale,with_utls,with_wireguard
else
  GO_PKG_TAGS:=$(subst $(space),$(comma),$(strip \
	$(if $(CONFIG_SING_BOX_TINY_BUILD_ACME),with_acme) \
	$(if $(CONFIG_SING_BOX_TINY_BUILD_CLASH_API),with_clash_api) \
	$(if $(CONFIG_SING_BOX_TINY_BUILD_DHCP),with_dhcp) \
	$(if $(CONFIG_SING_BOX_TINY_BUILD_EMBEDDED_TOR),with_embedded_tor) \
	$(if $(CONFIG_SING_BOX_TINY_BUILD_GRPC),with_grpc) \
	$(if $(CONFIG_SING_BOX_TINY_BUILD_GVISOR),with_gvisor) \
	$(if $(CONFIG_SING_BOX_TINY_BUILD_QUIC),with_quic) \
	$(if $(CONFIG_SING_BOX_TINY_BUILD_TAILSCALE),with_tailscale) \
	$(if $(CONFIG_SING_BOX_TINY_BUILD_UTLS),with_utls) \
	$(if $(CONFIG_SING_BOX_TINY_BUILD_V2RAY_API),with_v2ray_api) \
	$(if $(CONFIG_SING_BOX_TINY_BUILD_WIREGUARD),with_wireguard) \
  ))
endif

# x/net/http2 uses a stdlib-backed wrapper by default on Go 1.27, which omits
# the private connPool symbol referenced by sing-box's v2ray HTTP transport.
GO_PKG_TAGS:=http2legacy,$(GO_PKG_TAGS)

ifeq ($(CORE_PREBUILT),)
define Build/Configure
	cd $(PKG_BUILD_DIR) && \
		$(GO_BIN_PATH) $(GO_PKG_BUILD_VARS) go mod download $(GO_MOD_ARGS) $(TAILSCALE_MODULE)
	rm -rf $(PKG_BUILD_DIR)/third_party/tailscale
	mkdir -p $(PKG_BUILD_DIR)/third_party/tailscale
	cp -fpR $(TAILSCALE_MODULE_DIR)/. $(PKG_BUILD_DIR)/third_party/tailscale/
	chmod -R u+w $(PKG_BUILD_DIR)/third_party/tailscale
	$(call PatchDir,$(PKG_BUILD_DIR)/third_party/tailscale,./tailscale-patches,)
	cd $(PKG_BUILD_DIR) && \
		$(GO_BIN_PATH) $(GO_PKG_BUILD_VARS) go mod edit \
		-replace github.com/sagernet/tailscale=./third_party/tailscale
	$(call GoPackage/Build/Configure)
endef
else
define Build/Configure
endef
define Build/Compile
endef
endif

define Package/sing-box/conffiles
/etc/config/sing-box
/etc/sing-box/
endef

Package/sing-box-tiny/conffiles=$(Package/sing-box/conffiles)

define Package/sing-box/install
	$(if $(CORE_PREBUILT),$(INSTALL_DIR) $(1)/usr/bin)
	$(if $(CORE_PREBUILT),$(INSTALL_BIN) $(PKG_BUILD_DIR)/sing-box $(1)/usr/bin/sing-box)
	$(if $(CORE_PREBUILT),$(INSTALL_DIR) $(1)/usr/share/sbproxy)
	$(if $(CORE_PREBUILT),$(INSTALL_DATA) $(PKG_BUILD_DIR)/SBP_BUILD_INFO $(1)/usr/share/sbproxy/core-build.json)
	$(call GoPackage/Package/Install/Bin,$(1))

	$(INSTALL_DIR) $(1)/etc/sing-box
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/release/config/config.json $(1)/etc/sing-box

	$(INSTALL_DIR) $(1)/etc/config/
	$(INSTALL_CONF) ./files/sing-box.conf $(1)/etc/config/sing-box
	$(INSTALL_DIR) $(1)/etc/init.d/
	$(INSTALL_BIN) ./files/sing-box.init $(1)/etc/init.d/sing-box
endef

Package/sing-box-tiny/install=$(Package/sing-box/install)

$(eval $(call BuildPackage,sing-box))
$(eval $(call BuildPackage,sing-box-tiny))
