# SBProxy

**个人自用。** 本仓库只为作者自己的 OpenWrt / ImmortalWrt（ARM64、AMD64）路由器维护 SBProxy，公开代码仅用于自行同步与备份，不提供代理服务，也不对他人的下载、编译或安装负责。使用者须自行评估并承担网络访问、合规与安全风险。

LuCI 界面管理客户端、服务端、节点和核心；流量由 TUN 接管，Tailscale 可以跑在同一个 sing-box 进程里。

## 说明

- **代理模式**：关闭、大陆白名单、自定义路由、全局。大陆白名单支持域名、地址、端口和规则集分流。
- **节点**：订阅导入、URLTest，以及在候选组内按延迟和短下载表现智能选节点。
- **接入控制**：可按 Wi-Fi 或有线接口让部分来源不接管，其余来源继续走现有分流。
- **Tailscale**：内置在 SBProxy 的 sing-box 进程中，可以不依赖代理节点单独运行。
- **核心**：发布带本项目 Tailscale 兼容补丁的 sing-box 预编译核心。官方上游二进制不含这些补丁。

行为细节见文档：

- [TUN 接管与分流](docs/sbproxy-diversion.md)
- [代理模式](docs/sbproxy-proxy-mode.md)
- [智能选节点](docs/sbproxy-smart-selection.md)
- [接入接口分流](docs/sbproxy-ingress-policy.md)
- [独立核心构建与发布](docs/sbproxy-core.md)
- [自适应规则移除](docs/sbproxy-adaptive-removal.md)

## 软件包

| 软件包 | 版本 | 说明 | 源码来源 |
| --- | --- | --- | --- |
| `luci-app-sbproxy` | `1.0.2-r1` | SBProxy 的 LuCI 管理界面，负责代理、节点、Tailscale 与核心管理。 | [welenwho/packages](https://github.com/welenwho/packages) |
| `sing-box` | `1.14.4` | 带本项目 Tailscale 兼容补丁的 sing-box 核心，供固件打包和在线安装。 | [SagerNet/sing-box](https://github.com/SagerNet/sing-box) |

## 自动维护

CI 每天两次检查 sing-box 上游稳定版和 SBProxy 规则数据（北京时间 02:17 和 14:47），仅在发现更新时继续构建、提交和发布。软件包目录通过 Makefile 自动发现；新增或删除软件包后，构建范围和发布资产清理会自动调整。

独立 sing-box 核心按稳定版发布，最多保留 5 个版本。APK 发布按 ARM64 和 AMD64 分开维护；每个包名保留最近三个版本，并提供包含各软件包最新版的整合包。

## License

本仓库自有的 CI、脚本、文档及未另行声明的原创内容采用 [MIT License](LICENSE)。各插件、核心程序和预置第三方资源继续遵循其目录或上游项目声明的许可证。
