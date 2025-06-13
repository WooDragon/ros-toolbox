# RouterOS IPv4/IPv6 防火墙地址列表同步脚本 - 设计架构

**目标：** 设计一个 RouterOS v7 脚本的逻辑架构，用于同步 IPv4 防火墙地址列表 `PCDN-P1` 和 `PCDN-P2` 中的 IP 地址到对应的、同名的 IPv6 防火墙地址列表。同步逻辑基于 MAC 地址：从 ARP 表获取 IPv4 的 MAC，然后在 IPv6 Neighbor 表中找到该 MAC 对应的全局单播 IPv6 地址 (GUA)，并将其添加到相应的 IPv6 列表中。脚本每次运行时，还会清理 IPv6 列表中不再有效的条目。

**核心确认点：**

1.  **IPv6 地址选择：** 只添加全局单播地址 (GUA)，主要通过排除 Link-Local 地址 (`fe80::/10`) 来实现。
2.  **失效 IPv6 地址清理：** 如果一个 IPv6 地址之前被同步添加，但在当前运行周期中，无法通过 IPv4 -> ARP (MAC) -> IPv6 Neighbor (GUA) 的链条重新找到它，则从 IPv6 地址列表中移除。
3.  **查找失败处理：** 任何查找失败（如 ARP 无条目，Neighbor 无条目）都将记录到 RouterOS 的系统日志中。
4.  **列表名称：** IPv4 和 IPv6 防火墙地址列表使用完全相同的名称 (`PCDN-P1`, `PCDN-P2`)。

**详细逻辑架构：**

1.  **脚本初始化与配置**
    *   **定义常量/变量：**
        *   `targetListNames`: 数组，包含 `"PCDN-P1"`, `"PCDN-P2"`。这些名称将同时用于 IPv4 和 IPv6 防火墙地址列表。
        *   `logPrefix`: 字符串，用于日志消息，例如 `"[PCDN-Sync] "`。
    *   **日志记录：** 脚本开始时，记录一条信息日志，如 `"$logPrefix Script logic initiated."`。
    *   **全局活动 IPv6 集合 (`activeGlobalIPv6sThisRun`)：** 初始化一个临时数据结构（概念上是一个集合或数组，确保唯一性），用于存储本次同步周期中所有被识别为有效的、应保留的 GUA IPv6 地址。此集合跨越所有处理的列表，用于最终的清理步骤。

2.  **预存当前 IPv6 列表状态 (为清理做准备)**
    *   对于 `targetListNames` 中的每一个列表名 (`currentListName`):
        *   **逻辑：** 从 IPv6 防火墙的地址列表 `currentListName` 中，获取所有当前存在的 IPv6 地址。
        *   **存储：** 将这些获取到的 IPv6 地址存储在一个临时数据结构中（例如，`initialIPv6MembersIn_[currentListName]`），与该列表名关联。这用于后续比较哪些地址是“陈旧”的。

3.  **核心同步逻辑 (对每个目标列表进行迭代)**
    *   循环遍历 `targetListNames` 中的每个列表名 (`currentListName`)。
    *   记录日志，如 `"$logPrefix Processing list: $currentListName (for both IPv4 and IPv6 sync)."`。
    *   **遍历 IPv4 地址：**
        *   **逻辑：** 从 IPv4 防火墙的地址列表 `currentListName` 中获取所有 IPv4 地址。
        *   对于每个获取到的 `ipv4Address`：
            *   **查找 MAC 地址：**
                *   **逻辑：** 在系统的 ARP 表中查找与 `ipv4Address` 关联的 MAC 地址。优先考虑动态获取且有效的条目。
                *   **结果：** 得到 `macAddress`。
                *   **处理未找到：** 如果未找到有效的 MAC 地址，记录警告日志（例如 `"$logPrefix MAC not found for IPv4 $ipv4Address in list $currentListName."`），然后跳过此 `ipv4Address`，继续处理下一个。
            *   **查找并处理 IPv6 地址 (GUA)：**
                *   **逻辑：** 如果成功获取到 `macAddress`，则使用此 `macAddress` 在系统的 IPv6 Neighbor 表中查找对应的 IPv6 地址。
                *   对于每个找到的 `neighborIPv6Address`：
                    *   **筛选 GUA：** 判断 `neighborIPv6Address` 是否为全局单播地址 (GUA)。主要通过检查其是否不属于 Link-Local (`fe80::/10`) 范围。
                    *   **处理 GUA：** 如果是 GUA：
                        1.  **添加到全局活动集合：** 将此 `neighborIPv6Address` 添加到 `activeGlobalIPv6sThisRun` 集合中（确保唯一性，如果已存在则不重复添加）。
                        2.  **添加到 IPv6 防火墙列表：** 检查 IPv6 防火墙的地址列表 `currentListName` 中是否已存在此 `neighborIPv6Address`。如果不存在，则将其添加进去，并可选择性地添加一个描述性备注（例如，来源 IPv4 和 MAC）。记录添加操作的日志。
                *   **处理未找到 GUA：** 如果遍历完所有 Neighbor 条目后，没有为该 `macAddress` 找到任何 GUA IPv6 地址，记录警告日志（例如 `"$logPrefix No GUA IPv6 neighbor found for MAC $macAddress (from IPv4 $ipv4Address in list $currentListName)."`）。

4.  **清理 IPv6 地址列表**
    *   再次循环遍历 `targetListNames` 中的每个列表名 (`currentListNameToClean`)。
    *   **逻辑：** 获取在步骤 2 中为 `currentListNameToClean` 预存的初始 IPv6 地址成员集合 (`initialIPv6MembersIn_[currentListNameToClean]`)。
    *   对于 `initialIPv6MembersIn_[currentListNameToClean]` 中的每一个 `oldIPv6Address`：
        *   **检查保留状态：** 判断 `oldIPv6Address` 是否存在于全局的 `activeGlobalIPv6sThisRun` 集合中。
        *   **执行移除：** 如果 `oldIPv6Address` **不**存在于 `activeGlobalIPv6sThisRun` 中，则意味着它在本轮同步中不再有效。从 IPv6 防火墙的地址列表 `currentListNameToClean` 中移除此 `oldIPv6Address`。记录移除操作的日志。

5.  **脚本结束**
    *   记录脚本逻辑执行完毕的日志，例如 `"$logPrefix Script logic finished."`。

**程序设计架构图 (Mermaid - 概念流程):**

```mermaid
graph TD
    Start((开始脚本逻辑)) --> LogStart[记录: 脚本启动];

    subgraph 初始化阶段
        DefineTargets[定义目标列表名: PCDN-P1, PCDN-P2]
        InitActiveSet[创建空集合: activeGlobalIPv6sThisRun]
    end
    LogStart --> DefineTargets --> InitActiveSet;

    subgraph 预存IPv6列表状态 (为清理)
        LoopListsForPreStore{循环目标列表名} -- 为每个列表 --> GetInitialIPv6Members[获取IPv6列表当前成员] --> StoreInitialMembers[存储初始成员]
    end
    InitActiveSet --> LoopListsForPreStore;

    MainLoop{循环目标列表名 (currentListName)};
    StoreInitialMembers -- 完成所有预存 --> MainLoop;

    subgraph "核心同步处理 (对每个 currentListName)"
        LogListProcessing[记录: 开始处理 currentListName]
        GetIPv4s[获取IPv4列表 'currentListName' 中的所有IPv4地址 (ipv4Address)]
        LogListProcessing --> GetIPv4s

        ForEachIPv4{对每个 ipv4Address}
        GetIPv4s --> ForEachIPv4

        FindMAC[查找ipv4Address的MAC (macAddress) 从ARP表]
        ForEachIPv4 -- ipv4Address --> FindMAC

        subgraph "MAC 地址处理"
            direction LR
            MACFound{MAC有效?}
            FindMAC --> MACFound
            MACFound -- 是 --> FindIPv6[查找macAddress的IPv6从Neighbor表]
            MACFound -- 否 --> LogMACFail[记录: MAC未找到] --> ForEachIPv4
        end

        subgraph "IPv6 地址处理 (对每个找到的 neighborIPv6Address)"
            direction LR
            IsGUA{是GUA?}
            FindIPv6 --> IsGUA
            IsGUA -- 是 --> AddToGlobalActive[添加GUA到'activeGlobalIPv6sThisRun'] --> AddToIPv6ListConditionally[如果GUA不在IPv6列表'currentListName'中则添加] --> ForEachIPv4
            IsGUA -- 否 --> ForEachIPv4
            FindIPv6 -- 未找到GUA --> LogNoGUAFail[记录: 未找到GUA] --> ForEachIPv4
        end
    end
    MainLoop -- 为每个列表 --> LogListProcessing;


    CleanupPhase{开始清理阶段};
    ForEachIPv4 -- 所有列表处理完成 --> CleanupPhase;

    subgraph "清理IPv6地址列表 (对每个目标列表)"
        LoopListsForCleanup{循环目标列表名 (listToClean)}
        CleanupPhase --> LoopListsForCleanup

        GetStoredMembers[获取'listToClean'的预存初始IPv6成员 (oldIPv6Address)]
        LoopListsForCleanup -- 每个列表 --> GetStoredMembers

        ForEachOldIPv6{对每个 oldIPv6Address}
        GetStoredMembers --> ForEachOldIPv6

        IsInActiveSet{oldIPv6Address 在 'activeGlobalIPv6sThisRun' 中?}
        ForEachOldIPv6 -- oldIPv6Address --> IsInActiveSet
        IsInActiveSet -- 否 (失效) --> RemoveFromIPv6List[从IPv6列表'listToClean'移除oldIPv6Address] --> LogRemoval[记录: 移除] --> ForEachOldIPv6
        IsInActiveSet -- 是 (保留) --> ForEachOldIPv6
    end

    ForEachOldIPv6 -- 所有列表清理完成 --> LogEnd[记录: 脚本结束];
    LogEnd --> End((结束脚本逻辑));