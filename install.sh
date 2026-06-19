#!/bin/bash
# PVE 镜像转换工具 - 一键安装
REPO="chengege666/pvezh"
VERSION=$(curl -s https://api.github.com/repos/${REPO}/releases/latest | grep -oP '"tag_name": "\K[^"]+' || echo "v1.0")
wget -qO /tmp/pvezh "https://github.com/${REPO}/releases/download/${VERSION}/pvezh"
chmod +x /tmp/pvezh
/tmp/pvezh
