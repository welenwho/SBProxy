# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2022-2023 ImmortalWrt.org

include $(TOPDIR)/rules.mk

LUCI_TITLE:=SBProxy - sing-box proxy and VPN platform — AI Edition
LUCI_PKGARCH:=all
LUCI_DEPENDS:= \
	+luci-base \
	+sing-box \
	+firewall4 \
	+ip-full \
	+kmod-tun \
	+kmod-nft-queue \
	+kmod-nft-bridge \
	+curl \
	+flock \
	+jsonfilter \
	+unzip \
	+ucode-mod-digest \
	+ucode-mod-math
LUCI_EXTRA_DEPENDS:=sing-box (>=1.14.0)

PKG_NAME:=luci-app-sbproxy
PKG_VERSION:=1.0.2
PKG_RELEASE:=3
PKG_PO_VERSION:=$(PKG_VERSION)-r$(PKG_RELEASE)

define Package/luci-app-sbproxy/conffiles
/etc/config/sbproxy
/etc/sbproxy/retired-adaptive/
/etc/sbproxy/cache/
/etc/sbproxy/certs/
/etc/sbproxy/core/
/etc/sbproxy/dashboard/
/etc/sbproxy/ruleset/
/etc/sbproxy/resources/direct_list.txt
/etc/sbproxy/resources/proxy_list.txt
/etc/sbproxy/tailscale/
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
