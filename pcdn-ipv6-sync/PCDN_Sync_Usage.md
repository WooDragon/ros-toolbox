# RouterOS IPv4/IPv6 防火墙地址列表同步脚本 - 使用说明

## 脚本文件
- **主脚本**: [`pcdn-ipv6-sync.rsc`](pcdn-ipv6-sync.rsc) - 完整功能版本（包含清理）
- **安全脚本**: [`pcdn-ipv6-sync-safe.rsc`](pcdn-ipv6-sync-safe.rsc) - 只添加不删除版本（推荐首次使用）
- **测试脚本**: [`pcdn-ipv6-sync-test.rsc`](pcdn-ipv6-sync-test.rsc) - 环境检查版本
- **架构设计**: [`PCDN_Sync_Architecture.md`](PCDN_Sync_Architecture.md)

## 功能概述
此脚本用于自动同步 RouterOS v7 中的 IPv4 和 IPv6 防火墙地址列表：
- 从 IPv4 防火墙地址列表 `PCDN-P1` 和 `PCDN-P2` 中获取 IP 地址
- 通过 ARP 表查找对应的 MAC 地址
- 在 IPv6 Neighbor 表中找到该 MAC 对应的全局单播 IPv6 地址 (GUA)
- 将找到的 IPv6 地址添加到同名的 IPv6 防火墙地址列表中
- 清理不再有效的 IPv6 地址

## 部署步骤

### 1. 首先运行测试脚本
在部署主脚本之前，建议先运行测试脚本来检查环境：

```bash
# 上传测试脚本
scp pcdn-ipv6-sync-test.rsc admin@your-router-ip:/
```

在 RouterOS 终端中执行：
```ros
/import pcdn-ipv6-sync-test.rsc
```

检查日志输出，确保：
- IPv4 地址列表 PCDN-P1 和 PCDN-P2 存在且有内容
- ARP 表中有对应的动态条目
- IPv6 Neighbor 表中有对应的条目

### 2. 上传并运行安全脚本（推荐首次使用）
```bash
# 通过 SCP 上传安全脚本文件
scp pcdn-ipv6-sync-safe.rsc admin@your-router-ip:/
```

在 RouterOS 终端中执行：
```ros
/import pcdn-ipv6-sync-safe.rsc
```

**安全脚本特点**：
- 只添加新的 IPv6 地址，不删除现有地址
- 包含更强的重复检查机制
- 适合首次部署和测试

### 3. 运行完整功能脚本（可选）
如果安全脚本运行正常，可以使用包含清理功能的完整版本：

```bash
# 上传完整功能脚本
scp pcdn-ipv6-sync.rsc admin@your-router-ip:/
```

在 RouterOS 终端中执行：
```ros
/import pcdn-ipv6-sync.rsc
```

### 3. 创建调度任务（可选）
如果需要定期自动执行同步，可以创建调度任务：
```ros
/system scheduler add name="pcdn-ipv6-sync" interval=5m on-event="/import pcdn-ipv6-sync.rsc" comment="PCDN IPv6 sync every 5 minutes"
```

## 手动执行
直接在 RouterOS 终端中运行：
```ros
/import pcdn-ipv6-sync.rsc
```

## 前置条件

### 1. 确保 IPv4 地址列表存在
脚本会处理以下 IPv4 防火墙地址列表：
- `PCDN-P1`
- `PCDN-P2`

如果这些列表不存在，脚本会跳过相应的处理。

### 2. 确保 IPv6 功能已启用
```ros
/ipv6 settings set accept-router-advertisements=yes accept-redirects=yes
```

### 3. 确保有活跃的 IPv6 Neighbor 条目
脚本依赖 IPv6 Neighbor 表中的条目来查找 MAC 地址对应的 IPv6 地址。

## 日志监控

### 查看脚本执行日志
```ros
/log print where topics~"info" and message~"PCDN-Sync"
```

### 日志级别说明
- **info**: 脚本启动/结束、添加/移除 IPv6 地址的操作
- **warning**: MAC 地址未找到、IPv6 GUA 未找到等警告
- **debug**: 详细的处理过程（需要启用 debug 日志级别）

### 启用 debug 日志（可选）
```ros
/system logging add topics=script,debug action=memory
```

## 验证同步结果

### 查看 IPv6 防火墙地址列表
```ros
/ipv6 firewall address-list print where list="PCDN-P1"
/ipv6 firewall address-list print where list="PCDN-P2"
```

### 查看同步添加的条目
```ros
/ipv6 firewall address-list print where comment~"Synced from"
```

## 故障排除

### 1. 脚本执行出现语法错误
**解决方法**：
- 确保使用的是修复后的脚本版本（v1.1）
- 先运行测试脚本 `pcdn-ipv6-sync-test.rsc` 检查环境
- 检查 RouterOS 版本是否为 v7.x

### 2. 脚本没有添加任何 IPv6 地址
**可能原因**：
- IPv4 地址列表为空
- ARP 表中没有对应的 MAC 地址条目
- IPv6 Neighbor 表中没有对应的条目
- 找到的 IPv6 地址都是 Link-Local 地址（fe80::/10）

**检查方法**：
```ros
# 先运行测试脚本
/import pcdn-ipv6-sync-test.rsc

# 检查 IPv4 地址列表
/ip firewall address-list print where list="PCDN-P1"

# 检查 ARP 表
/ip arp print where dynamic=yes

# 检查 IPv6 Neighbor 表
/ipv6 neighbor print
```

### 3. IPv6 地址列表被意外清空
**可能原因**：
- 脚本在预存阶段出现错误
- 字符串处理导致的问题

**解决方法**：
- 立即停止脚本执行
- 从备份中恢复 IPv6 地址列表
- 使用测试脚本验证环境后再重新运行

### 4. IPv6 地址没有被清理
**可能原因**：
- 脚本执行过程中出现错误
- IPv6 地址是手动添加的（不是通过脚本同步的）

**解决方法**：
- 检查日志中的错误信息
- 手动清理不需要的 IPv6 地址

## 自定义配置

### 修改目标列表名称
编辑脚本中的 `targetListNames` 变量：
```ros
:local targetListNames {"YOUR-LIST-1"; "YOUR-LIST-2"; "YOUR-LIST-3"}
```

### 修改 GUA 筛选条件
如果需要排除更多类型的 IPv6 地址（如 ULA fc00::/7），可以修改 GUA 筛选逻辑：
```ros
# 在脚本中找到这部分代码并修改
:local isGUA true
:if ([:pick $neighborIPv6Address 0 4] = "fe80") do={
    :set isGUA false
}
# 添加更多筛选条件
:if ([:pick $neighborIPv6Address 0 2] = "fc" or [:pick $neighborIPv6Address 0 2] = "fd") do={
    :set isGUA false
}
```

### 调整日志级别
修改脚本中的日志输出级别：
- 将 `:log debug` 改为 `:log info` 以显示更多信息
- 将 `:log warning` 改为 `:log info` 以降低警告级别

## 性能考虑
- 脚本执行时间取决于 IPv4 地址列表的大小和 ARP/Neighbor 表的大小
- 建议在网络流量较低的时间段执行
- 对于大型网络，可以考虑增加执行间隔或分批处理

## 安全注意事项
- 脚本会修改防火墙地址列表，请确保在测试环境中验证后再部署到生产环境
- 建议定期备份 RouterOS 配置
- 监控脚本执行日志，及时发现异常情况