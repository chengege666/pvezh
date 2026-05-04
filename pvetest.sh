#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ─────────────────────────────────────────────
# 全局临时变量（显式初始化，防止 cleanup 误判）
# ─────────────────────────────────────────────
loop_dev=""
tmp_mnt=""
raw_img=""
temp_img=""

cleanup() {
    [ -n "$loop_dev" ] && losetup -d "$loop_dev" 2>/dev/null || true
    if [ -n "$tmp_mnt" ] && mountpoint -q "$tmp_mnt" 2>/dev/null; then
        umount "$tmp_mnt" 2>/dev/null || true
    fi
    [ -n "$tmp_mnt" ]  && [ -d "$tmp_mnt" ] && rm -rf "$tmp_mnt"
    [ -n "$raw_img" ]  && [ -f "$raw_img" ] && rm -f "$raw_img"
    [ -n "$temp_img" ] && [ -f "$temp_img" ] && rm -f "$temp_img"
}
trap cleanup EXIT

# ─────────────────────────────────────────────
# 工具函数
# ─────────────────────────────────────────────
die() { echo -e "${RED}[错误] $*${NC}" >&2; exit 1; }
info() { echo -e "${GREEN}[✔]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }

# 校验正整数
validate_int() {
    local val="$1" name="$2" min="${3:-1}" max="${4:-999999999}"
    [[ "$val" =~ ^[0-9]+$ ]] || die "$name 必须为正整数，收到：'$val'"
    (( val >= min && val <= max )) || die "$name 超出范围 [$min, $max]，收到：$val"
}

# 读取并校验整数输入
read_int() {
    local prompt="$1" default="$2" min="${3:-1}" max="${4:-999999999}"
    local val
    read -p "$prompt" val
    val="${val:-$default}"
    validate_int "$val" "$prompt" "$min" "$max"
    echo "$val"
}

# 校验 PVE VM/CT ID（100–999999999）
validate_vmid() {
    validate_int "$1" "ID" 100 999999999
    # 检查 ID 是否已被占用
    if qm status "$1" &>/dev/null || pct status "$1" &>/dev/null; then
        die "ID $1 已被占用，请选择其他 ID。"
    fi
}

# ─────────────────────────────────────────────
# 主界面
# ─────────────────────────────────────────────
clear
echo "====================================================="
echo -e "${BLUE}          PVE 镜像转换工具  ${NC}"
echo "====================================================="

# ─────────────────────────────────────────────
# 扫描镜像文件
# ─────────────────────────────────────────────
scan_dirs=("./" "/var/lib/vz/template/iso/" "/var/lib/vz/template/cache/")
mapfile -t all_found < <(
    find "${scan_dirs[@]}" -maxdepth 1 -type f \
        \( -name "*.img" -o -name "*.img.gz" -o -name "*.tar.gz" \
           -o -name "*.tar.zst" -o -name "*.tar.xz" \) 2>/dev/null | sort
)

[ ${#all_found[@]} -eq 0 ] && die "未找到任何可用镜像文件。"

vm_files=(); lxc_files=()
for f in "${all_found[@]}"; do
    [[ "$f" == *.img || "$f" == *.img.gz ]] \
        && vm_files+=("$f") || lxc_files+=("$f")
done

count=1
merged_files=()
echo -e "${YELLOW}--- VM 镜像 ---${NC}"
for f in "${vm_files[@]}"; do
    printf " [%d] %s\n" "$count" "$(basename "$f")"
    merged_files+=("$f"); ((count++))
done
echo -e "\n${YELLOW}--- LXC 镜像 ---${NC}"
for f in "${lxc_files[@]}"; do
    printf " [%d] %s\n" "$count" "$(basename "$f")"
    merged_files+=("$f"); ((count++))
done
echo "====================================================="

total=${#merged_files[@]}
read -p "请选择镜像编号 (默认 1): " file_idx
file_idx="${file_idx:-1}"
validate_int "$file_idx" "镜像编号" 1 "$total"
selected_file="${merged_files[$(( file_idx - 1 ))]}"
file_name=$(basename "$selected_file")
echo -e ">> 已选择: ${GREEN}$file_name${NC}\n"

# ─────────────────────────────────────────────
# 选择安装模式
# ─────────────────────────────────────────────
suggest_mode=1
[[ "$file_name" == *.tar* ]] && suggest_mode=2
echo "请选择安装模式:"
echo " [1] 虚拟机 (VM)"
echo " [2] 容器 (LXC)"
read -p "您的选择 (默认 $suggest_mode): " mode
mode="${mode:-$suggest_mode}"
[[ "$mode" == "1" || "$mode" == "2" ]] || die "无效的模式选择：$mode"

# 获取下一个可用 ID（失败时给出提示）
suggest_id=$(pvesh get /cluster/nextid 2>/dev/null) \
    || { warn "无法获取集群下一个 ID，请手动输入。"; suggest_id="100"; }

# ═══════════════════════════════════════════════════════════
# VM 模式
# ═══════════════════════════════════════════════════════════
if [ "$mode" == "1" ]; then
    echo -e ">> 进入 ${BLUE}[VM 虚拟机]${NC} 模式"
    echo " [1] 全自动创建新虚拟机"
    echo " [2] 注入现有虚拟机 (空壳)"
    read -p "请选择操作类型 (默认 1): " vm_op
    vm_op="${vm_op:-1}"
    [[ "$vm_op" == "1" || "$vm_op" == "2" ]] || die "无效的操作类型：$vm_op"

    # ── 自动创建 ──────────────────────────────────────
    if [ "$vm_op" == "1" ]; then
        read -p "[配置] 请输入新虚拟机 ID (默认 $suggest_id): " vmid
        vmid="${vmid:-$suggest_id}"
        validate_vmid "$vmid"

        echo "  [1] openwrt-VM (默认)"
        echo "  [2] immortalwrt-VM"
        echo "  [3] 自定义名称"
        read -p "[配置] 虚拟机名称选择 (默认 1): " vname_idx
        vname_idx="${vname_idx:-1}"
        case "$vname_idx" in
            1) vname="openwrt-VM" ;;
            2) vname="immortalwrt-VM" ;;
            3) read -p "[配置] 请输入自定义虚拟机名称: " vname
               [[ -n "$vname" ]] || die "虚拟机名称不能为空。" ;;
            *) die "无效选项：$vname_idx" ;;
        esac

        vcores=$(read_int "[配置] CPU 核心数 (默认 1): " 1 1 128)

        echo "  [1] host (物理机直通)"
        echo "  [2] kvm64 (标准兼容)"
        read -p "  请选择 CPU 模式 (默认 1): " cpu_idx
        cpu_idx="${cpu_idx:-1}"
        [[ "$cpu_idx" == "2" ]] && vcpu="kvm64" || vcpu="host"

        vmem=$(read_int "[配置] 内存大小 MB (默认 512): " 512 32 1048576)
        vswap=$(read_int "[配置] 虚拟内存 Swap MB (默认 0): " 0 0 65536)

        echo "  [1] i440fx (默认/兼容性好)"
        echo "  [2] q35 (现代/支持 PCIe 直通)"
        read -p "  请选择机型 (默认 1): " mach_idx
        mach_idx="${mach_idx:-1}"
        [[ "$mach_idx" == "2" ]] && vmachine="q35" || vmachine="pc"

        read -p "[配置] 引导模式 [1] SeaBIOS [2] OVMF(UEFI) (默认 1): " v_bios
        v_bios="${v_bios:-1}"
        [[ "$v_bios" == "1" || "$v_bios" == "2" ]] || die "无效的引导模式：$v_bios"

        read -p "[高级] 是否开启 SSD 仿真与 Discard 优化? (y/n, 默认 y): " v_ssd
        v_ssd="${v_ssd:-y}"

        read -p "[高级] 是否需要配置双网口 (WAN+LAN)? (y/n, 默认 n): " v_dual
        v_dual="${v_dual:-n}"

        read -p "  -> 网口 1 (eth0) 桥接至 (默认 vmbr0): " vbr0
        vbr0="${vbr0:-vmbr0}"

        if [ "$v_dual" == "y" ]; then
            read -p "  -> 网口 2 (eth1) 桥接至 (默认 vmbr1): " vbr1
            vbr1="${vbr1:-vmbr1}"
        fi

        # 存储列表
        mapfile -t storage_list < <(pvesm status -content images 2>/dev/null | awk 'NR>1 {print $1}')
        [ ${#storage_list[@]} -eq 0 ] && die "未找到可用的 VM 存储（images 类型）。"
        echo -e "\n[系统] 可用存储:"
        for i in "${!storage_list[@]}"; do
            printf "  %d) %s\n" "$(( i+1 ))" "${storage_list[$i]}"
        done
        st_idx=$(read_int "请选择存储位置 (默认 1): " 1 1 "${#storage_list[@]}")
        vst="${storage_list[$(( st_idx - 1 ))]}"

        echo -e "\n====================================================="
        echo "确认创建: VM $vmid ($vname)"
        echo "配置: $vcores 核($vcpu), $vmem MB RAM, Swap ${vswap} MB"
        echo "机型: $vmachine | 引导: $( [[ "$v_bios" == "2" ]] && echo OVMF || echo SeaBIOS )"
        echo "存储: $vst | 网口: $vbr0$( [ "$v_dual" == "y" ] && echo " + $vbr1" )"
        echo "====================================================="
        read -p "确认继续? (y/n, 默认 y): " confirm
        [[ "${confirm:-y}" == "y" ]] || exit 0

        echo -ne "[进度] 正在创建虚拟机... "
        bios_args=()
        [[ "$v_bios" == "2" ]] && bios_args=(--bios ovmf)
        qm create "$vmid" --name "$vname" \
            --net0 "virtio,bridge=$vbr0" \
            --cores "$vcores" --memory "$vmem" --balloon 0 \
            --cpu "$vcpu" --machine "$vmachine" --ostype l26 \
            "${bios_args[@]}" >/dev/null 2>&1
        [ "$v_dual" == "y" ] && qm set "$vmid" --net1 "virtio,bridge=$vbr1" >/dev/null 2>&1
        [[ "$v_bios" == "2" ]] && qm set "$vmid" --efidisk0 "$vst:0" >/dev/null 2>&1
        info "虚拟机骨架创建完成"

    # ── 注入现有 VM ────────────────────────────────────
    else
        qm list
        read -p "请输入目标 VM ID: " vmid
        validate_int "$vmid" "VM ID" 100 999999999
        qm status "$vmid" &>/dev/null || die "VM $vmid 不存在。"

        # 让用户选择存储（与自动创建保持一致）
        mapfile -t storage_list < <(pvesm status -content images 2>/dev/null | awk 'NR>1 {print $1}')
        [ ${#storage_list[@]} -eq 0 ] && die "未找到可用的 VM 存储（images 类型）。"
        echo -e "\n[系统] 可用存储:"
        for i in "${!storage_list[@]}"; do
            printf "  %d) %s\n" "$(( i+1 ))" "${storage_list[$i]}"
        done
        st_idx=$(read_int "请选择存储位置 (默认 1): " 1 1 "${#storage_list[@]}")
        vst="${storage_list[$(( st_idx - 1 ))]}"
        v_ssd="n"
    fi

    # ── 磁盘解压与导入（VM 共用）─────────────────────────
    # 使用 PID 避免并发冲突
    temp_img="/var/tmp/imp_${vmid}_$$.img"

    echo -ne "[进度] 正在解压磁盘镜像... "
    if [[ "$file_name" == *.gz ]]; then
        zcat "$selected_file" > "$temp_img" || die "解压失败，请检查磁盘空间或文件完整性。"
    else
        cp "$selected_file" "$temp_img" || die "复制失败，请检查磁盘空间。"
    fi
    info "解压完成 ($(du -sh "$temp_img" | cut -f1))"

    echo -ne "[进度] 正在导入磁盘到存储 $vst ... "
    qm importdisk "$vmid" "$temp_img" "$vst" >/dev/null 2>&1 \
        || die "无法将磁盘导入到存储 $vst，请检查存储类型与剩余空间。"

    # 导入后立即清理临时镜像
    rm -f "$temp_img"; temp_img=""

    disk_id="$vst:vm-$vmid-disk-0"
    disk_params="$disk_id"
    [ "${v_ssd:-n}" == "y" ] && disk_params="$disk_params,discard=on,ssd=1"
    qm set "$vmid" \
        --scsihw virtio-scsi-pci \
        --scsi0 "$disk_params" \
        --boot order=scsi0 >/dev/null 2>&1
    info "磁盘导入并挂载完成"

    echo ""
    echo -e ">> ${GREEN}操作成功：VM $vmid 已就绪。${NC}"

# ═══════════════════════════════════════════════════════════
# LXC 模式
# ═══════════════════════════════════════════════════════════
elif [ "$mode" == "2" ]; then
    echo -e ">> 进入 ${BLUE}[LXC 容器]${NC} 模式"

    read -p "[配置] 容器 ID (默认 $suggest_id): " ctid
    ctid="${ctid:-$suggest_id}"
    validate_vmid "$ctid"

    echo " [1] openwrt-LXC (默认)"
    echo " [2] immortalwrt-LXC"
    echo " [3] 自定义名称"
    read -p "[配置] 容器名称选择 (默认 1): " cname_idx
    cname_idx="${cname_idx:-1}"
    case "$cname_idx" in
        1) cname="openwrt-LXC" ;;
        2) cname="immortalwrt-LXC" ;;
        3) read -p "[配置] 请输入自定义容器名称: " cname
           [[ -n "$cname" ]] || die "容器名称不能为空。" ;;
        *) die "无效选项：$cname_idx" ;;
    esac

    echo " [1] 非特权 (更安全, 默认)"
    echo " [2] 特权 (支持拨号/硬件直接访问)"
    read -p "权限模式选择 (默认 1): " priv_idx
    priv_idx="${priv_idx:-1}"
    [[ "$priv_idx" == "2" ]] && unpriv=0 || unpriv=1

    cores=$(read_int "[配置] CPU 核心 (默认 1): " 1 1 128)
    mem=$(read_int "[配置] 内存 MB (默认 512): " 512 32 1048576)
    swap_val=$(read_int "[配置] 虚拟内存 Swap MB (默认 512): " 512 0 65536)
    dsize=$(read_int "[配置] 磁盘大小 G (默认 4): " 4 1 65536)

    read -p "[配置] 网络桥接 (默认 vmbr0): " br
    br="${br:-vmbr0}"

    echo -e "--- 高级选项 ---"
    read -p "[配置] 开启 Nesting 虚拟化 (y/n, 默认 y): " nesting
    nesting="${nesting:-y}"
    read -p "[配置] 激活 /etc/rc.local 执行权限? (y/n, 默认 y): " opt_rc
    opt_rc="${opt_rc:-y}"
    read -p "[配置] 自定义 DNS (留空使用宿主机): " dns_server
    dns_server="${dns_server:-}"

    mapfile -t storage_list < <(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print $1}')
    [ ${#storage_list[@]} -eq 0 ] && die "未找到可用的 LXC 存储（rootdir 类型）。"
    echo -e "\n[系统] 可用存储:"
    for i in "${!storage_list[@]}"; do
        printf "  %d) %s\n" "$(( i+1 ))" "${storage_list[$i]}"
    done
    st_idx=$(read_int "请选择存储位置 (默认 1): " 1 1 "${#storage_list[@]}")
    selected_storage="${storage_list[$(( st_idx - 1 ))]}"

    # ── .img/.img.gz → tar.gz 转换 ────────────────────
    final_tar="$selected_file"
    if [[ "$file_name" == *.img || "$file_name" == *.img.gz ]]; then
        echo -e "${YELLOW}[第一阶段] 正在将 .img 转换为 LXC 模版...${NC}"

        raw_img="/var/tmp/lxc_raw_${ctid}_$$.img"
        tmp_mnt="/var/tmp/lxc_mnt_${ctid}_$$"
        mkdir -p "$tmp_mnt"

        echo -ne "  -> 解压镜像... "
        if [[ "$file_name" == *.gz ]]; then
            zcat "$selected_file" > "$raw_img" || die "解压失败，请检查磁盘空间或文件完整性。"
        else
            cp "$selected_file" "$raw_img" || die "复制失败，请检查磁盘空间。"
        fi
        info "完成"

        echo -ne "  -> 挂载分区... "
        loop_dev=$(losetup -fP --show "$raw_img") \
            || die "无法创建 loop 设备，请检查内核模块 loop 是否加载。"

        # 依次尝试 p2 / p1 / 裸设备，三者全失败则终止
        mounted=0
        for part in "${loop_dev}p2" "${loop_dev}p1" "$loop_dev"; do
            if mount "$part" "$tmp_mnt" >/dev/null 2>&1; then
                mounted=1
                break
            fi
        done
        if [ "$mounted" -eq 0 ]; then
            losetup -d "$loop_dev"; loop_dev=""
            rm -rf "$tmp_mnt"; tmp_mnt=""
            rm -f "$raw_img";   raw_img=""
            die "无法挂载任何分区（已尝试 p2/p1/裸设备），镜像可能损坏。"
        fi
        info "完成"

        # 处理 rc.local 权限
        if [ "$opt_rc" == "y" ] && [ -f "$tmp_mnt/etc/rc.local" ]; then
            chmod +x "$tmp_mnt/etc/rc.local"
            echo -e "  -> 已激活 /etc/rc.local"
        fi

        final_tar="/var/lib/vz/template/cache/lxc_auto_${ctid}_$$.tar.gz"
        echo -ne "  -> 打包为 tar.gz ... "
        # 排除伪文件系统目录，防止打包内核虚拟文件
        (
            cd "$tmp_mnt"
            tar -czf "$final_tar" \
                --exclude=./proc \
                --exclude=./sys \
                --exclude=./dev \
                --exclude=./run \
                . 2>/dev/null
        ) || die "tar 打包失败，请检查磁盘空间。"

        umount "$tmp_mnt";        tmp_mnt=""
        losetup -d "$loop_dev";   loop_dev=""
        rm -rf "/var/tmp/lxc_mnt_${ctid}_$$"
        rm -f "$raw_img";         raw_img=""
        info "转换完成！"
    fi

    # ── 创建容器 ──────────────────────────────────────
    echo -ne "[进度] 正在创建容器 $ctid ... "

    extra_args=()
    [ "$nesting" == "y" ] && extra_args+=(--features nesting=1)
    [ -n "$dns_server" ]   && extra_args+=(--nameserver "$dns_server")

    pct create "$ctid" "$final_tar" \
        --arch amd64 \
        --hostname "$cname" \
        --rootfs "$selected_storage:$dsize" \
        --memory "$mem" \
        --swap "$swap_val" \
        --cores "$cores" \
        --ostype unmanaged \
        --unprivileged "$unpriv" \
        --net0 "name=eth0,bridge=$br,ip=manual" \
        "${extra_args[@]}" >/dev/null 2>&1 \
        || die "pct create 失败，请检查日志：journalctl -xe"

    info "容器创建完成"

    # 若是从 .img 转换的临时模板，创建后删除
    if [[ "$final_tar" == /var/lib/vz/template/cache/lxc_auto_* ]]; then
        rm -f "$final_tar"
    fi

    echo ""
    echo -e ">> ${GREEN}操作成功：LXC 容器 $ctid 已就绪。${NC}"
fi
