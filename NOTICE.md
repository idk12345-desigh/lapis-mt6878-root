# NOTICE — 第三方组件归属

本仓库的分发物中包含或派生于以下项目。各组件的许可如下。

## 源文件 source/timer.c

派生自：
- YuKongA/CVE-2026-98260 — https://github.com/YuKongA/CVE-2026-98260
  License: MIT
- 其 timer.c 改编自 woshigenm/CVE-2026-98260 的 src/uid0.c 与 src/poc.c
  License: MIT

本仓库对 timer.c 的修改（补丁 2/3/4/5/6）同样以 MIT 发布。

## 源文件 source/tools/dumpbtf.rs

基于 YuKongA/ghostlock-app 的 tools/extract_rs 结构（boot.rs / btf.rs 模块接口）。
- YuKongA/ghostlock-app — https://github.com/YuKongA/ghostlock-app
  License: Apache-2.0

本仓库新增的 dumpbtf.rs 以 Apache-2.0 发布。

## 二进制 bin/timer-fullroot, bin/timer-uid0

由本仓库修改后的 timer.c 编译而成（NDK r27c, aarch64-linux-android35-clang -static）。
因包含 MIT 代码，以 MIT 分发。

## 未包含但运行时依赖

- tiann/KernelSU — https://github.com/tiann/KernelSU
  License: GPL-2.0
  以 ksud 可执行文件 + kernelsu.ko 形式在运行时使用，**未打包进本仓库**。
  需要用户自行从官方 Release 下载 ksud（>= 3.3.1）。

## 引用但未包含代码

- Jz8Root/xiaomi-hyperos-bootloader-unlock — https://github.com/Jz8Root/xiaomi-hyperos-bootloader-unlock
  License: AGPL-3.0
  本仓库 docs/BL-UNLOCK-WALLS.md 仅引用其公开的研究结论（RPMB 魔数、seccfg 回退语义），
  **不包含其任何代码**。

## 内核 BTF 布局数据

docs/LAYOUT.md 中的结构偏移由 dumpbtf 从用户自有设备的 boot.img 导出，
不包含任何厂商专有代码。
