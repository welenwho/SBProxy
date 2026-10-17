# 自适应路由退役

从 1.0.1-r14 起移除自适应路由页面、后台学习探测服务、RPC、探测端口与动态学习规则。不再因为连接慢或失败自动改变直连/代理分流规则。

1.0.1-r28 新增可选的[智能选节点](sbproxy-smart-selection.md)，仅在用户配置的代理候选组内选优，不恢复上述直连/代理学习规则。

- 大陆白名单、全局代理、自定义路由继续使用各自原有的规则与默认出口。
- 规则分流、URLTest 自动选节点、Tailscale、入口接口绕过均保留。
- Dashboard 的 LAN/显式 Tailscale 接口限制和至少 16 字符密钥校验保留。
- 升级脚本通过 procd 停止旧探测服务，移除其启动链接。旧配置及学习记录移到 `/etc/sbproxy/retired-adaptive/backup.*/`，不再读取，备份目录继续随配置保留。
- 软件包热升级时，若正在运行的核心仍含自适应规则，重启 SBProxy 使新配置生效，网络可能短暂中断；不会主动启动原本已停止的服务。
- 旧 HomeProxy 的主配置迁移仍保留，但不再复制其自适应配置和学习记录。

回归测试：`sh luci-app-sbproxy/tests/test-retire-adaptive.sh`，以及 `node luci-app-sbproxy/tests/test-no-adaptive.mjs`。升级脚本可使用 `SBPROXY_RETIRE_ROOT` 在隔离目录测试，不连接真实 procd、不重启实际服务。

`tests/test-retire-adaptive-live.mjs` 用模拟 procd 验证热升级的停止、重启及失败路径；`tests/router-no-adaptive.sh` 在 OpenWrt 容器中验证七种配置场景、残留旧配置无效和 URLTest 迁移幂等性。共享模块导出函数补齐结束分号，以兼容标准 OpenWrt ucode。
