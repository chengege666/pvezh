# PVE 镜像转换与部署工具

Proxmox VE 自动化部署脚本，用于快速导入、转换并部署 OpenWrt、ImmortalWrt 等 Linux 路由系统镜像。

- GitHub: https://github.com/chengege666/pvezh
- Gitee: https://gitee.com/chengege666/pvezh

## 功能

- **VM 虚拟机部署** — 创建新虚拟机或注入到现有虚拟机
- **LXC 容器部署** — 从模板或 .img 镜像提取 rootfs 创建容器（实验性）
- **自动镜像扫描** — 扫描当前目录、`/var/lib/vz/template/iso/`、`/var/lib/vz/template/cache/`
- **支持格式** — `.img`、`.img.gz`、`.qcow2`、`.raw`、`.tar.gz`、`.tar.xz`、`.tar.zst`
- **配置摘要** — 执行前显示完整配置并确认

## 使用方法

### 一键运行（推荐）

```bash
bash <(curl -sL https://lj.1231818.xyz/pvezh)
```

### Gitee 一键运行

```bash
bash <(curl -sL https://gitee.com/chengege666/pvezh/raw/main/pvezh.sh)
```

### GitHub 下载运行

```bash
wget -O pvezh.sh https://raw.githubusercontent.com/chengege666/pvezh/main/pvezh.sh && chmod +x pvezh.sh && ./pvezh.sh
```

### Gitee 下载运行

```bash
wget -O pvezh.sh https://gitee.com/chengege666/pvezh/raw/main/pvezh.sh && chmod +x pvezh.sh && ./pvezh.sh
```

### 手动运行

```bash
chmod +x pvezh.sh
./pvezh.sh
```

## 运行环境

- Proxmox VE 7.x / 8.x
- 需要 root 权限

## 部署模式

### VM 新建

交互式配置虚拟机参数：
- VM ID / 名称
- CPU 核心数 / CPU 类型（host / kvm64）
- 内存大小
- 机型（i440fx / q35）
- 引导模式（SeaBIOS / OVMF UEFI）
- SSD 仿真 / Discard 优化
- 双网口（WAN + LAN）
- 存储位置
- 磁盘导入与自动扩容

### VM 注入

将镜像导入到已有虚拟机，需要目标 VM 已存在。

### LXC 容器

- 支持 LXC 模板直接创建
- 支持从 .img 镜像提取 rootfs 创建
- 配置项：CT ID、名称、CPU、内存、Swap、磁盘大小、网桥、DNS、特权/非特权模式、Nesting

## 镜像识别规则

通过文件名自动识别镜像类型：

| 文件名包含 | 识别结果 | 推荐磁盘 |
|-----------|---------|---------|
| openwrt / owrt | OpenWrt | SATA |
| immortalwrt | ImmortalWrt | SATA |
| lede | LEDE | SATA |
| ubuntu / debian / centos / 等其他 | 通用 Linux | VirtIO |

## 扫描目录

1. 当前运行目录 `./`
2. `/var/lib/vz/template/iso/`
3. `/var/lib/vz/template/cache/`

## 注意

- LXC 模式属于实验性功能，OpenWrt 在 LXC 下可能存在兼容性问题，推荐优先使用 VM 模式
- ARM 架构镜像无法在 x86 PVE 上直接运行
- 需要足够的磁盘空间存放临时镜像文件（位于 `/var/tmp/`）
