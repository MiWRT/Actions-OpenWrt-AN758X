# 自定义补丁

把补丁放进**对应的子目录**即可，构建时按目录自动应用。
不用补丁时留空目录就行，不会有任何影响。

> 📌 三个子目录当前均为**空仓库状态**（各有一个 `.gitkeep` 占位）。
> Git 不跟踪空目录，所以占位文件是必需的 —— 少了它，目录在本地建得出来、
> 却永远不会进版本库，CI 里表现为「补丁目录不存在，跳过」。

| 目录 | 打给谁 | 何时生效 | 典型用途 |
|---|---|---|---|
| `ponwrt/` | ponwrt 源码树根目录 | step 4.5，clone 后立刻 `git apply` | DTS、package Makefile、脚本、默认值 |
| `kernel/` | 内核源码 | step 4.5 复制到 `target/linux/airoha/patches-*/`，编内核时由 quilt 应用 | 驱动补丁、`airoha_npu.c`、网络子系统 |
| `clanker/` | ClankerNPU 固件源码 | step 5.5，拉源码后、编译前（`npu_fw=clanker` 时） | 改固件行为、调参数 |

## 当前加载了什么

跑一次 CI，在 **Apply custom patches** 这一步的日志开头会打印
`===== patches/ 目录内容 =====`，列出本目录所有文件；随后逐行给出每个补丁的结果：

| 日志 | 含义 |
|---|---|
| `✅ xxx.patch` | 本次新应用成功 |
| `⏭  已应用，跳过: xxx.patch` | 反向 apply 检测命中，此前已打过（重跑 CI 不会重复打） |
| `❌ xxx.patch` | 应用失败，下面会跟 `git apply --verbose` 的诊断输出 |
| `补丁目录不存在，跳过` | 目录没随 Git 进来 —— 检查是不是少了 `.gitkeep` |
| `补丁目录为空，跳过` | 目录在，但没有 `.patch` / `.diff` |

**没有任何输出行**＝本目录没补丁，本次编译没有源码改动。

> mt76 的 NPU 补丁**不走这里**。它们在仓库根目录的 `mt76/patches/`，
> 由 `scripts/install-mt76.sh` 在 step 4.6 随整包替换装进 `package/kernel/mt76/`，
> 再由 quilt 在解压 mt76 源码后应用。详见主 [README.md](../README.md)
> 的「mt76 无线驱动（WiFi NPU 卸载）」一节。

## 控制开关

| 输入项 | 默认 | 说明 |
|---|---|---|
| `apply_patches` | `true` | 总开关，`false` 则三个目录全跳过 |
| `patch_strict` | `true` | 补丁打不上时立刻失败；`false` 只警告继续编 |

目录为空或不存在 → 自动跳过，不报错。

## 规则

1. **只收 `.patch` / `.diff`**，按文件名字母序应用。用数字前缀控制顺序：
   ```
   001-fix-a.patch
   010-fix-b.patch
   ```
2. **路径必须是 `-p1`**（`a/path/to/file` → `path/to/file`）。
   用 `git diff` 生成的默认就是 `-p1`：
   ```sh
   git -C /path/to/ponwrt diff > 001-my-change.patch
   cp 001-my-change.patch patches/ponwrt/
   ```
3. **已应用过的会自动跳过**（用反向 apply 检测），重跑 CI 不会重复打。
4. `kernel/` 下建议用 **`9xx-` 前缀**（如 `950-npu-fix.patch`），
   保证排在官方补丁之后应用，否则可能被官方补丁覆盖或冲突。没有数字前缀会警告。
5. 失败时会打印 `git apply --verbose` 的详细输出，常见原因：
   - 前缀不对（需要 `-p1`）
   - 上游改过这些文件 → 重新生成补丁
   - 补丁放错了目录（三者选一）

## 顺序提醒

`patches/ponwrt/` 在 **step 4.5** 应用，而 NPU 的 DTS 修改为 **step 5**
（`apply-npu-dts.sh` 用 sed 往 DTS 插 include）。

所以：**如果你的补丁也改了同一个 DTS 文件，补丁先打、sed 后跑**。
若补丁把 `#include "an7581.dtsi"` 那行改没了，`apply-npu-dts.sh` 会找不到锚点并打警告
（不会失败，但内存区就没补上）。这种情况建议直接把 NPU 内存区写进你自己的补丁里，
并把 `npu_wlan_mem` 设为 `false`。
