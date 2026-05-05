#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

cleanup() {
    [ -d "${tmp_mnt:-}" ] && umount "$tmp_mnt" 2>/dev/null
    [ -n "${loop_dev:-}" ] && losetup -d "$loop_dev" 2>/dev/null
    [ -d "${tmp_mnt:-}" ] && rm -rf "$tmp_mnt"
    [ -f "${raw_img:-}" ] && rm -f "$raw_img"
    [ -f "${temp_img:-}" ] && rm -f "$temp_img"
}
trap cleanup EXIT

clear
echo "====================================================="
echo -e "${BLUE}          PVE 镜像转换工具  ${NC}"
echo "====================================================="

scan_dirs=("./" "/var/lib/vz/template/iso/" "/var/lib/vz/template/cache/")

all_found=()
while IFS= read -r -d '' f; do
    all_found+=("$f")
done < <(find "${scan_dirs[@]}" -maxdepth 1 -type f \( -name "*.img" -o -name "*.img.gz" -o -name "*.tar.gz" -o -name "*.tar.zst" -o -name "*.tar.xz" \) -print0 2>/dev/null)

if [ ${#all_found[@]} -eq 0 ]; then
    echo -e "${RED}[错误] 未找到任何可用镜像文件。${NC}"
    exit 1
fi

vm_files=(); lxc_files=()
for f in "${all_found[@]}"; do
    [[ "$f" == *.img || "$f" == *.img.gz ]] && vm_files+=("$f") || lxc_files+=("$f")
done

count=1
merged_files=()
echo -e "${YELLOW}--- VM 镜像 ---${NC}"
for f in "${vm_files[@]}"; do echo " [$count] $(basename "$f")"; merged_files+=("$f"); ((count++)); done
echo -e "\n${YELLOW}--- LXC 镜像 ---${NC}"
for f in "${lxc_files[@]}"; do echo " [$count] $(basename "$f")"; merged_files+=("$f"); ((count++)); done
echo "====================================================="

read -p "请选择镜像编号 (默认 1): " file_idx
file_idx=${file_idx:-1}

if ! [[ "$file_idx" =~ ^[0-9]+$ ]] || [ "$file_idx" -lt 1 ] || [ "$file_idx" -gt "${#merged_files[@]}" ]; then
    echo -e "${RED}[错误] 无效的编号，有效范围: 1 ~ ${#merged_files[@]}${NC}"
    exit 1
fi

selected_file="${merged_files[$((file_idx-1))]}"
file_name=$(basename "$selected_file")
echo -e ">> 已选择: ${GREEN}$file_name${NC}\n"

suggest_mode=1
[[ "$file_name" == *.tar* ]] && suggest_mode=2
echo "请选择安装模式:"
echo " [1] 虚拟机 (VM)"
echo " [2] 容器 (LXC)"
read -p "您的选择 (默认 $suggest_mode): " mode
mode=${mode:-$suggest_mode}

suggest_id=$(pvesh get /cluster/nextid 2>/dev/null) || suggest_id=100

if [ "$mode" == "1" ]; then
    echo -e ">> 进入 ${BLUE}[VM 虚拟机]${NC} 模式"
    echo " [1] 全自动创建新虚拟机"
    echo " [2] 注入现有虚拟机 (空壳)"
    read -p "请选择操作类型 (默认 1): " vm_op
    vm_op=${vm_op:-1}

    if [ "$vm_op" == "1" ]; then
        read -p "[配置] 请输入新虚拟机 ID: " vmid; vmid=${vmid:-$suggest_id}
        echo "  [1] openwrt-VM (默认)"
        echo "  [2] immortalwrt-VM"
        echo "  [3] 自定义名称"
        read -p "[配置] 虚拟机名称选择 (默认 1): " vname_idx; vname_idx=${vname_idx:-1}
        if [ "$vname_idx" == "2" ]; then
            vname="immortalwrt-VM"
        elif [ "$vname_idx" == "3" ]; then
            read -p "[配置] 请输入自定义虚拟机名称: " vname
        else
            vname="openwrt-VM"
        fi
        read -p "[配置] CPU 核心数 (默认 1): " vcores; vcores=${vcores:-1}
        echo "  [1] host (物理机直通)"
        echo "  [2] kvm64 (标准兼容)"
        read -p "  请选择 CPU 模式 (默认 1): " cpu_idx; cpu_idx=${cpu_idx:-1}
        [[ "$cpu_idx" == "2" ]] && vcpu="kvm64" || vcpu="host"
        read -p "[配置] 内存大小 MB (默认 512): " vmem; vmem=${vmem:-512}
        read -p "[配置] 虚拟内存 Swap MB (默认 0): " vswap; vswap=${vswap:-0}

        echo "  [1] i440fx (默认/兼容性好)"
        echo "  [2] q35 (现代/支持 PCIe 直通)"
        read -p "  请选择机型 (默认 1): " mach_idx; mach_idx=${mach_idx:-1}
        [[ "$mach_idx" == "2" ]] && vmachine="q35" || vmachine="pc"

        read -p "[配置] 引导模式 [1] SeaBIOS [2] OVMF(UEFI) (默认 1): " v_bios; v_bios=${v_bios:-1}
        read -p "[高级] 是否开启 SSD 仿真与 Discard 优化? (y/n, 默认 y): " v_ssd; v_ssd=${v_ssd:-y}
        read -p "[高级] 是否需要配置双网口 (WAN+LAN)? (y/n, 默认 n): " v_dual; v_dual=${v_dual:-n}
        read -p "  -> 网口 1 (eth0) 桥接至 (默认 vmbr0): " vbr0; vbr0=${vbr0:-vmbr0}
        if [ "$v_dual" == "y" ]; then
            read -p "  -> 网口 2 (eth1) 桥接至 (默认 vmbr1): " vbr1; vbr1=${vbr1:-vmbr1}
        fi

        readarray -t storage_list < <(pvesm status -content images | awk 'NR>1 {print $1}')
        if [ ${#storage_list[@]} -eq 0 ]; then
            echo -e "${RED}[错误] 没有可用的 images 类型存储。${NC}"
            exit 1
        fi
        echo -e "\n[系统] 可用存储:"
        for i in "${!storage_list[@]}"; do echo "  $(($i+1))) ${storage_list[$i]}"; done
        read -p "请选择存储位置 (默认 1): " st_idx; st_idx=${st_idx:-1}
        if ! [[ "$st_idx" =~ ^[0-9]+$ ]] || [ "$st_idx" -lt 1 ] || [ "$st_idx" -gt "${#storage_list[@]}" ]; then
            echo -e "${RED}[错误] 无效的存储编号，有效范围: 1 ~ ${#storage_list[@]}${NC}"
            exit 1
        fi
        vst=${storage_list[$((st_idx-1))]}

        echo -e "\n====================================================="
        echo "确认创建: VM $vmid ($vname)"
        echo "配置: $vcores 核($vcpu), $vmem MB, Swap ${vswap}MB, 存储 $vst"
        echo "====================================================="
        read -p "确认继续? (y/n, 默认 y): " confirm; [[ "${confirm:-y}" != "y" ]] && exit 0

        echo -ne "[进度] 正在创建虚拟机并配置网口... "
        bios_opt=""
        [[ "$v_bios" == "2" ]] && bios_opt="--bios ovmf"
        qm create $vmid --name "$vname" --net0 virtio,bridge=$vbr0 --cores $vcores --memory $vmem --swap "$vswap" --cpu $vcpu --machine $vmachine --ostype l26 $bios_opt >/dev/null 2>&1
        [ "$v_dual" == "y" ] && qm set $vmid --net1 virtio,bridge=$vbr1 >/dev/null 2>&1
        [[ "$v_bios" == "2" ]] && qm set $vmid --efidisk0 $vst:0 >/dev/null 2>&1
        echo -e "${GREEN}完成${NC}"
    else
        qm list
        read -p "请输入目标 VM ID: " vmid
        readarray -t storage_list < <(pvesm status -content images | awk 'NR>1 {print $1}')
        if [ ${#storage_list[@]} -eq 0 ]; then
            echo -e "${RED}[错误] 没有可用的 images 类型存储。${NC}"
            exit 1
        fi
        echo -e "\n[系统] 可用存储:"
        for i in "${!storage_list[@]}"; do echo "  $(($i+1))) ${storage_list[$i]}"; done
        read -p "请选择存储位置 (默认 1): " st_idx; st_idx=${st_idx:-1}
        if ! [[ "$st_idx" =~ ^[0-9]+$ ]] || [ "$st_idx" -lt 1 ] || [ "$st_idx" -gt "${#storage_list[@]}" ]; then
            echo -e "${RED}[错误] 无效的存储编号，有效范围: 1 ~ ${#storage_list[@]}${NC}"
            exit 1
        fi
        vst=${storage_list[$((st_idx-1))]}
        v_ssd="n"
    fi

    temp_img="/var/tmp/imp_$vmid.img"
    echo -ne "[进度] 正在解压并处理磁盘镜像... "
    if [[ "$file_name" == *.gz ]]; then
        zcat "$selected_file" > "$temp_img" 2>/dev/null
    else
        cp "$selected_file" "$temp_img" 2>/dev/null
    fi

    if [ $? -ne 0 ]; then
        echo -e "${RED}失败！原因：磁盘空间不足或文件损坏。${NC}"
        cleanup
        exit 1
    fi
    echo -e "${GREEN}完成${NC}"

    echo -ne "[进度] 正在注入磁盘并应用特性... "
    import_err=$(qm importdisk $vmid "$temp_img" "$vst" 2>&1)
    if [ $? -eq 0 ]; then
        disk_params="$vst:vm-$vmid-disk-0"
        [ "$v_ssd" == "y" ] && disk_params="$disk_params,discard=on,ssd=1"
        qm set $vmid --scsihw virtio-scsi-pci --scsi0 "$disk_params" --boot order=scsi0 >/dev/null 2>&1
        echo -e "${GREEN}完成${NC}"
    else
        echo -e "${RED}失败！${NC}"
        echo -e "${YELLOW}原因:${NC} $import_err"
        echo ""
        echo -e "可能的原因与排查:"
        echo -e "  1. ${YELLOW}存储空间不足${NC}: 检查 \"pvesm status\" 确认 $vst 有足够空间"
        echo -e "  2. ${YELLOW}临时文件位置不受支持${NC}: 可将镜像先复制到 \"$vst\" 存储的目录下重试"
        echo -e "  3. ${YELLOW}VM 状态冲突${NC}: 确保 VM $vmid 未运行 (qm status $vmid)"
        echo -e "  4. ${YELLOW}镜像损坏${NC}: 临时文件保留在 $temp_img 可手动排查"
        exit 1
    fi

    rm -f "$temp_img"
    echo -e ">> 操作成功：VM $vmid 已就绪。"

elif [ "$mode" == "2" ]; then
    echo -e ">> 进入 ${BLUE}[LXC 容器]${NC} 模式"
    read -p "[配置] 容器 ID: " ctid; ctid=${ctid:-$suggest_id}
    echo " [1] openwrt-LXC (默认)"
    echo " [2] immortalwrt-LXC"
    echo " [3] 自定义名称"
    read -p "[配置] 容器名称选择 (默认 1): " cname_idx; cname_idx=${cname_idx:-1}
    if [ "$cname_idx" == "2" ]; then
        cname="immortalwrt-LXC"
    elif [ "$cname_idx" == "3" ]; then
        read -p "[配置] 请输入自定义容器名称: " cname
    else
        cname="openwrt-LXC"
    fi

    echo " [1] 非特权 (更安全, 默认)"
    echo " [2] 特权 (支持拨号/硬件直接访问)"
    read -p "权限 模式选择 (默认 1): " priv_idx; priv_idx=${priv_idx:-1}
    [[ "$priv_idx" == "2" ]] && unpriv=0 || unpriv=1

    read -p "[配置] CPU 核心 (默认 1): " cores; cores=${cores:-1}
    read -p "[配置] 内存 MB (默认 512): " mem; mem=${mem:-512}
    read -p "[配置] 虚拟内存 Swap MB (默认 512): " swap_val; swap_val=${swap_val:-512}
    read -p "[配置] 磁盘大小 (G, 默认 4): " dsize; dsize=${dsize:-4}
    read -p "[配置] 网络桥接 (默认 vmbr0): " br; br=${br:-vmbr0}

    echo -e "--- 高级选项 ---"
    read -p "[配置] 开启 Nesting 虚拟化 (y/n, 默认 y): " nesting; nesting=${nesting:-y}
    read -p "[配置] 激活 /etc/rc.local 执行权限? (y/n, 默认 y): " opt_rc; opt_rc=${opt_rc:-y}
    read -p "[配置] 自定义 DNS (留空使用宿主机): " dns_server

    readarray -t storage_list < <(pvesm status -content rootdir | awk 'NR>1 {print $1}')
    if [ ${#storage_list[@]} -eq 0 ]; then
        echo -e "${RED}[错误] 没有可用的 rootdir 类型存储。${NC}"
        exit 1
    fi
    echo -e "\n[系统] 可用存储:"
    for i in "${!storage_list[@]}"; do echo "  $(($i+1))) ${storage_list[$i]}"; done
    read -p "请选择存储位置 (默认 1): " st_idx; st_idx=${st_idx:-1}
    if ! [[ "$st_idx" =~ ^[0-9]+$ ]] || [ "$st_idx" -lt 1 ] || [ "$st_idx" -gt "${#storage_list[@]}" ]; then
        echo -e "${RED}[错误] 无效的存储编号，有效范围: 1 ~ ${#storage_list[@]}${NC}"
        exit 1
    fi
    selected_storage=${storage_list[$((st_idx-1))]}

    final_tar="$selected_file"
    if [[ "$file_name" == *.img || "$file_name" == *.img.gz ]]; then
        echo -e "${YELLOW}[第一阶段] 正在将 .img 转换为 LXC 模版...${NC}"
        raw_img="/var/tmp/lxc_raw_$ctid.img"
        tmp_mnt="/var/tmp/lxc_mnt_$ctid"
        mkdir -p "$tmp_mnt"

        if [[ "$file_name" == *.gz ]]; then
            zcat "$selected_file" > "$raw_img" 2>/dev/null
        else
            cp "$selected_file" "$raw_img" 2>/dev/null
        fi

        if [ $? -ne 0 ]; then
             echo -e "${RED}转换失败：磁盘空间不足。${NC}"
             exit 1
        fi

        loop_dev=$(losetup -fP --show "$raw_img")
        if ! mount "${loop_dev}p2" "$tmp_mnt" >/dev/null 2>&1; then
            mount "${loop_dev}p1" "$tmp_mnt" >/dev/null 2>&1 || mount "$loop_dev" "$tmp_mnt" >/dev/null 2>&1
        fi

        if [ "$opt_rc" == "y" ] && [ -f "$tmp_mnt/etc/rc.local" ]; then
            chmod +x "$tmp_mnt/etc/rc.local"
            echo -e "  -> 已激活 /etc/rc.local"
        fi

        final_tar="/var/lib/vz/template/cache/lxc_auto_$ctid.tar.gz"
        (cd "$tmp_mnt" && tar -czf "$final_tar" .)
        umount "$tmp_mnt" 2>/dev/null || true
        losetup -d "$loop_dev" 2>/dev/null || true
        rm -rf "$tmp_mnt" 2>/dev/null || true
        rm -f "$raw_img" 2>/dev/null || true
        loop_dev=""
        echo -e "${GREEN}  -> 转换完成！${NC}"
    fi

    echo -ne "[进度] 正在创建容器... "

    extra_opts=""
    [ "$nesting" == "y" ] && extra_opts="--features nesting=1"
    [ -n "$dns_server" ] && extra_opts="$extra_opts --nameserver $dns_server"

    if pct create $ctid "$final_tar" --arch amd64 --hostname "$cname" --rootfs "$selected_storage:$dsize" \
      --memory "$mem" --swap "$swap_val" --cores "$cores" --ostype unmanaged --unprivileged $unpriv \
      --net0 name=eth0,bridge=$br,ip=manual $extra_opts >/dev/null 2>&1; then
        echo -e "${GREEN}完成${NC}"
        echo -e "\n>> 操作成功：LXC 容器 $ctid 已就绪。"
    else
        if [[ "$final_tar" == /var/lib/vz/template/cache/lxc_auto_* ]]; then
            rm -f "$final_tar" 2>/dev/null
        fi
        echo -e "${RED}失败！${NC}"
    fi
fi
