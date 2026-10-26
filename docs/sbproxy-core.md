# SBProxy 独立核心构建与发布

核心源码、编译配置和 Tailscale 补丁统一在 `welenwho/packages` 维护。
不使用也不修改 `singbox-v2ray-api` 的产物。

当前内置 Tailscale 集成依赖 `tailscale-patches/010-restore-linux-policy-routing.patch`：
它启用 Linux 策略路由检测，并在接口启停时安装、清理策略规则，使远端路由进入表 52。
SBProxy 用该表实现选定子网的策略控制，不能仅替换状态页中的表号。
未应用此补丁的 SagerNet Tailscale 依赖会保持 `ipRuleAvailable=false`，
把路由写入 `main`；即使节点能 ping 通、核心带 `with_tailscale` 标签，
也不代表兼容当前 OpenWrt 集成。`main` 是该内嵌版本的原生行为，并非路由表损坏。
为保留“只接受勾选的远端子网”，稳定版和 Alpha 版均应用这项补丁。

若状态页提示无法检查系统路由，检查 `ip -4 rule show`、
`ip -4 route show table 52` 和 `ip -4 route show table main dev tailscale0`。
表 52 不存在而远端路由在 `main` 时，先核对核心来源及补丁，勿手动搬移运行中核心的路由。
恢复带补丁核心后，确认 `tailscale-sync` 持续运行、表 52 及选定子网规则均已恢复。

## 发布与版本

每日维护队列每天两次调用 `Update-Sing-Box.yml`（北京时间 02:17 和 14:47），
分别检查上游最新稳定版和 Alpha 版，以及本仓库补丁、包定义、构建脚本的指纹。
未发布的版本才编译，已发布的版本不会覆盖。也可手动运行该工作流，选择
`channel=stable`（默认）或 `channel=alpha`。仅发布完整 SBProxy 核心，
不增加 standard/minimal 配置。

- Release：`sbproxy-core-v1.14.3`（示例）。发布名只用上游版本，不附加 `-rN`。
- Alpha Release：`sbproxy-core-v1.15.0-alpha.12`（示例），标记为 GitHub prerelease，
  不设置 Latest，不改稳定版固件锁定文件，也不进入滚动 APK 发布。
- Alpha 资产沿用上游版本名，如 `sing-box-1.15.0-alpha.12-arm64.apk`；
  APK 元数据使用 `1.15.0_alpha12-r1`，核心输出仍为 `1.15.0-alpha.12`。
- 架构：ARM64（ARMv8.0）和 AMD64（x86-64-v1）。
- `sing-box-1.14.3-linux-arm64.tar.gz`：供固件打包的预编译核心。
- `sing-box-1.14.3-arm64.apk`：供当前 ImmortalWrt APK 系统在线安装。
- `core-manifest.json`、`SHA256SUMS`：架构、核心版本、源码提交、补丁、编译信息和校验值。
- `sbproxy-core-build-source.tar.gz`：该版本的构建脚本与补丁快照；上游源码固定为清单中的 Git tag，Tailscale 依赖由该 tag 的 go.mod 确定。

每个上游版本只发布一次，标签和标题都不带 `-rN`。已发布的 Release 不覆盖，
也不再为同一版本追加修订号。2026-10 之前已经发布的 `sbproxy-core-v1.14.x-rN`
标签保持不变，在线回滚仍可下载。两种架构都成功、核心功能及静态链接检查通过后
才发布；稳定版标为仓库 Latest。稳定版和 Alpha 各保留最新 5 个
Release；当前固件锁定版本即使更旧也会保留。补丁无法应用时任务失败，不跳过补丁，
也不推进固件版本。

## 固件编译

发布成功后，工作流提交 `Makefile` 与 `core-prebuilt.mk` 中的精确版本、架构 SHA-256。
普通完整包构建下载该固定压缩包，不构建 Go 工具链或 sing-box；当前 SDK 自行打包
APK/IPK 并保留其服务文件、依赖、包数据库。OpenWRT-CI 已引入本仓库的 `sing-box`
包定义，更新 feed 后即可生效，不需要跨 SDK 直接导入 APK。

首次发布完成前、不支持的架构、tiny/custom 构建继续源码编译。
可通过 `CONFIG_SING_BOX_BUILD_FROM_SOURCE=y` 强制源码编译。
独立核心 CI 使用 `SBPROXY_CORE_SOURCE_BUILD=1`，生成静态链接、基线 CPU 核心，
APK 内二进制与压缩包内二进制来自同一次构建。
下载失败或哈希错误直接报错，不回退 latest，也不悄悄改为源码构建。

## 在线升级与回滚

升级、重装和回滚以独立后台任务执行，RPC 只提交任务并立即返回任务 ID。
页面每 2 秒串行查询进度，显示下载、校验、准备恢复包、安装、重启及健康检查阶段。
切换时的短暂断网不会直接报升级失败；连接恢复后根据同一任务的最终结果判断，
不能仅凭已安装版本判断成功。浏览器关闭或刷新不会终止后台任务；重新打开核心管理
会恢复正在运行的任务，并可查看最近一次任务结果。提交回应丢失时只查询原任务，
不自动重复安装。连续 30 分钟仍无法确认时提供再次查询入口，不宣称失败。

进度和最近一次结果保存在独立的 `/var/run/sbproxy-core-manager` 目录，
不随 SBProxy 服务重启清理；系统重启后不保留。进程异常退出、系统重启或结果已被
新任务替换时显示“结果未确认”，需检查实际核心状态及日志后再决定操作。
核心管理日志仍在 `/var/run/sbproxy/core-manager.log`，校验和自动恢复保护不变。

LuCI 核心管理读取版本化 Release 的历史列表，允许升级、重装或选择旧版回滚。
稳定版优先排列，Alpha 明确标识并手动选择；两种通道都执行相同的校验和回滚流程。
仅接受本仓库匹配架构的资产，使用 GitHub SHA-256 校验、APK 名称/版本/架构校验、
完整编译标签与 Tailscale 路由 API 检查，并校验当前客户端/服务端配置。
1.14 之前的核心不展示；版本达到最低要求也不意味着兼容当前配置，实际检查失败会阻止切换。

手动回滚不依赖已保存的本地回滚包。每次切换先从仓库下载当前版本的应急恢复包，
避免新核心启动失败后还要联网恢复。首次从旧固件迁移时，应急包可从原有
`apk-packages-arm64/amd64` 发布获取；如果两处均已无当前版本，则拒绝不安全切换。
离线时不能下载历史版本，但切换过程中已准备的应急包仍可用于自动恢复。

在线安装目前针对支持的 ARM64/AMD64 APK 系统；其他系统可复用预编译压缩包进行
固件打包，不承诺不同 OpenWrt 分支的 APK 依赖一定兼容。

## 验证

```
python3 sing-box/tests/test-core-release.py
sh sing-box/tests/static-tailscale-route-api.sh
sh luci-app-sbproxy/tests/static-core-management.sh
```

实际双架构源码编译及 QEMU 核心检查在 GitHub Actions 中执行。

在线切换前记录本次应运行的客户端/服务端实例及监听端口。切换后检查对应核心进程
（含 ujail 子进程）与它持有的 TCP/UDP socket，连续 5 次 PID/启动时间稳定才通过。
日志清理、接口同步等辅助进程不能代替核心健康状态；失败仍进入自动恢复流程。
