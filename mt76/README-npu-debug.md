# 114 号诊断补丁（NPU 卸载静默失效）

## ⚠️ 千万别往 `mt76/patches/` 里放非补丁文件

这是踩过的坑，**任何**非补丁文件（说明文档、README、备份、`.orig`、`.rej`）放进去都会让编译失败。

原因在 OpenWrt 的 `include/quilt.mk` `PatchDir/Quilt`：

```sh
@for patch in $( (cd "$2" && if [ -f series ]; then filter_series series; else ls | sort; fi) ); do
    cp "$2/$patch" "$1/patches/$3";
    echo "$3$patch" >> "$1/patches/series";
done
```

`patches/` 下**没有 `series` 文件**时走 `ls | sort` —— 于是目录下每个文件都被拷进源码树并写进
quilt 的 series，随后 quilt 尝试逐个应用。Markdown 文档自然 "can't find file to patch"，
`Compile the firmware` 步骤直接 exit 1，且要跑满几十分钟才暴露。

**本仓库故意不提供 `patches/series`**：OpenWrt 在有 series 时会先 `cp series` 再追加一遍列表，
导致 series 里每个补丁重复出现两次。所以保持 "无 series、全目录即补丁" 的原始约定，
只要确保 `mt76/patches/` 下只有真正的补丁文件即可。

> 排查 CI 失败时先看这个：
> `curl -s https://api.github.com/repos/<owner>/<repo>/actions/runs/<id>/attempts/1/jobs`
> （匿名可读）能拿到失败步骤的确切名称，日志本身需要仓库写权限。

---

## 为什么要加 114

`mt76_npu_init()` 有三个失败出口，原实现全部只是 `goto` 之后 `return err`；
而调用方 `mt7915/pci.c` **忽略了返回值**：

```c
if (mt7915_npu)
    mt76_npu_init(&dev->mt76, pci_resource_start(pdev, 0), ...);
/* 没有检查返回值 */
```

于是 NPU 卸载失效时完全没有痕迹：`dmesg` 一行 NPU 相关的东西都没有，
WiFi 也照常起来。分不清是：

1. NPU 根本没编译进来，还是
2. 编译进来了但初始化失败，还是
3. 初始化成功但数据面不工作

114 给这三个出口各补一条 `dev_err`，并在绑定成功时补一条 `dev_info`。

## 怎么用

补丁已在 `mt76/patches/` 下，`sync-mt76.sh` 整目录拷贝时会一并带过去，
无需改动脚本（校验清单是白名单，114 会被归入 `另有 N 个非必需补丁`）。

重编并刷机后：

```sh
dmesg | grep -i npu
```

四种结果：

| dmesg 输出 | 含义 | 下一步 |
|---|---|---|
| `NPU bound: type=2 phy=...` | **绑定成功**，NPU 已挂上 | 问题在数据面。查 debugfs `ppe/entries`、`ppe/bind`，确认 wcid 是否已同步给 NPU |
| `NPU bind failed: airoha_npu_get() err=...` | 拿不到 NPU 设备句柄 | 见下方 errno 表 |
| `NPU bind failed: airoha_ppe_get_dev() err=...` | NPU 拿到了，PPE 没拿到 | 检查 DTS 里 wifi 节点的 `airoha,eth` phandle |
| `NPU bind failed: reserved memory init err=...` | NPU 设备拿到了，但握手失败 | 见下方 errno 表 |

## errno 对照

| errno | 值 | 含义 | 处理 |
|---|---|---|---|
| `-EPROBE_DEFER` | -517 | 依赖的平台驱动还没 probe 完 | 理论上会自动重试。若持续出现，查 `airoha-npu` platform driver 是否编译/加载 |
| `-ETIMEDOUT` | -110 | **mailbox 发出去 NPU 没应答**（等待 100 ms） | NPU 固件没跑起来或固件与 WiFi 芯片不匹配。换固件变体（`mainline` ↔ `clanker`）重编 |
| `-EINVAL` | -22 | 请求被拒 / 协议不接受 | 通常是 NPU 固件不认这套 vendor 线格式，或保留内存配置不对 |
| `-ENODEV` | -19 | DTS 里没有 `airoha,npu` 属性 | 检查 wifi 节点的 DT 属性 |

## 保留内存检查

DTS 里 `memory-region-names` 必须齐全，**顺序也要对**：

```
memory-region-names = "binary", "pkt", "tx-pkt", "tx-bufid", "ba";
```

`airoha_npu_wlan_init_reserved_memory()` 按名字查找，缺一块就失败。

核对 `.ko` 有没有真的把 NPU 编进去（没有输出代表没编）：

```sh
strings /lib/modules/*/mt7915e.ko | grep -i npu
```

## 注

若不想要这些日志，直接删掉 `mt76/patches/114-*.patch` 重编即可，
不影响 113 的功能，也不改动任何数据面代码。
