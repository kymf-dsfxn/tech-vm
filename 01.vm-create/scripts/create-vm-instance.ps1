[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,

    [string]$VmName,

    [string]$VmRootPath,

    [string]$IsoPath,

    [ValidateRange(1, 256)]
    [int]$CpuCount = 4,

    [ValidateRange(1, 256)]
    [int]$CoresPerSocket = 4,

    [ValidateRange(256, 2097152)]
    [int]$MemoryMB = 12288,

    [ValidateRange(1, 65535)]
    [int]$CoreDiskSizeGB = 32,

    [ValidateRange(0, 16)]
    [int]$DataDiskCount = 1,

    [ValidateRange(1, 65535)]
    [int]$DataDiskSizeGB = 512,

    [ValidateSet('bridged', 'nat', 'hostonly', 'custom')]
    [string]$NetworkType = 'nat',

    [string]$NetworkName,

    [ValidateSet('ubuntu-64')]
    [string]$GuestOs = 'ubuntu-64',

    [ValidateSet('efi', 'bios')]
    [string]$Firmware = 'efi',

    [ValidateRange(0, 600000)]
    [int]$BootDelayMs = 5000,

    [ValidateRange(640, 8192)]
    [int]$DisplayWidth = 1280,

    [ValidateRange(480, 4320)]
    [int]$DisplayHeight = 1024,

    [ValidateRange(1, 8)]
    [int]$DisplayCount = 1,

    [ValidateSet('vmxnet3')]
    [string]$NetworkAdapter = 'vmxnet3',

    [ValidateSet('pvscsi')]
    [string]$ScsiController = 'pvscsi',

    [ValidateSet('21', '20', '19')]
    [string]$VirtualHardwareVersion = '21',

    [ValidateSet('monolithicSparse', 'splitSparse')]
    [string]$DiskProvisioning = 'monolithicSparse',

    [string]$VdiskManagerPath,

    [switch]$EnableSecureBoot,

    [switch]$DisableSideChannelMitigations,

    [bool]$EnableHostSharedFolder = $true,

    [string]$HostSharedFolderPath = 'S:\local-data',

    [string]$HostSharedFolderName = 'local-data',

    [switch]$Force,

    [switch]$SkipDiskCreation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDirectory = Split-Path -Path $PSCommandPath -Parent
. (Join-Path -Path $scriptDirectory -ChildPath 'vmware-workstation-common.ps1')

function Test-ConfigProperty {
    param(
        [Parameter(Mandatory)]
        [object]$Config,

        [Parameter(Mandatory)]
        [string]$Name
    )

    return $null -ne $Config.PSObject.Properties[$Name]
}

function Get-SettingValue {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [hashtable]$BoundParameters,

        [object]$Config,

        $DefaultValue,

        [switch]$Required
    )

    if ($BoundParameters.ContainsKey($Name)) {
        return $BoundParameters[$Name]
    }

    if ($null -ne $Config -and (Test-ConfigProperty -Config $Config -Name $Name)) {
        return $Config.$Name
    }

    if ($Required) {
        throw "A value is required for $Name. Provide it via the parameter file or the command line."
    }

    return $DefaultValue
}

function Assert-InRange {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [int]$Value,

        [Parameter(Mandatory)]
        [int]$Minimum,

        [Parameter(Mandatory)]
        [int]$Maximum
    )

    if ($Value -lt $Minimum -or $Value -gt $Maximum) {
        throw "$Name must be between $Minimum and $Maximum. Actual value: $Value"
    }
}

function Assert-OneOf {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Value,

        [Parameter(Mandatory)]
        [string[]]$AllowedValues
    )

    if ($AllowedValues -notcontains $Value) {
        throw "$Name must be one of: $($AllowedValues -join ', '). Actual value: $Value"
    }
}

$config = $null
if ($ConfigPath) {
    $resolvedConfigPath = Resolve-FullPath -Path $ConfigPath
    if (-not (Test-Path -LiteralPath $resolvedConfigPath -PathType Leaf)) {
        throw "Config file does not exist: $resolvedConfigPath"
    }

    $config = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json
}

$VmName = [string](Get-SettingValue -Name 'VmName' -BoundParameters $PSBoundParameters -Config $config -Required)
$VmRootPath = [string](Get-SettingValue -Name 'VmRootPath' -BoundParameters $PSBoundParameters -Config $config -Required)
$IsoPath = [string](Get-SettingValue -Name 'IsoPath' -BoundParameters $PSBoundParameters -Config $config -DefaultValue $IsoPath)
$CpuCount = [int](Get-SettingValue -Name 'CpuCount' -BoundParameters $PSBoundParameters -Config $config -DefaultValue $CpuCount)
$CoresPerSocket = [int](Get-SettingValue -Name 'CoresPerSocket' -BoundParameters $PSBoundParameters -Config $config -DefaultValue $CoresPerSocket)
$MemoryMB = [int](Get-SettingValue -Name 'MemoryMB' -BoundParameters $PSBoundParameters -Config $config -DefaultValue $MemoryMB)
$CoreDiskSizeGB = [int](Get-SettingValue -Name 'CoreDiskSizeGB' -BoundParameters $PSBoundParameters -Config $config -DefaultValue $CoreDiskSizeGB)
$DataDiskCount = [int](Get-SettingValue -Name 'DataDiskCount' -BoundParameters $PSBoundParameters -Config $config -DefaultValue $DataDiskCount)
$DataDiskSizeGB = [int](Get-SettingValue -Name 'DataDiskSizeGB' -BoundParameters $PSBoundParameters -Config $config -DefaultValue $DataDiskSizeGB)
$NetworkType = [string](Get-SettingValue -Name 'NetworkType' -BoundParameters $PSBoundParameters -Config $config -DefaultValue $NetworkType)
$NetworkName = [string](Get-SettingValue -Name 'NetworkName' -BoundParameters $PSBoundParameters -Config $config -DefaultValue $NetworkName)
$GuestOs = [string](Get-SettingValue -Name 'GuestOs' -BoundParameters $PSBoundParameters -Config $config -DefaultValue $GuestOs)
$Firmware = [string](Get-SettingValue -Name 'Firmware' -BoundParameters $PSBoundParameters -Config $config -DefaultValue $Firmware)
$BootDelayMs = [int](Get-SettingValue -Name 'BootDelayMs' -BoundParameters $PSBoundParameters -Config $config -DefaultValue $BootDelayMs)
$DisplayWidth = [int](Get-SettingValue -Name 'DisplayWidth' -BoundParameters $PSBoundParameters -Config $config -DefaultValue $DisplayWidth)
$DisplayHeight = [int](Get-SettingValue -Name 'DisplayHeight' -BoundParameters $PSBoundParameters -Config $config -DefaultValue $DisplayHeight)
$DisplayCount = [int](Get-SettingValue -Name 'DisplayCount' -BoundParameters $PSBoundParameters -Config $config -DefaultValue $DisplayCount)
$NetworkAdapter = [string](Get-SettingValue -Name 'NetworkAdapter' -BoundParameters $PSBoundParameters -Config $config -DefaultValue $NetworkAdapter)
$ScsiController = [string](Get-SettingValue -Name 'ScsiController' -BoundParameters $PSBoundParameters -Config $config -DefaultValue $ScsiController)
$VirtualHardwareVersion = [string](Get-SettingValue -Name 'VirtualHardwareVersion' -BoundParameters $PSBoundParameters -Config $config -DefaultValue $VirtualHardwareVersion)
$DiskProvisioning = [string](Get-SettingValue -Name 'DiskProvisioning' -BoundParameters $PSBoundParameters -Config $config -DefaultValue $DiskProvisioning)
$VdiskManagerPath = [string](Get-SettingValue -Name 'VdiskManagerPath' -BoundParameters $PSBoundParameters -Config $config -DefaultValue $VdiskManagerPath)
$EnableSecureBoot = [bool](Get-SettingValue -Name 'EnableSecureBoot' -BoundParameters $PSBoundParameters -Config $config -DefaultValue $EnableSecureBoot.IsPresent)
$DisableSideChannelMitigations = [bool](Get-SettingValue -Name 'DisableSideChannelMitigations' -BoundParameters $PSBoundParameters -Config $config -DefaultValue $DisableSideChannelMitigations.IsPresent)
$EnableHostSharedFolder = [bool](Get-SettingValue -Name 'EnableHostSharedFolder' -BoundParameters $PSBoundParameters -Config $config -DefaultValue $EnableHostSharedFolder)
$HostSharedFolderPath = [string](Get-SettingValue -Name 'HostSharedFolderPath' -BoundParameters $PSBoundParameters -Config $config -DefaultValue $HostSharedFolderPath)
$HostSharedFolderName = [string](Get-SettingValue -Name 'HostSharedFolderName' -BoundParameters $PSBoundParameters -Config $config -DefaultValue $HostSharedFolderName)

Assert-InRange -Name 'CpuCount' -Value $CpuCount -Minimum 1 -Maximum 256
Assert-InRange -Name 'CoresPerSocket' -Value $CoresPerSocket -Minimum 1 -Maximum 256
Assert-InRange -Name 'MemoryMB' -Value $MemoryMB -Minimum 256 -Maximum 2097152
Assert-InRange -Name 'CoreDiskSizeGB' -Value $CoreDiskSizeGB -Minimum 1 -Maximum 65535
Assert-InRange -Name 'DataDiskCount' -Value $DataDiskCount -Minimum 0 -Maximum 16
Assert-InRange -Name 'DataDiskSizeGB' -Value $DataDiskSizeGB -Minimum 1 -Maximum 65535
Assert-InRange -Name 'BootDelayMs' -Value $BootDelayMs -Minimum 0 -Maximum 600000
Assert-InRange -Name 'DisplayWidth' -Value $DisplayWidth -Minimum 640 -Maximum 8192
Assert-InRange -Name 'DisplayHeight' -Value $DisplayHeight -Minimum 480 -Maximum 4320
Assert-InRange -Name 'DisplayCount' -Value $DisplayCount -Minimum 1 -Maximum 8
Assert-OneOf -Name 'NetworkType' -Value $NetworkType -AllowedValues @('bridged', 'nat', 'hostonly', 'custom')
Assert-OneOf -Name 'GuestOs' -Value $GuestOs -AllowedValues @('ubuntu-64')
Assert-OneOf -Name 'Firmware' -Value $Firmware -AllowedValues @('efi', 'bios')
Assert-OneOf -Name 'NetworkAdapter' -Value $NetworkAdapter -AllowedValues @('vmxnet3')
Assert-OneOf -Name 'ScsiController' -Value $ScsiController -AllowedValues @('pvscsi')
Assert-OneOf -Name 'VirtualHardwareVersion' -Value $VirtualHardwareVersion -AllowedValues @('21', '20', '19')
Assert-OneOf -Name 'DiskProvisioning' -Value $DiskProvisioning -AllowedValues @('monolithicSparse', 'splitSparse')

#if (($CpuCount % $CoresPerSocket) -ne 0) {
#    throw 'CpuCount must be divisible by CoresPerSocket.'
#}

if ($NetworkType -eq 'custom' -and -not $NetworkName) {
    throw 'NetworkName is required when NetworkType is custom.'
}

if ($EnableHostSharedFolder) {
    if ([string]::IsNullOrWhiteSpace($HostSharedFolderPath)) {
        throw 'HostSharedFolderPath is required when EnableHostSharedFolder is true.'
    }

    if ([string]::IsNullOrWhiteSpace($HostSharedFolderName)) {
        throw 'HostSharedFolderName is required when EnableHostSharedFolder is true.'
    }
}

$resolvedVmRootPath = Resolve-FullPath -Path $VmRootPath
$vmDirectory = Join-Path -Path $resolvedVmRootPath -ChildPath $VmName
$vmxPath = Join-Path -Path $vmDirectory -ChildPath "$VmName.vmx"

if (Test-Path -LiteralPath $vmDirectory) {
    if (-not $Force) {
        throw "Target VM directory already exists: $vmDirectory"
    }

    if ($PSCmdlet.ShouldProcess($vmDirectory, 'Remove existing VM directory')) {
        Remove-Item -LiteralPath $vmDirectory -Recurse -Force
    }
}

$resolvedIsoPath = $null
if ($IsoPath) {
    $resolvedIsoPath = Resolve-FullPath -Path $IsoPath
    if (-not (Test-Path -LiteralPath $resolvedIsoPath -PathType Leaf)) {
        throw "ISO file does not exist: $resolvedIsoPath"
    }
}

$resolvedVdiskManagerPath = $null
if (-not $SkipDiskCreation) {
    $resolvedVdiskManagerPath = Resolve-VMwareBinary -ToolName 'vmware-vdiskmanager.exe' -ExplicitPath $VdiskManagerPath
}

if ($PSCmdlet.ShouldProcess($vmDirectory, 'Create VMware VM directory')) {
    New-Item -ItemType Directory -Path $vmDirectory -Force | Out-Null
}

$disks = [System.Collections.Generic.List[hashtable]]::new()
$coreDiskName = "$VmName-core.vmdk"
$coreDiskPath = Join-Path -Path $vmDirectory -ChildPath $coreDiskName
$disks.Add(@{ FileName = $coreDiskName; Path = $coreDiskPath; SizeGB = $CoreDiskSizeGB })

for ($index = 1; $index -le $DataDiskCount; $index++) {
    $dataDiskName = '{0}-data-{1:00}.vmdk' -f $VmName, $index
    $dataDiskPath = Join-Path -Path $vmDirectory -ChildPath $dataDiskName
    $disks.Add(@{ FileName = $dataDiskName; Path = $dataDiskPath; SizeGB = $DataDiskSizeGB })
}

if (-not $SkipDiskCreation) {
    foreach ($disk in $disks) {
        $diskParams = @{
            Path = $disk.Path
            SizeGB = $disk.SizeGB
            VdiskManagerPath = $resolvedVdiskManagerPath
            Provisioning = $DiskProvisioning
            WhatIf = $WhatIfPreference
        }

        New-VMwareVirtualDisk @diskParams
    }
}

$definition = @{
    VirtualHardwareVersion = $VirtualHardwareVersion
    DisplayName = $VmName
    GuestOs = $GuestOs
    Firmware = $Firmware
    CpuCount = [string]$CpuCount
    CoresPerSocket = [string]$CoresPerSocket
    MemoryMB = [string]$MemoryMB
    BootDelayMs = [string]$BootDelayMs
    DisableSideChannelMitigations = $(if ($DisableSideChannelMitigations) { 'TRUE' } else { 'FALSE' })
    SecureBootEnabled = $(if ($EnableSecureBoot) { 'TRUE' } else { 'FALSE' })
    DisplayWidth = [string]$DisplayWidth
    DisplayHeight = [string]$DisplayHeight
    DisplayCount = [string]$DisplayCount
    NetworkAdapter = $NetworkAdapter
    NetworkType = $NetworkType
    NetworkName = $NetworkName
    ScsiController = $ScsiController
    Disks = $disks
    IsoPath = $resolvedIsoPath
    EnableHostSharedFolder = $(if ($EnableHostSharedFolder) { 'TRUE' } else { 'FALSE' })
    HostSharedFolderPath = $HostSharedFolderPath
    HostSharedFolderName = $HostSharedFolderName
}

$vmxContent = New-VMwareVmxContent -Definition $definition
if ($PSCmdlet.ShouldProcess($vmxPath, 'Write VMX file')) {
    Set-Content -LiteralPath $vmxPath -Value $vmxContent -Encoding ASCII
}

[pscustomobject]@{
    VmName = $VmName
    VmDirectory = $vmDirectory
    VmxPath = $vmxPath
    ConfigPath = $ConfigPath
    CoreDiskPath = $coreDiskPath
    DataDiskCount = $DataDiskCount
    IsoPath = $resolvedIsoPath
    DiskCreationSkipped = [bool]$SkipDiskCreation
}