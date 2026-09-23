# AN7581 PonWrt 云编译仓库

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
├── diy-part1.sh                         # feeds 阶段：补齐 PON 两个 feed
├── diy-part2.sh                         # config 阶段：主机名 / 时区 / 硬件卸载
└── README.md
```

## 用法

1. 新建 GitHub 仓库，把本目录内容整个推上去（`.github/` 开头的目录别漏）。
2. Actions → **Build AN7581 PonWrt** → **Run workflow**，在 `device` 下拉里选机型。
3. 约 1–2 小时后，Actions 页面右上角 Artifacts 下载固件；也会自动打 tag 发 Release。
4. 产物在 `bin/targets/airoha/an7581/`。

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
| 广东联动 UNG00A | `unionman_ung00a` | `kmod-airoha-en7572` |
| 中兴 ZN504XG-D | `znxt_zn504xg-d` | `kmod-airoha-en7572` |
| 中兴 ZN515XG-D | `znxt_zn515xg-d` | `kmod-airoha-en7572` |

## 每份配置里都带了什么

配置末尾有 6 段分类注释（`#` 开头，不影响编译），逐项标注 `[内置 =y]` / `[模块 =m]` / `[未启用]`：

1. **PON 内核驱动** — `kmod-airoha-xpon`（PON MAC）、`kmod-airoha-pon-frontend`（BOSA 抽象层 + DDM）
2. **光器件驱动** — 按机型二选一，注释里写明本机型选了哪颗
3. **PON 用户态** — `airoha-pond`（OMCI/OAM 主守护）、`airoha-ponctl`（光功率/温度查询）、`airoha-pon-debug`（抓包诊断）
4. **LuCI 界面** — `luci-app-pon`（板级身份编辑）、`luci-app-iptv`（IPTV 桥接）及中文包
5. **硬件卸载** — NPU 固件、`kmod-nft-offload`、`kmod-nf-conntrack-bridge`
6. **PHY / WiFi** — EN8811H 2.5G、RTL826x 固件、MT7916 WiFi 与 EEPROM

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
