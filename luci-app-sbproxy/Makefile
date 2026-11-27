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
PKG_VERSION:=1.0.14
PKG_RELEASE:=1
PKG_PO_VERSION:=$(PKG_VERSION)-r$(PKG_RELEASE)

define Package/luci-app-sbproxy/conffiles
/etc/config/sbproxy
/etc/sbproxy/certs/
/etc/sbproxy/ruleset/
/etc/sbproxy/resources/direct_list.txt
/etc/sbproxy/resources/proxy_list.txt
/etc/sbproxy/tailscale/tailscaled.state
/etc/sbproxy/tailscale/tailscaled.log.conf
/etc/sbproxy/tailscale/magicdns_target
endef

# /etc/sbproxy/dashboard is a link to the selected dashboard. Up to 1.0.12 the
# package also shipped the sing-box dashboard at that path, so an upgrade wrote
# it through the link into Yacd or MetaCubeXD. Drop the link before unpacking;
# sbproxy-dashboard-select recreates it after installation.
define Package/luci-app-sbproxy/preinst
#!/bin/sh
[ ! -L "$${IPKG_INSTROOT}/etc/sbproxy/dashboard" ] || rm -f "$${IPKG_INSTROOT}/etc/sbproxy/dashboard"
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
