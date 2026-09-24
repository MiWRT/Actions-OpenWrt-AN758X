# AN7581 PonWrt 云编译仓库
脚本参考有

https://github.com/VIKINGYFY/CloseWRT-CI

https://github.com/yhlh9982/Actions-OpenWrt-MT798X

源码地址：https://github.com/pbs05/ponwrt

GitHub Actions 自动编译 Airoha AN7581 PON 设备固件，源码 `pbs05/ponwrt`（ImmortalWrt + AN7581 PON 支持，内核 6.18）。

## 目录结构

```
.
├── .github/workflows/build-an7581.yml   # 工作流：下拉选机型后编译
├── configs/                             # 9 份单机型 .config
│   ├── an7581-fiberhome_hg5382a.config
│   ├── an7581-fiberhome_hg5585f-ct.config
│   ├── an7581-fiberhome_hg5585f-cu.config
│   ├── an7581-gemtek_xg2010g.config
│   ├── an7581-nokia_xg-040g-md-ubi.config
│   ├── an7581-nokia_xg-040g-tf-ubi.config
│   ├── an7581-unionman_ung00a.config
│   ├── an7581-znxt_zn504xg-d.config
│   └── an7581-znxt_zn515xg-d.config
├── diy-part1.sh                         # feeds 前：补齐 PON 两个 feed
├── diy-part2.sh                         # config 阶段：主机名 / 时区 / 硬件卸载
├── diy-part3.sh                         # feeds 后：拉取第三方插件（passwall/openclash/daed 等）
└── README.md
```

## 用法

1. 新建 GitHub 仓库，把本目录内容整个推上去（`.github/` 开头的目录别漏）。
2. Actions → **Build AN7581 PonWrt** → **Run workflow**：
   - `device`：机型，9 选 1，默认 `fiberhome_hg5585f-cu`
   - `repo_branch`：源码分支，默认 **`master`**（ponwrt 的默认分支是 master，不是 main），可填自己 fork 的分支名
   - `clean_cache`：勾选则忽略工具链缓存，全量重编
3. 约 1–2 小时后，Actions 页面右上角 Artifacts 下载固件；也会自动打 tag 发 Release。
4. 产物在 `bin/targets/airoha/an7581/`。

## 刷机与 PON 板级数据（重要）

ponwrt README 的流程：

1. 先用 **AN758x-Stock2UBI** 备份原厂 flash 并切换到 UBI 分区布局
2. 刷入 PonWrt
3. 恢复原厂校准与身份数据（二选一）：
   - U-Boot Web 界面
   - LuCI → Network → PON → Configuration → **PON board data**

各机型的备份类型不同，恢复时要对上：

| 机型 | 备份类型 | 说明 |
|---|---|---|
| 烽火 HG5382A / HG5585F-CT / HG5585F-CU | `factory` | 需先用 **FiberHome Factory** 转换，再恢复到 PonWrt 的 factory 卷 |
| 智易 XG2010G | `dsd` | 恢复到 factory 卷 |
| 诺基亚贝尔 XG-040G-MD / TF | `bosa`, `ri` | 恢复到同名卷 |
| 九联 UNG00A / 兆能 ZN504XG-D / ZN515XG-D | `reservearea` | 恢复到 factory 卷 |

不恢复板级数据，PON 光口通常无法注册。

## defconfig 与构建校验

工作流**已包含 `make defconfig`**（在「载入 .config 与 diy-part2.sh」步骤末尾），精简配置必须经它展开成完整 `.config` 才能编译。

defconfig 之后还有一步「校验 defconfig 展开结果」，会硬检查：

- 目标机型数量恰好为 1
- 光器件驱动 `en7572` / `paged-bosa` 恰好开一个
- PON 必选包全部存在：`kmod-airoha-xpon`、`kmod-airoha-pon-frontend`、`airoha-pond`、`airoha-ponctl`、`airoha-pon-debug`、`luci-app-pon`、`luci-app-iptv`
  - 包名写错时 kconfig 会**静默丢弃**，这一步能把它兜住，几十秒就报错，不用等 1–2 小时

任一项不满足则直接失败退出。

本地编译：

```bash
git clone https://github.com/pbs05/ponwrt.git && cd ponwrt
./scripts/feeds update -a && ./scripts/feeds install -a
cp configs/an7581-fiberhome_hg5585f-cu.config .config
make defconfig          # 精简配置必须跑这一步展开
make -j$(nproc)
```

## 机型与光器件驱动

光器件驱动两颗互斥，已按硬件写进每份配置，无需再改：

| 机型 | profile | 光器件驱动 |
|---|---|---|
| 烽火 HG5382A | `fiberhome_hg5382a` | `kmod-airoha-paged-bosa`（GN28L95 / UX3363） |
| 烽火 HG5585F 电信版 | `fiberhome_hg5585f-ct` | `kmod-airoha-paged-bosa` |
| 烽火 HG5585F 联通版 | `fiberhome_hg5585f-cu` | `kmod-airoha-paged-bosa` |
| 智易 XG2010G | `gemtek_xg2010g` | `kmod-airoha-en7572` |
| 诺基亚贝尔 XG-040G-MD | `nokia_xg-040g-md-ubi` | `kmod-airoha-en7572` |
| 诺基亚贝尔 XG-040G-TF | `nokia_xg-040g-tf-ubi` | `kmod-airoha-en7572` |
| 九联 UNG00A | `unionman_ung00a` | `kmod-airoha-en7572` |
| 兆能 ZN504XG-D | `znxt_zn504xg-d` | `kmod-airoha-en7572` |
| 兆能 ZN515XG-D | `znxt_zn515xg-d` | `kmod-airoha-en7572` |

## diy-part3.sh —— 第三方插件

`diy-part3.sh` 在 **`feeds install` 之后、载入 `.config` 之前**执行（顺序不能变）：它会 `rm -rf` feeds 里若干包（golang、mosdns、smartdns、xray-core 等）再 clone 新版，并把插件 clone 到 `package/custom/`。

拉完会自动再跑一次 `./scripts/feeds install -a` 修复被删目录的符号链接，并检查 `package/custom` 与 feeds 是否有同名包重复定义（有则打 warning）。

拉到的插件在 `configs/*.config` **第 12 段**，默认全部注释掉 —— 不启用就不会编译、不影响 PON 功能。要用哪个就把对应行取消注释。

### 三个已知注意点

1. **luci-theme-argon 重复**：第 7 段已启用 feeds 版本，diy-part3 又拉了一份到 `package/custom`。两处同名会冲突。想用 diy-part3 那份，需在 `diy-part3.sh` 里加一行 `rm -rf feeds/luci/themes/luci-theme-argon`。
2. **golang 被替换为 sbwml 26.x**：如果有你启用的包依赖 golang，会走新版；当前 PON 组件不依赖它。
3. **luci-app-daed 需要内核 BTF**：启用时除取消注释外，还要打开 `CONFIG_KERNEL_DEBUG_INFO_BTF` 等（第 12 段注释里列全了），否则 eBPF 程序加载不了。

## 分支与源码

仓库 `pbs05/ponwrt` 只有 1 个分支 **`master`**（无 `main`），最新提交 `18d7b41`。`REPO_URL` 在 `.github/workflows/build-an7581.yml` 的 `env` 里硬编码为 `https://github.com/pbs05/ponwrt.git`，想换成自己的 fork 改这一行即可。

分支通过 `repo_branch` 输入项选择，默认 `master`。克隆前会先用 `git ls-remote --heads` 校验分支是否存在，填错时日志会打印该仓库实际可用的分支列表，不会默默卡住。

## 配置格式说明

`configs/*.config` 是**精简配置（diffconfig）**：只列出相对 target 默认值有改动、或需要显式指定的项，其余交给 `make defconfig` 按 target 默认展开。

每份约 209 行（全量展开后是 9000 行）。好处是改起来一眼能看全，坏处是**不能直接用**——必须先跑 `make defconfig`。工作流里已经包含这一步，本地编译也要记得跑。

分 11 段，和 MT798X 那套 `.config` 的组织方式一致：

| 段 | 内容 |
|---|---|
| DEVICES | 目标机型 profile |
| 基础构建选项 | target / 内核 6.18 / rootfs / debugfs |
| 1. PON 内核驱动 | `kmod-airoha-xpon`、`kmod-airoha-pon-frontend` |
| 2. 光器件驱动 | 按机型二选一，注释写明本机型选了哪颗 |
| 3. PON 用户态 | `airoha-pond`（OMCI/OAM 主守护）、`airoha-ponctl`（光功率/温度查询）、`airoha-pon-debug`（抓包诊断） |
| 4. PON/IPTV LuCI | `luci-app-pon`（板级身份编辑）、`luci-app-iptv`（IPTV 桥接）+ 中文包 |
| 5. 硬件卸载 | NPU 固件、`kmod-nft-offload`、`kmod-nf-conntrack-bridge` |
| 6. 有线 PHY / WiFi | EN8811H 2.5G、RTL826x 固件、MT7916、wpad-openssl、fitblk |
| 7. LuCI 界面 | luci + 各 mod + argon 主题 + 中文包 |
| 8. 基础服务与工具 | dnsmasq-full、pppoe、iperf3、tcpdump、i2c-tools、uboot-envtools 等 |
| 9. 存储 / USB / eMMC / M.2 | **默认全部注释掉**，按需取消注释 |
| 10. 网络 / 内核杂项 | cgroup、BBR、nft/ipt 增强、zram |
| 11. MISC | 编译强化选项、fastpath 取舍 |

每段里的 `=y` / `=m` 后面带中文行内注释，说明这个包干什么用。

## PON 协议支持情况

`kmod-airoha-xpon` 上游给出的状态：

| 模式 | 状态 |
|---|---|
| XG-PON | ✅ 已测试 |
| 10G-EPON 10G/1G | ✅ 已测试 |
| XGS-PON | ❓ 未测试 |
| 10G-EPON 10G/10G | ❓ 未测试 |
| GPON | ❌ 未实现 |
| EPON 1G/1G | ❌ 未实现 |

## 注意事项

- **构建时长**：单机型 1–2 小时（冷启动含工具链），不会撞 Actions 6 小时上限。换机型重编可复用工具链缓存。
- **缓存**：按源码 commit hash 缓存 `staging_dir`。源码更新后想全量重编，勾 Run workflow 里的 `clean_cache`。
- **刷机**：首次建议先 initramfs 引导再 sysupgrade；跨版本升级不要保留配置，刷完按住 reset 8 秒复位一次。
- **硬件卸载**：装完后要在 firewall 里确认 `flow_offloading_hw` 为 1，否则 PPE 表项建不起来。
- **PON 光口**：需要 pond 起来并完成 OMCI/OAM 注册；注册失败时用 `airoha-pon-debug` 抓包，配合 `ponctl` 看光功率和 ONU 状态。
