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

# --- 将192.168.66.0/24网段IP地址绑定到internal-mgmt接口 ---
:log info "Checking for 192.168.66.0/24 network addresses to bind to internal-mgmt..."

# 遍历所有IP地址配置
:foreach ipAddress in=[/ip address find] do={
    :local addressInfo [/ip address get $ipAddress address]
    :local currentInterface [/ip address get $ipAddress interface]
    
    # 检查是否为192.168.66.0/24网段
    :if ([:pick $addressInfo 0 [:find $addressInfo "/"]] ~ "192\\.168\\.66\\.[0-9]+") do={
        :log info "Found 192.168.66.0/24 address $addressInfo on interface $currentInterface"
        
        # 检查是否已经绑定到internal-mgmt接口
        :if ($currentInterface != "internal-mgmt") do={
            :do {
                # 将IP地址重新绑定到internal-mgmt接口
                /ip address set $ipAddress interface=internal-mgmt
                :log info "Moved 192.168.66.0/24 address $addressInfo from $currentInterface to internal-mgmt"
            } on-error={
                :log warning "Failed to move address $addressInfo to internal-mgmt interface"
            }
        } else={
            :log info "Address $addressInfo is already on internal-mgmt interface"
        }
    }
}

:log info "Adaptive interface configuration script finished."
# End of script source