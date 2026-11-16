# 为什么有完整 root 也解不了 Bootloader

拿到 `u:r:ksu:s0` + 全部 capability 之后，仍**无法**解锁 bootloader。
以下是实测的结论，不是推测。

---

## 结论速览

| 尝试 | 结果 |
|---|---|
| `dd` 读 seccfg | ✅ **可以**（root 能读 `/dev/block/by-name/seccfg`） |
| `dd` 读 `/dev/rpmb0` | ❌ `read error: Invalid argument`（需协议 + 密钥） |
| 本地计算 seccfg hash | ❌ `AES_HW_KEY` 烧在 SEJ 内，不可读 |
| 改 LK 分区 | ❌ preloader 签名校验 → 无法启动（BROM 被 DAA 封死，救不回） |
| `fastboot oem setmtklks 3` | ❌ `Token is empty, failed.`（需小米 RSA 签名 token） |
| `fastboot oem unlock` | ❌ `Start unlock flow` → `Failed to unlock the device` |
| `fastboot oem chkmtklks` | ✅ 可读：`seccfg_state is 1` |

---

## 墙 1 — seccfg 的 hash 用硬件密钥

### seccfg v4 结构（本机实测）

```
+0x00  u32 magic         = 0x4D4D4D4D  "MMMM"
+0x04  u32 version       = 4
+0x08  u32 size          = 0x3c
+0x0c  u32 lock_state    = 1        ← 1=DEFAULT/锁定, 3=UNLOCK, 4=LOCK
+0x10  u32 dm_verity_state
+0x14  u32 sboot_runtime
+0x18  u32 endflag       = 0x45454545  "EEEE"
+0x1c  u8  hash[32]                  ← 位于 size - 0x20
```

分区大小 8 MiB，有效结构仅前 0x3c 字节。

### hash 算法

```python
data     = pack("<IIIIIII", magic, ver, size, lock_state,
                dm_verity_state, sboot_runtime, 0x45454545)
dec_hash = sha256(data)
enc_hash = sej_sec_cfg_XXX(dec_hash, encrypt=True)
```

mtkclient 支持多种 hwtype，逐一验证**本机为 HW 型**：

| hwtype | 实现 | 本机是否匹配 |
|---|---|---|
| `SW` | 纯软件 AES-256-CBC<br>key `25A1763A21BC854CD569DC23B4782B63`<br>iv `57325A5A125497661254976657325A5A` | ❌ 不匹配 |
| `HW` | HACC 硬件（`custom_sej_hw`） | 需硬件 |
| `V2` | `sej_sec_cfg_hw` | 需硬件 |
| `V3` / `V4` | `hw_aes128_cbc_encrypt`（`AES_HW_KEY`） | 需硬件 |

实测 SW 校验：

```
stored hash : 440a6508a3d3ab5626028eb88ad696ea1b6cb58bb52455832e8d6dfccf9ad507
sha256(data): 7ec2e74193dbe969bd1e899c0e5a9d9bdef43da366aa7dab733cc1d111455422
AES-CBC(sha): be83a6c7969908d7a61d11e93a3984a17a970c722f6318c3371da3a52f038f44
→ 不匹配
```

`AES_HW_KEY` 是 SEJ 内部密钥，**任何软件都无法推导**。所以就算改了 `lock_state = 3`，
也生成不出合法 hash。

---

## 墙 2 — RPMB 需要认证密钥

```bash
$ su -c 'dd if=/dev/rpmb0 of=/data/local/tmp/x bs=512 count=4'
dd: /dev/rpmb0: read error: Invalid argument
```

RPMB 不是普通块设备：

- 节点 `/dev/rpmb0`，SELinux 标签 `u:object_r:teei_rpmb_device:s0`（Trustonic TEE）
- 访问需要走 RPMB 协议帧 + 32 字节认证密钥
- 密钥在 TEE 内，用户态拿不到

即使能读，按 [Jz8Root 的研究](https://github.com/Jz8Root/xiaomi-hyperos-bootloader-unlock)，
还需要在正确扇区**擦除魔数 `Jz8PNRUF`**，而写 RPMB 更需要密钥。

> 本机 `fastboot oem chkmtklks` 返回 `seccfg_state is 1`（DEFAULT / RPMB 未初始化），
> 意味着 LK 可能走 seccfg 回退路径 —— 但墙 1 仍然拦在前面。

---

## 墙 3 — LK 受 preloader 签名校验

LK（Little Kernel）是 bootloader 主体，位于 `lk` / `lk2` 分区。

- LK 二进制里确实存在 `SHA256` 代码 + `seccfg` + `lock_state` 字符串 → 存在完整性校验
- 修改 LK 会导致 preloader 验签失败 → **设备无法启动**
- 救砖需要 BROM/EDL，而 MT6878 的 BROM 是 **DAA 熔断**的：
  ```
  SBC=True SLA=True DAA=True
  Mem read auth=True / Mem write auth=True / Cmd 0xC8 blocked=True
  → mtkclient: "Auth file is required"
  ```
  需要小米为本机单独签名的 auth 文件，公开渠道不存在。

**这是真实的变砖风险，不可尝试。**

---

## 那么永久 root 靠什么

只有官方路径：

1. 小米社区申请解锁配额（Global 版：ME → Unlock bootloader → Apply for unlocking）
2. 配额重置于每日 **00:00 (GMT+8)**，社区内卷，需抢
3. 抢到 → 开发者选项绑定账号和设备 → 等待强制期（168h / 7 天）
4. 期满 → Mi Unlock Tool 解锁
5. 解锁后把 Magisk patch 进 `init_boot` → **永久 root**

---

## 附：本机 seccfg 样本

`docs/seccfg_sample.bin` 为前 64 字节（结构体 0x3c + 填充），仅供对照格式：

```
4d 4d 4d 4d 04 00 00 00 3c 00 00 00 01 00 00 00
00 00 00 00 00 00 00 00 45 45 45 45 44 0a 65 08
a3 d3 ab 56 26 02 8e b8 8a d6 96 ea 1b 6c b5 8b
b5 24 55 83 2e 8d 6d fc cf 9a d5 07 00 00 00 00
```
