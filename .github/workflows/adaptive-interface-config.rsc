# Script name: adaptive-interface-config
# Start of script source
:log info "Adaptive interface configuration script started."

# 等待系统完全初始化(可选)
:delay 5s

# --- 固定配置部分 ---
/interface ethernet
# 设置固定接口名称
:do {
    set [ find default-name=ether2 ] disable-running-check=no name=internal-mgmt
} on-error={ :log warning "Failed to configure ether2 as internal-mgmt" }
:do {
    set [ find default-name=ether3 ] disable-running-check=no name=internal-vms
} on-error={ :log warning "Failed to configure ether3 as internal-vms" }
:do {
    set [ find default-name=ether1 ] disable-running-check=no name=uplink0-onboard
} on-error={ :log warning "Failed to configure ether1 as uplink0-onboard" }
:log info "Attempted static configuration for specific interfaces."

# --- 动态配置 uplink 部分 ---
:local uplinkCounter 1
:local interfaceNumberToCheck 4
# 根据您的硬件调整, 一般RouterBOARD以太网口不会超过24-28个, 64是个非常安全的上限
:local maxEtherInterfacesToScan 64

:while ($interfaceNumberToCheck <= $maxEtherInterfacesToScan) do={
    :local currentDefaultName ("ether" . $interfaceNumberToCheck)
    # 确保在正确的路径下查找接口ID
    :local foundInterfaceId [/interface ethernet find default-name=$currentDefaultName]

    # 更稳健的检查方式
    :if ($foundInterfaceId != "" && $foundInterfaceId != nil) do={
        :local newUplinkName ("uplink" . $uplinkCounter)
        
        # 检查是否已存在同名接口(避免命名冲突)
        :if ([:len [/interface find name=$newUplinkName]] = 0) do={
            # 确保在正确的路径下设置接口属性
            :do {
                /interface ethernet set $foundInterfaceId name=$newUplinkName disable-running-check=no
                :log info "Configured '$currentDefaultName' as '$newUplinkName'."
                :set uplinkCounter ($uplinkCounter + 1)
                # 短暂延迟以确保配置生效
                :delay 100ms
            } on-error={ 
                :log warning "Failed to rename $currentDefaultName to $newUplinkName" 
            }
        } else={
            :log warning "Interface name $newUplinkName already exists, skipping rename of $currentDefaultName"
            :set uplinkCounter ($uplinkCounter + 1)
        }
    }

    :set interfaceNumberToCheck ($interfaceNumberToCheck + 1)
}

# 日志记录动态配置结果
:if (($uplinkCounter - 1) > 0) do={
    :log info ("Dynamically configured " . ($uplinkCounter - 1) . " uplink interface(s).")
} else={
    :log info "No additional dynamic uplink interfaces found or configured."
}

:log info "Adaptive interface configuration script finished."
# End of script source