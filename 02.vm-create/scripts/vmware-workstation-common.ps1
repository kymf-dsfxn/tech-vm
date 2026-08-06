Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path (Get-Location) -ChildPath $Path))
}

function Resolve-VMwareBinary {
    param(
        [Parameter(Mandatory)]
        [string]$ToolName,

        [string]$ExplicitPath
    )

    if ($ExplicitPath) {
        $resolvedExplicitPath = Resolve-FullPath -Path $ExplicitPath
        if (-not (Test-Path -LiteralPath $resolvedExplicitPath -PathType Leaf)) {
            throw "Requested $ToolName binary does not exist: $resolvedExplicitPath"
        }
        return $resolvedExplicitPath
    }

    $command = Get-Command -Name $ToolName -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidateRoots = @(
        ${env:ProgramFiles(x86)},
        $env:ProgramFiles
    ) | Where-Object { $_ }

    foreach ($root in $candidateRoots) {
        $candidatePath = Join-Path -Path $root -ChildPath "VMware\VMware Workstation\$ToolName"
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            return $candidatePath
        }
    }

    throw "Unable to locate $ToolName. Add it to PATH or pass an explicit path."
}

function New-VMwareVirtualDisk {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateRange(1, 65535)]
        [int]$SizeGB,

        [Parameter(Mandatory)]
        [string]$VdiskManagerPath,

        [ValidateSet('monolithicSparse', 'splitSparse')]
        [string]$Provisioning = 'monolithicSparse'
    )

    $resolvedDiskPath = Resolve-FullPath -Path $Path
    $diskDirectory = Split-Path -Path $resolvedDiskPath -Parent
    if (-not (Test-Path -LiteralPath $diskDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $diskDirectory -Force | Out-Null
    }

    if (Test-Path -LiteralPath $resolvedDiskPath) {
        throw "Virtual disk already exists: $resolvedDiskPath"
    }

    $diskTypeCode = switch ($Provisioning) {
        'monolithicSparse' { '0' }
        'splitSparse' { '1' }
    }

    $arguments = @(
        '-c',
        '-s', "$SizeGB`GB",
        '-a', 'scsi',
        '-t', $diskTypeCode,
        $resolvedDiskPath
    )

    if ($PSCmdlet.ShouldProcess($resolvedDiskPath, "Create ${SizeGB}GB VMware virtual disk")) {
        & $VdiskManagerPath @arguments
        if ($LASTEXITCODE -ne 0) {
            throw "vmware-vdiskmanager failed creating $resolvedDiskPath (exit code $LASTEXITCODE)."
        }
    }
}

function New-VmxLine {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [AllowEmptyString()]
        [string]$Value
    )

    return '{0} = "{1}"' -f $Name, $Value
}

function New-VMwareVmxContent {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Definition
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((New-VmxLine -Name '.encoding' -Value 'UTF-8'))
    $lines.Add((New-VmxLine -Name 'config.version' -Value '8'))
    $lines.Add((New-VmxLine -Name 'virtualHW.version' -Value $Definition.VirtualHardwareVersion))
    $lines.Add((New-VmxLine -Name 'virtualHW.productCompatibility' -Value 'hosted'))
    $lines.Add((New-VmxLine -Name 'displayName' -Value $Definition.DisplayName))
    $lines.Add((New-VmxLine -Name 'guestOS' -Value $Definition.GuestOs))
    $lines.Add((New-VmxLine -Name 'firmware' -Value $Definition.Firmware))
    $lines.Add((New-VmxLine -Name 'numvcpus' -Value $Definition.CpuCount))
    $lines.Add((New-VmxLine -Name 'cpuid.coresPerSocket' -Value $Definition.CoresPerSocket))
    $lines.Add((New-VmxLine -Name 'memsize' -Value $Definition.MemoryMB))
    $lines.Add((New-VmxLine -Name 'bios.bootDelay' -Value $Definition.BootDelayMs))
    $lines.Add((New-VmxLine -Name 'ulm.disableMitigations' -Value $Definition.DisableSideChannelMitigations))
    $lines.Add((New-VmxLine -Name 'uefi.secureBoot.enabled' -Value $Definition.SecureBootEnabled))
    $lines.Add((New-VmxLine -Name 'pciBridge0.present' -Value 'TRUE'))
    $lines.Add((New-VmxLine -Name 'pciBridge4.present' -Value 'TRUE'))
    $lines.Add((New-VmxLine -Name 'pciBridge4.virtualDev' -Value 'pcieRootPort'))
    $lines.Add((New-VmxLine -Name 'pciBridge4.functions' -Value '8'))
    $lines.Add((New-VmxLine -Name 'pciBridge5.present' -Value 'TRUE'))
    $lines.Add((New-VmxLine -Name 'pciBridge5.virtualDev' -Value 'pcieRootPort'))
    $lines.Add((New-VmxLine -Name 'pciBridge5.functions' -Value '8'))
    $lines.Add((New-VmxLine -Name 'pciBridge6.present' -Value 'TRUE'))
    $lines.Add((New-VmxLine -Name 'pciBridge6.virtualDev' -Value 'pcieRootPort'))
    $lines.Add((New-VmxLine -Name 'pciBridge6.functions' -Value '8'))
    $lines.Add((New-VmxLine -Name 'pciBridge7.present' -Value 'TRUE'))
    $lines.Add((New-VmxLine -Name 'pciBridge7.virtualDev' -Value 'pcieRootPort'))
    $lines.Add((New-VmxLine -Name 'pciBridge7.functions' -Value '8'))
    $lines.Add((New-VmxLine -Name 'vmci0.present' -Value 'TRUE'))
    $lines.Add((New-VmxLine -Name 'hpet0.present' -Value 'TRUE'))
    $lines.Add((New-VmxLine -Name 'floppy0.present' -Value 'FALSE'))
    $lines.Add((New-VmxLine -Name 'sound.present' -Value 'FALSE'))
    $lines.Add((New-VmxLine -Name 'isolation.tools.hgfs.disable' -Value $(if ($Definition.EnableHostSharedFolder -eq 'TRUE') { 'FALSE' } else { 'TRUE' })))

    if ($Definition.EnableHostSharedFolder -eq 'TRUE') {
        $lines.Add((New-VmxLine -Name 'sharedFolder0.present' -Value 'TRUE'))
        $lines.Add((New-VmxLine -Name 'sharedFolder0.enabled' -Value 'TRUE'))
        $lines.Add((New-VmxLine -Name 'sharedFolder0.readAccess' -Value 'TRUE'))
        $lines.Add((New-VmxLine -Name 'sharedFolder0.writeAccess' -Value 'TRUE'))
        $lines.Add((New-VmxLine -Name 'sharedFolder0.hostPath' -Value $Definition.HostSharedFolderPath))
        $lines.Add((New-VmxLine -Name 'sharedFolder0.guestName' -Value $Definition.HostSharedFolderName))
        $lines.Add((New-VmxLine -Name 'sharedFolder0.expiration' -Value 'never'))
        $lines.Add((New-VmxLine -Name 'sharedFolder.maxNum' -Value '1'))
    }

    $lines.Add((New-VmxLine -Name 'mks.enable3d' -Value 'FALSE'))
    $lines.Add((New-VmxLine -Name 'svga.vramSize' -Value '8388608'))
    $lines.Add((New-VmxLine -Name 'svga.maxWidth' -Value $Definition.DisplayWidth))
    $lines.Add((New-VmxLine -Name 'svga.maxHeight' -Value $Definition.DisplayHeight))
    $lines.Add((New-VmxLine -Name 'numDisplays' -Value $Definition.DisplayCount))
    $lines.Add((New-VmxLine -Name 'ethernet0.present' -Value 'TRUE'))
    $lines.Add((New-VmxLine -Name 'ethernet0.virtualDev' -Value $Definition.NetworkAdapter))
    $lines.Add((New-VmxLine -Name 'ethernet0.connectionType' -Value $Definition.NetworkType))
    $lines.Add((New-VmxLine -Name 'ethernet0.addressType' -Value 'generated'))

    if ($Definition.NetworkType -eq 'custom' -and $Definition.NetworkName) {
        $lines.Add((New-VmxLine -Name 'ethernet0.vnet' -Value $Definition.NetworkName))
    }

    $lines.Add((New-VmxLine -Name 'scsi0.present' -Value 'TRUE'))
    $lines.Add((New-VmxLine -Name 'scsi0.virtualDev' -Value $Definition.ScsiController))

    for ($index = 0; $index -lt $Definition.Disks.Count; $index++) {
        $unitNumber = $index
        $disk = $Definition.Disks[$index]
        $lines.Add((New-VmxLine -Name "scsi0:${unitNumber}.present" -Value 'TRUE'))
        $lines.Add((New-VmxLine -Name "scsi0:${unitNumber}.fileName" -Value $disk.FileName))
        $lines.Add((New-VmxLine -Name "scsi0:${unitNumber}.deviceType" -Value 'scsi-hardDisk'))
    }

    if ($Definition.IsoPath) {
        $lines.Add((New-VmxLine -Name 'sata0.present' -Value 'TRUE'))
        $lines.Add((New-VmxLine -Name 'sata0:0.present' -Value 'TRUE'))
        $lines.Add((New-VmxLine -Name 'sata0:0.deviceType' -Value 'cdrom-image'))
        $lines.Add((New-VmxLine -Name 'sata0:0.startConnected' -Value 'TRUE'))
        $lines.Add((New-VmxLine -Name 'sata0:0.fileName' -Value $Definition.IsoPath))
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Invoke-VMwareVmrun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VmrunPath,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    & $VmrunPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "vmrun failed with exit code $LASTEXITCODE."
    }
}