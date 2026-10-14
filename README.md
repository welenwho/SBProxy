# imm-packages · AI Edition

这是一个个人自用的 OpenWrt/ImmortalWrt 插件分享仓库。插件以实际使用需求为导向，并借助 AI 完成维护、适配、审计和自动化，因此统一标记为 **AI Edition**。

## 插件简介

| 插件 | 版本 | 简介 | 源码来源 |
| --- | --- | --- | --- |
| `luci-app-gecoosac` | `20260812-r4` | gecoosac 核心的 LuCI 管理界面与 OpenWrt 集成。 | [welenwho/packages](https://github.com/welenwho/packages) |
| `luci-app-sbproxy` | `1.0.1-r26` | sing-box 代理与 VPN 平台，支持可选的内置 Tailscale。 | [welenwho/packages](https://github.com/welenwho/packages) |
| `luci-app-wolultra` | `20260812-r3` | wol 功能的 LuCI 管理界面与 OpenWrt 集成。 | [welenwho/packages](https://github.com/welenwho/packages) |

## 核心与依赖来源

| 软件包 | 版本 | 源码来源 |
| --- | --- | --- |
| `gecoosac` | `2.2.20251015-r1` | [welenwho/packages](https://github.com/welenwho/packages) |
| `sing-box` | `1.14.2` | [SagerNet/sing-box](https://github.com/SagerNet/sing-box) |

## 自动维护

CI 每天两次检查受维护的上游项目（北京时间 02:17 和 14:47），仅在发现更新时继续构建、提交和发布。软件包目录通过 Makefile 自动发现；新增或删除软件包后，构建范围和发布资产清理会自动调整，LuCI 插件列表也会自动更新。

独立 sing-box 核心按稳定版发布，最多保留 5 个版本。APK 发布按 ARM64 和 AMD64 分开维护；每个包名保留最近三个版本，并提供包含各软件包最新版的整合包。

## License

本仓库自有的 CI、脚本、文档及未另行声明的原创内容采用 [MIT License](LICENSE)。各插件、核心程序和预置第三方资源继续遵循其目录或上游项目声明的许可证。
