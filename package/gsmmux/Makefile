#
# gsmmux —— 把串口挂上内核 GSM 07.10 线路规程（n_gsm）的最小工具
#
# 为什么需要它：ImmortalWrt 25.12 的软件源里没有 ldattach，
# 而内核 n_gsm 必须由用户态 ioctl 才能启用。
#
include $(TOPDIR)/rules.mk

PKG_NAME:=gsmmux
PKG_VERSION:=1.0
PKG_RELEASE:=1

PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=local

include $(INCLUDE_DIR)/package.mk

define Package/gsmmux
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Attach a serial port to the kernel GSM 07.10 line discipline
  DEPENDS:=@LINUX_6_12
endef

define Package/gsmmux/description
  Minimal replacement for util-linux ldattach, limited to the N_GSM0710
  line discipline. Keeps the file descriptor open so the discipline stays
  attached, and exposes /dev/gsmtty* virtual channels.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_CPPFLAGS) $(TARGET_LDFLAGS) \
		-o $(PKG_BUILD_DIR)/gsmmux $(PKG_BUILD_DIR)/gsmmux.c
endef

define Package/gsmmux/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/gsmmux $(1)/usr/sbin/gsmmux
endef

$(eval $(call BuildPackage,gsmmux))
