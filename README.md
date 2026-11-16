# lapis-mt6878-root

**CVE-2026-98260 内核提权工具包 — Redmi Note 15 Pro 5G (`lapis` / MediaTek MT6878)**

在 **bootloader 锁定** 的设备上拿到 **真实 root**（`u:r:ksu:s0` + 全部 capability + KernelSU LKM），
**不需要**解锁 BL、**不需要** BROM/EDL、**不需要** 签名 DA、**不需要** 社区解锁配额。

---

## 支持范围

| 项目 | 值 |
|---|---|
| 设备 | REDMI Note 15 Pro 5G（型号 `25080RABDG`） |
| 代号 | `lapis` / `lapis_global` |
| SoC | MediaTek **MT6878**（Dimensity 7300） |
| 内核 | `6.1.129-android14-11-g6b7a9f51c088-ab13432504` |
| KMI | `android14-11`（KernelSU LKM 名：`android14-6.1`） |
| 系统 | HyperOS 2.0 `OS2.0.203.0.VPPMIXM` / Android 15 |
| 区域 | Global / HK |
| BL 状态 | 锁定（`flash.locked=1`），全程未改动 |

> ⚠️ profile 按 `uname -r` **整串精确匹配**。内核版本不同会拒绝运行，需要重新生成 profile（见下文）。

---

## 实测结果

```
su -c id   →  uid=0(root) gid=0(root) context=u:r:ksu:s0
CapEff     →  000001ffffffffff          （全部 41 个 capability）
/proc/modules → kernelsu 225280 0 - Live (O)
/data      →  可读可写
BL         →  flash.locked=1, verifiedbootstate=green（未改动）
```

---

## 快速开始

### 依赖

- Linux / macOS / Windows + `adb`
- 手机：USB 调试已开、**已解锁屏幕**、`/data/local/tmp` 可写
- `ksud` **3.3.1 或更高**（旧版 3.1.0 不支持 `--kmi`）

### 步骤

```bash
# 1. 下载官方 ksud（约 6.4 MB）
curl -L -o ksud \
  https://github.com/tiann/KernelSU/releases/download/v3.3.1/ksud-aarch64-linux-android

# 2. 推送
adb push bin/timer-fullroot /data/local/tmp/timer
adb push ksud             /data/local/tmp/ksud
adb shell "chmod 755 /data/local/tmp/timer /data/local/tmp/ksud"

# 3. 执行（约 40 秒，期间屏幕会闪一下，不要动手机）
adb shell "cd /data/local/tmp && ./timer fake"

# 4. 验证
adb shell "su -c id"
```

Windows 用 `scripts\root.bat`（会自动完成上述流程）。

### 一键脚本

```bash
bash scripts/root.sh          # Linux / macOS
scripts\root.bat              # Windows
```

---

## 工作原理

```
adb shell (uid 2000, u:r:shell:s0)
   │
   │  CVE-2026-98260 — POSIX CPU timer UAF（de_thread 清理路径）
   │  通过 pselect6 栈叠加伪造 rt_mutex_waiter，利用 rb-tree 重平衡实现内核任意写
   ▼
① 零写真实 cred              → uid=0（受限：CapEff=0）
② 改写 task->cred 指向伪造 cred（full caps + SELinux SID_KERNEL）
③ 零写 selinux_state.enforcing → SELinux 变 Permissive
④ ksud late-load —— 加载 lkm-aarch64-android14-6.1_kernelsu.ko
   ▼
KernelSU 激活 → su = u:r:ksu:s0 → 完整 root
```

失败时进程会 park 并持有僵尸/假 cred 页；**不要 kill，重启是唯一安全清理方式**。

---

## 相对上游的 4 处修改

上游 [`YuKongA/CVE-2026-98260`](https://github.com/YuKongA/CVE-2026-98260) 只支持 `6.12.69-android16-6`。
本工具包使其在 `6.1.129` 上可用。**详细说明见 [`docs/PATCHES.md`](docs/PATCHES.md)。**

| # | 文件 | 修改 | 为什么必须 |
|---|---|---|---|
| 1 | `timer-extract/src/derive.rs` | `task_struct` 分配点回退链：`copy_process` → `dup_task_struct` → `alloc_task_struct_node` → `kernel_clone` | 6.1 的 `kmem_cache_alloc_node(task_struct_cachep)` 在 `dup_task_struct`，未内联进 `copy_process` |
| 2 | `timer.c` `wait_zombie()` | 超时 `2000×200µs (0.4s)` → `60000×200µs (12s)` | **最关键**。0.4s 在 BSP 内核上不够，plant 永远判定失败 |
| 3 | `timer.c` `spray_thread()` | phase0 循环增加 `g_stop_spray` 退出条件 | 失败分支 `pthread_join` 永久死锁 |
| 4 | `timer.c` fake cred 构造 | 指针偏移 `-8`；caps 循环 `c[6..10]` → `c[5..9]` | 6.1 的 `cred.usage` 是 `atomic_t`(4B) 而非 `atomic_long_t`(8B)，整体前移 8 字节 |

第 4 点是用本仓库的 **`dumpbtf`** 工具从内核 BTF 直接读出来的，不是猜的。

---

## 已知限制

### 1. 临时 root —— 重启即失效

KernelSU 是**运行时加载的内核模块**，模块活在 RAM 里。冷启动必然丢失。

| 场景 | root |
|---|---|
| 软重启 `su -c 'stop; start'` | ✅ 保留 |
| 正常重启 / 关机 | ❌ 需重跑（约 40 秒） |

### 2. 无法从 root 反推 BL 解锁

即使有完整 root，仍解不了 bootloader。三道墙：

1. **seccfg 的 hash 用硬件 SEJ 密钥**（`AES_HW_KEY`，烧在 Security Engine 里，不可读）
2. **RPMB 需要认证密钥**（`/dev/rpmb0` 裸读返回 `EINVAL`）
3. **LK 分区受 preloader 签名校验**（改了会无法启动，且 BROM 被 DAA 封死无法救砖）

详见 [`docs/BL-UNLOCK-WALLS.md`](docs/BL-UNLOCK-WALLS.md)。

### 3. 假 cred 的 euid 是垃圾值

`c[2]` 覆盖了 `sgid/euid`，日志里会看到 `euid=-127` 之类的值。不影响 root 交接（KernelSU 走 `u:r:ksu:s0`），但不要依赖该进程的 `euid`。

---

## 目录

```
bin/
  timer-fullroot      ARM64 静态二进制 — 完整 root（推荐）
  timer-uid0          ARM64 静态二进制 — 仅 uid=0（轻量，CapEff=0）
source/
  timer.c             已打全部补丁的 exploit 源码
  kbuilds/
    6.1.129-*.h       本内核自动生成的 profile
  tools/
    dumpbtf.rs        BTF 结构布局导出工具（Rust）
docs/
  PATCHES.md          4 处修改的完整说明
  LAYOUT.md           本内核 BTF 实测结构布局
  BL-UNLOCK-WALLS.md  BL 解锁的三道墙分析
  seccfg_sample.bin   本机 seccfg 头部样本（64B，供参考）
scripts/
  root.sh             Linux / macOS 一键
  root.bat            Windows 一键
```

---

## 为新内核生成 profile

```bash
cd source/tools                  # 或上游仓库的 tools/extract
cargo build --release
./target/release/timer-extract /path/to/boot.img --add
```

需要 `boot.img`（或原始 `arm64 Image`）。工具会输出 `vulnerable YES|NO` 并生成
`kbuilds/<uname -r>.h`，退出码 `0=漏洞存在 / 3=已修补 / 1=出错`。

### 导出内核结构布局

```bash
cargo build --release --bin dumpbtf
./target/release/dumpbtf boot.img cred task_security_struct
```

移植到其它内核时用它核对 `security` / `user_ns` 等字段的真实偏移。

---

## 致谢

| 项目 | 许可 | 用途 |
|---|---|---|
| [YuKongA/CVE-2026-98260](https://github.com/YuKongA/CVE-2026-98260) | MIT | 本工具包的基础 |
| [woshigenm/CVE-2026-98260](https://github.com/woshigenm/CVE-2026-98260) | MIT | `timer.c` 原始实现 |
| [YuKongA/ghostlock-app](https://github.com/YuKongA/ghostlock-app) | Apache-2.0 | `tools/extract`（BTF / kallsyms / 反汇编） |
| [tiann/KernelSU](https://github.com/tiann/KernelSU) | GPL-2.0 | `ksud` 与 LKM |
| [Jz8Root/xiaomi-hyperos-bootloader-unlock](https://github.com/Jz8Root/xiaomi-hyperos-bootloader-unlock) | AGPL-3.0 | RPMB/seccfg 研究（本仓库仅引用分析结论，未包含其代码） |

本仓库的补丁与文档部分以 MIT 发布。

---

## 免责声明

仅供**自有设备的安全研究**使用。使用前请确认你拥有设备的所有权。
提权过程涉及内核写原语，可能导致重启、数据损坏或设备异常；请自行承担风险并提前备份。
