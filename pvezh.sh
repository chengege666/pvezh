#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

clear
echo "====================================================="
echo -e "${BLUE}          PVE 镜像导入工具 (仅限磁盘转换)${NC}"
echo "====================================================="

# 1. 选择镜像文件
echo "检测到以下镜像文件:"
files=($(find . /var/lib/vz/template/iso/ -maxdepth 1 -name "*.img" -o -name "*.img.gz" 2>/dev/null))

if [ ${#files[@]} -eq 0 ]; then
    echo -e "${RED}[错误] 未找到任何 .img 或 .img.gz 文件，请先上传镜像。${NC}"
    exit 1
fi

for i in "${!files[@]}"; do
    echo " [$(($i+1))] $(basename "${files[$i]}")"
done

read -p "请选择镜像编号 (默认 1): " file_idx
file_idx=${file_idx:-1}
selected_file="${files[$(($file_idx-1))]}"
file_name=$(basename "$selected_file")
echo -e ">> 已选择: ${GREEN}$file_name${NC}\n"

# 2. 指定目标虚拟机 VMID
echo "当前运行中的虚拟机列表:"
qm list
echo "-----------------------------------------------------"
read -p "请输入要导入的目标 VM ID: " vmid

if ! qm status $vmid >/dev/null 2>&1; then
    echo -e "${RED}[错误] 虚拟机 $vmid 不存在，请先在界面创建好虚拟机。${NC}"
    exit 1
fi
echo -e ">> 目标虚拟机: ${GREEN}$vmid${NC}\n"

# 3. 选择目标存储
echo "检测到可用存储位置:"
storage_list=($(pvesm status -content images | awk 'NR>1 {print $1}'))
for i in "${!storage_list[@]}"; do
    echo " [$(($i+1))] ${storage_list[$i]}"
done

read -p "请选择存储编号 (默认 1): " storage_idx
storage_idx=${storage_idx:-1}
selected_storage="${storage_list[$(($storage_idx-1))]}"
echo -e ">> 目标存储: ${GREEN}$selected_storage${NC}\n"

# 4. 执行转换与导入
echo "-----------------------------------------------------"
echo -e "准备将 ${BLUE}$file_name${NC} 导入到虚拟机 ${BLUE}$vmid${NC} ($selected_storage)"
read -p "确认开始? (y/n): " confirm
[[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 0

# 处理压缩包
temp_img="/tmp/temp_import_$vmid.img"
if [[ "$file_name" == *.gz ]]; then
    echo -ne "[1/3] 正在解压缩镜像... "
    zcat "$selected_file" > "$temp_img"
    echo -e "${GREEN}完成${NC}"
else
    temp_img="$selected_file"
fi

echo -ne "[2/3] 正在转换格式并导入磁盘... "
# 执行导入命令
import_log=$(qm importdisk $vmid "$temp_img" "$selected_storage" 2>&1)
echo -e "${GREEN}完成${NC}"

echo -ne "[3/3] 正在挂载磁盘并设为第一启动项... "
# 获取导入后的磁盘名称
# 适配不同版本的 qm importdisk 输出
drive_id=$(echo "$import_log" | grep -o "unused[0-9]" | head -1)
if [ -z "$drive_id" ]; then
    # 如果没找到 unused 标识，尝试手动拼接常规格式
    qm set $vmid --scsi0 "$selected_storage:vm-$vmid-disk-0" >/dev/null 2>&1
else
    qm set $vmid --scsi0 "$selected_storage:$drive_id" >/dev/null 2>&1
fi

# 设置引导顺序
qm set $vmid --boot order=scsi0 >/dev/null 2>&1
echo -e "${GREEN}完成${NC}"

# 清理临时文件
[[ "$file_name" == *.gz ]] && rm -f "$temp_img"

echo -e "\n${GREEN}成功！磁盘已成功注入虚拟机 $vmid。${NC}"
echo "请回到 PVE 界面手动启动该虚拟机。"