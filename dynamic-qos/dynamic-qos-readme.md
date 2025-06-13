# RouterOS 动态QoS流量整形脚本

## 概述

这个脚本专为RouterOS v7设计，用于对PCDN流量进行智能化的动态流量整形，通过时间段划分和随机化策略来规避ISP检测。

## 主要功能

### 1. 分时段流量控制
- **晚高峰时段 (18:00-23:59)**：P1队列全速，P2队列限制为父接口的66%
- **凌晨时段 (00:10-09:30)**：P1+P2总限速不超过父接口的33%
- **工作时段 (09:30-18:00)**：P1+P2总限速不超过父接口的50%

### 2. 随机化压制策略
- 在非晚高峰时段对P1和P2队列进行随机限速
- 凌晨时段：P1(10-20%), P2(10-13%)
- 工作时段：P1(20-30%), P2(15-20%)
- 确保总限速不超过时段上限

### 3. 平滑过渡机制
- 单次调整幅度限制在父接口限速的10%以内
- 避免速率突变，减少检测风险

### 4. 智能突发控制
- 动态设置burst-limit为max-limit的1.5倍
- burst-threshold设为max-limit的75%
- 固定burst-time为30秒

## 脚本修正内容

### 语法修正
1. **函数定义**：改为局部函数，避免全局变量冲突
2. **随机数生成**：使用系统时间作为随机种子，实现真正的随机化
3. **时间比较**：将时间转换为秒数进行比较，支持跨午夜时间段
4. **函数调用**：修正函数调用语法，使用方括号调用
5. **错误处理**：添加队列操作的错误处理机制

### 逻辑优化
1. **队列查找**：修正P2队列查找的语法错误
2. **数学运算**：避免整数除法精度丢失
3. **比例分配**：改进总限速超限时的比例调整算法
4. **类型检查**：添加带宽值的类型检查

## 配置参数

### 时间段设置
```routeros
:local timePeakStart 18:00:00      # 晚高峰开始时间
:local timePeakEnd 23:59:59        # 晚高峰结束时间
:local timeMidnightStart 00:10:00  # 凌晨时段开始时间
:local timeMidnightEnd 09:30:00    # 凌晨时段结束时间
:local timeWorkStart 09:30:00      # 工作时段开始时间
:local timeWorkEnd 18:00:00        # 工作时段结束时间
```

### 速率比例设置
```routeros
:local p2PeakRatio 66              # P2晚高峰速率比例(%)
:local midnightTotalRatio 25       # 凌晨时段总限速比例(%)
:local workTotalRatio 50           # 工作时段总限速比例(%)
```

### 随机化范围
```routeros
# 凌晨时段随机范围
:local midnightP1MinRatio 10
:local midnightP1MaxRatio 20
:local midnightP2MinRatio 10
:local midnightP2MaxRatio 13

# 工作时段随机范围
:local workP1MinRatio 20
:local workP1MaxRatio 30
:local workP2MinRatio 15
:local workP2MaxRatio 20
```

## 安装和使用

### 1. 上传脚本
将 `dynamic-qos.rsc` 文件上传到RouterOS设备的Files目录

### 2. 创建计划任务
```routeros
/system scheduler
add name="DynamicQoS" interval=5m on-event="/import dynamic-qos.rsc" \
    start-date=jan/01/1970 start-time=00:00:00
```

### 3. 手动测试
```routeros
/import dynamic-qos.rsc
```

### 4. 查看日志
```routeros
/log print where topics~"info"
```

## 队列要求

脚本要求队列结构符合以下条件：
1. 存在包含 `qos-up-pcdn-p1` 标记的队列
2. 存在包含 `qos-up-pcdn-p2` 标记的队列
3. P1和P2队列必须有相同的父队列
4. 父队列必须设置了 `max-limit` 参数

## 监控和调试

### 启用日志
脚本默认启用日志记录，可通过修改以下参数关闭：
```routeros
:local enableLogging false
```

### 日志内容
- 脚本运行时间和当前时段
- 每个队列的限速调整情况
- 错误和警告信息

## 注意事项

1. **队列命名**：确保PCDN队列的packet-mark包含指定的标记字符串
2. **父队列设置**：父队列的max-limit将作为计算基准
3. **执行频率**：建议5分钟执行一次，避免过于频繁的调整
4. **系统资源**：脚本会遍历所有队列，在队列数量很多时可能影响性能
5. **时间同步**：确保RouterOS系统时间准确

## 实现目标检查

✅ **时间段划分**：实现了三个明确的时间段策略
✅ **随机压制**：在非晚高峰时段实现随机化限速
✅ **平滑调整**：避免速率突变的平滑过渡机制
✅ **队列遍历**：自动发现和处理所有PCDN队列
✅ **错误处理**：添加了队列操作的错误处理
✅ **日志记录**：完整的操作日志记录
✅ **配置灵活性**：所有参数都可在脚本顶部配置

## 版本信息

- **版本**：1.0
- **兼容性**：RouterOS v7.x
- **语言**：RouterOS Script
- **最后更新**：2025年6月