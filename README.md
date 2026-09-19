# dsh-termux（增强版）

> 在 Termux (Android arm64) 上一键安装并修补 `@deepseek-ai/dsh` CLI，让它真正能跑起来。修复：本轮运行失败flock is not supported on android-arm64 等报错。

本项目基于 [lilyco-42/dsh-termux](https://github.com/lilyco-42/dsh-termux) 改进，在原版 5 个兼容性修复的基础上，新增了 **flock / fs-local / attachment-local / ripgrep / sandbox** 等一系列补丁，并引入幂等、可检测、可自愈的补丁机制。

---

## 与原版的区别

原版 [lilyco-42/dsh-termux](https://github.com/lilyco-42/dsh-termux) 已经修复了 5 个核心问题（node-gyp OS=android、koffi API 30、sharp 编译、shebang、session-persistence 硬链接）。但在实际使用中，还有若干模块在 Android 上依然会崩。本仓库在此基础上新增 4 个补丁，并重构了补丁框架。

| # | 模块 | 原版状态 | 本版新增修复 |
|---|------|---------|-------------|
| 1 | `node-addon-system/flock.js` | ❌ 直接 `throw` 不支持 android | 替换为 no-op stub（`tryLock`/`unlock` 直接回调成功） |
| 2 | `dsh-session-persistence-jsonl` | ✅ 已修（link → rename） | 补强：确保 import 里有 `rename`，`defaultFileSystem` 也注入 `rename` |
| 3 | `dsh-fs-local` | ❌ `linkFile` 遇 EACCES 直接抛 | 捕获 EACCES 后 fallback 到 `rename()` |
| 4 | `dsh-attachment-local` | ❌ `link()` 无防护 | 包一层 try/catch，识别 EACCES |
| 5 | `dsh-tool-fs-search` | ❌ `@vscode/ripgrep` 无 android-arm64 包 | 创建假平台包（软链系统 `rg`）+ `resolveRgPath()` 加系统 `rg` fallback |
| 6 | `dsh-sandbox-local` | ❌ `PLATFORM_CHAINS` 无 android，选择器返回 `unavailable` 直接抛错 | 加 `android: []`，`selectRunner` 降级为 `passthrough`，`confine` 原样返回 argv |

原版 README 中提到的 5 个修复（node-gyp / koffi / sharp / shebang / session-persistence）本版 **全部保留**。

---

## 安装

### 方式一：克隆后运行

```bash
pkg install -y git
git clone https://github.com/eraycc/dsh-termux.git
cd dsh-termux
bash dsh-install.sh
```

### 方式二：一行命令

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/eraycc/dsh-termux/refs/heads/main/dsh-install.sh)
```

### 非交互式提供 Key

```bash
DEEPSEEK_API_KEY=sk-... bash dsh-install.sh
```

---

## 用法

```bash
bash dsh-install.sh                # 完整安装 + 打补丁
bash dsh-install.sh --patch-only   # 只打补丁（已装 dsh，更新后修复用）
bash dsh-install.sh --check        # 只检测不写；全部 OK 退出 0，否则非零
bash dsh-install.sh -h | --help    # 显示帮助
```

### 验证

```bash
dsh --version
dsh web                                   # 启动浏览器 UI
dsh --profile headless "hello"            # 跑一次任务
```

---

## 前置要求

* Termux（脚本会自动用 `pkg` 装其余依赖）
* **Android 11 (API 30) 或更新** —— `koffi` 依赖 `statx()`，编译目标为 `aarch64-unknown-linux-android30`
* 一个 DeepSeek API Key（脚本会提示输入，或从 `DEEPSEEK_API_KEY` 读取）

---

## 脚本做了什么

1. 安装依赖：`nodejs build-essential clang cmake ninja python libvips ripgrep`
2. 修补 node-gyp 的 `create-config-gypi.js`（去掉 `OS=android`，幂等）
3. 全局安装 `@deepseek-ai/dsh`，编译时 `--target=aarch64-unknown-linux-android30`
4. 用系统 `libvips` 构建 `sharp`
5. 修 `session-persistence-jsonl`：`link()` → `rename()`
6. 改 shebang 为 `node --expose-internals`
7. 修 `@vscode/ripgrep` 缺 android-arm64 平台包：建假包软链到系统 `rg` + 加 fallback
8. 打完整兼容补丁集：
   * `flock.js` 平台 stub
   * `dsh-fs-local` link EACCES 兜底
   * `dsh-attachment-local` link EACCES 防护
   * `dsh-session-persistence-jsonl` 补强
   * `dsh-tool-fs-search` ripgrep fallback
   * `dsh-sandbox-local` android passthrough
9. 交互式提示输入 `DEEPSEEK_API_KEY`，写入 `~/.bashrc`（环境变量或按键跳过则自动扫描已有 key）

所有补丁都是 **幂等** 的，重复运行脚本安全。

---

## 健壮性设计

* **Marker 检测**：每个补丁先检查是否已打，已打则跳过，避免二次破坏。
* **MISS / SKIP 显式告警**：锚点失配（上游代码变了）或文件缺失会打印 `WARN` 并以非零码退出，不会静默漏补。
* **双策略匹配**：`flock.js` 补丁先用函数级正则做主策略，失败再用精确串兜底。
* **`--check` 模式**：不写文件，仅报告哪些补丁需要打，便于 CI 或巡检。

---

## 模块与补丁速查

| 模块 | 文件 | 补丁标记 |
|------|------|---------|
| flock | `node-addon-system/lib/flock.js` | `termux-flock-stub` |
| session | `dsh-session-persistence-jsonl/lib/index.js` | `termux-publish-fallback` |
| fs-local | `dsh-fs-local/lib/index.js` | `termux-noreplace-fallback` |
| attachment | `dsh-attachment-local/lib/index.js` | `termux-hardlink-fallback` |
| fs-search | `dsh-tool-fs-search/lib/index.js` | `termux-rg-fallback` |
| sandbox | `dsh-sandbox-local/lib/index.js` | `termux-sandbox-passthrough` |

---

## 常见问题

**Q: 升级 dsh 后补丁失效了？**
A: 运行 `bash dsh-install.sh --patch-only`。如果上游改了代码导致锚点失配，脚本会打印 `MISS` 并退出，此时需要对照上游更新补丁锚点。

**Q: 沙箱没了会不会不安全？**
A: Android 上本来就没有可用的沙箱后端（`bwrap`/`landlock`/`seatbelt`/`windows-acl` 都不适用），本补丁把 `unavailable` 抛错改成 `passthrough` 降级，命令会以当前 Termux 用户身份直接执行。风险等价于直接在终端跑命令。

**Q: `sharp` 编译失败怎么办？**
A: 脚本会打印 `WARN` 并继续。后续如果用到图片处理，可重跑脚本或手动进 `$DSH_LIB/node_modules/sharp` 执行 `node-gyp rebuild --directory=src`。

---

## 致谢

* 原版脚本：[lilyco-42/dsh-termux](https://github.com/lilyco-42/dsh-termux)
* 上游 CLI：`@deepseek-ai/dsh`

---
