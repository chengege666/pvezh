#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

clear
echo "====================================================="
echo -e "${BLUE}          PVE 镜像一键转虚拟机工具${NC}"
echo "====================================================="

# 1. 第一步：选择镜像文件
echo "检测到以下镜像文件:"
# 搜索当前目录和 PVE 默认 ISO 目录下的 img 和 img.gz 文件
files=($(find . /var/lib/vz/template/iso/ -maxdepth 1 -name "*.img" -o -name "*.img.gz" 2>/dev/null))

if [ ${#files[@]} -eq 0 ]; then
    echo -e "${RED}[错误] 未找到任何 .img 或 .img.gz 文件，请先上传镜像。${NC}"
    exit 1
fi

for i in "${!files[@]}"; do
    echo " [$(($i+1))] $(basename "${files[$i]}")"
done

echo ""
read -p "请选择镜像编号 (默认 1): " file_idx
file_idx=${file_idx:-1}
selected_file="${files[$(($file_idx-1))]}"
file_name=$(basename "$selected_file")
echo -e ">> 已选择: ${GREEN}$file_name${NC}"
echo ""

# 2. 第二步：设置 VM ID
existing_ids=$(qm list | awk 'NR>1 {print $1}' | tr '\n' ',' | sed 's/,$//')
echo -e "[提示] 当前已存在的虚拟机 ID: ${BLUE}${existing_ids:-无}${NC}"

# 自动计算建议 ID (最大 ID + 1)
max_id=$(qm list | awk 'NR>1 {print $1}' | sort -n | tail -1)
suggest_id=$((max_id + 1))
if [ "$suggest_id" -le 100 ]; then suggest_id=100; fi

read -p "请输入新的虚拟机 ID (建议 $suggest_id): " vmid
vmid=${vmid:-$suggest_id}
echo -e ">> 虚拟机 ID 将设为: ${GREEN}$vmid${NC}"
echo ""

# 3. 第三步：选择目标存储
echo "检测到可用存储位置:"
# 获取类型为 lvmthin 或 zfspool 的活动存储
storage_list=($(pvesm status -content images | awk 'NR>1 {print $1}'))

for i in "${!storage_list[@]}"; do
    echo " [$(($i+1))] ${storage_list[$i]}"
done

echo ""
read -p "请选择要存放磁盘的存储编号 (默认 1): " storage_idx
storage_idx=${storage_idx:-1}
selected_storage="${storage_list[$(($storage_idx-1))]}"
echo -e ">> 目标存储: ${GREEN}$selected_storage${NC}"
echo ""

# 4. 第四步：确认并自动执行
# 自动识别是否为 EFI 镜像
bios_type="seabios"
[[ "$file_name" == *"efi"* ]] && bios_type="ovmf"

echo "-----------------------------------------------------"
echo "确认配置信息:"
echo " - 镜像文件: $file_name"
echo " - 虚拟机ID: $vmid"
echo " - 目标存储: $selected_storage"
echo " - 引导模式: $( [ "$bios_type" == "ovmf" ] && echo "UEFI" || echo "Legacy (SeaBIOS)" )"
echo "-----------------------------------------------------"
read -p "确认开始转换? (y/n): " confirm

if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "已取消操作。"
    exit 0
fi

echo ""
# 4.1 创建虚拟机
echo -ne "[进度] 正在创建虚拟机 $vmid... "
qm create $vmid --name ImmortalWrt-Auto --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-single --ostype l26 --cpu host --memory 2048 --cores 2 --bios $bios_type >/dev/null 2>&1
echo -e "${GREEN}完成${NC}"

# 4.2 处理镜像 (如果是 gz 则解压)
temp_img="/tmp/temp_pve_conv_$vmid.img"
echo -ne "[进度] 正在解压并转换磁盘镜像... "
if [[ "$file_name" == *.gz ]]; then
    zcat "$selected_file" > "$temp_img"
else
    cp "$selected_file" "$temp_img"
fi
echo -e "${GREEN}完成${NC}"

# 4.3 导入磁盘
echo -ne "[进度] 正在导入磁盘到 $selected_storage... "
import_out=$(qm importdisk $vmid "$temp_img" "$selected_storage" 2>&1)
echo -e "${GREEN}100% 完成${NC}"

# 4.4 配置启动项与网卡
echo -ne "[进度] 正在配置启动项与网卡... "
# 这里的磁盘 ID 提取逻辑：通常是导入后的第一个磁盘
disk_name=$(echo "$import_out" | grep -o "unused[0-9]" | head -1)
if [ -z "$disk_name" ]; then
    # 备选提取逻辑：针对不同 PVE 版本的输出
    disk_name=$(pvesm list $selected_storage | grep "vm-$vmid-disk" | tail -1 | awk '{print $1}' | cut -d/ -f2)
    qm set $vmid --scsi0 "$selected_storage:$disk_name" >/dev/null 2>&1
else
    qm set $vmid --scsi0 "$selected_storage:$vmid/vm-$vmid-disk-0.raw" >/dev/null 2>&1 || \
    qm set $vmid --scsi0 "$selected_storage:unused0" >/dev/null 2>&1 # 兼容性处理
fi

# 修正磁盘挂载和引导
qm set $vmid --scsi0 "$selected_storage:vm-$vmid-disk-0" >/dev/null 2>&1
qm set $vmid --boot order=scsi0 >/dev/null 2>&1

# 如果是 EFI 还需要添加 EFI 分区
if [ "$bios_type" == "ovmf" ]; then
    qm set $vmid --efidisk0 "$selected_storage:0,format=qcow2,preenroll-keys=1" >/dev/null 2>&1
fi
echo -e "${GREEN}完成${NC}"

# 4.5 清理
echo -ne "[进度] 正在清理临时文件... "
rm -f "$temp_img"
echo -e "${GREEN}完成${NC}"

echo ""
echo "====================================================="
echo -e "${GREEN}恭喜！虚拟机 $vmid (ImmortalWrt) 已成功创建。${NC}"
echo "====================================================="
echo "提示："
echo "1. 默认分配 2核 CPU / 2G 内存。"
echo "2. 默认创建了一个网卡桥接至 vmbr0。"
echo "3. 请在 PVE 控制台点击“启动”开始使用。"