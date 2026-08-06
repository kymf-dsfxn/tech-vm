[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('start', 'stop', 'reset', 'suspend', 'pause', 'unpause', 'snapshot', 'deleteSnapshot', 'listSnapshots', 'clone', 'getGuestIPAddress', 'list')]
    [string]$Action,

    [string]$VmxPath,

    [ValidateSet('gui', 'nogui')]
    [string]$StartMode = 'nogui',

    [ValidateSet('soft', 'hard')]
    [string]$StopMode = 'soft',

    [string]$SnapshotName,

    [string]$ClonePath,

    [ValidateSet('full', 'linked')]
    [string]$CloneType = 'full',

    [int]$WaitForGuestSeconds = 30,

    [string]$VmrunPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDirectory = Split-Path -Path $PSCommandPath -Parent
. (Join-Path -Path $scriptDirectory -ChildPath 'vmware-workstation-common.ps1')

$resolvedVmrunPath = Resolve-VMwareBinary -ToolName 'vmrun.exe' -ExplicitPath $VmrunPath

$resolvedVmxPath = $null
if ($VmxPath) {
    $resolvedVmxPath = Resolve-FullPath -Path $VmxPath
    if (-not (Test-Path -LiteralPath $resolvedVmxPath -PathType Leaf)) {
        throw "VMX file does not exist: $resolvedVmxPath"
    }
}

$arguments = @('-T', 'ws')

switch ($Action) {
    'list' {
        $arguments += 'list'
    }
    'start' {
        if (-not $resolvedVmxPath) { throw 'VmxPath is required for start.' }
        $arguments += @('start', $resolvedVmxPath, $StartMode)
    }
    'stop' {
        if (-not $resolvedVmxPath) { throw 'VmxPath is required for stop.' }
        $arguments += @('stop', $resolvedVmxPath, $StopMode)
    }
    'reset' {
        if (-not $resolvedVmxPath) { throw 'VmxPath is required for reset.' }
        $arguments += @('reset', $resolvedVmxPath, $StopMode)
    }
    'suspend' {
        if (-not $resolvedVmxPath) { throw 'VmxPath is required for suspend.' }
        $arguments += @('suspend', $resolvedVmxPath, $StopMode)
    }
    'pause' {
        if (-not $resolvedVmxPath) { throw 'VmxPath is required for pause.' }
        $arguments += @('pause', $resolvedVmxPath)
    }
    'unpause' {
        if (-not $resolvedVmxPath) { throw 'VmxPath is required for unpause.' }
        $arguments += @('unpause', $resolvedVmxPath)
    }
    'snapshot' {
        if (-not $resolvedVmxPath) { throw 'VmxPath is required for snapshot.' }
        if (-not $SnapshotName) { throw 'SnapshotName is required for snapshot.' }
        $arguments += @('snapshot', $resolvedVmxPath, $SnapshotName)
    }
    'deleteSnapshot' {
        if (-not $resolvedVmxPath) { throw 'VmxPath is required for deleteSnapshot.' }
        if (-not $SnapshotName) { throw 'SnapshotName is required for deleteSnapshot.' }
        $arguments += @('deleteSnapshot', $resolvedVmxPath, $SnapshotName)
    }
    'listSnapshots' {
        if (-not $resolvedVmxPath) { throw 'VmxPath is required for listSnapshots.' }
        $arguments += @('listSnapshots', $resolvedVmxPath)
    }
    'clone' {
        if (-not $resolvedVmxPath) { throw 'VmxPath is required for clone.' }
        if (-not $ClonePath) { throw 'ClonePath is required for clone.' }
        $resolvedClonePath = Resolve-FullPath -Path $ClonePath
        $arguments += @('clone', $resolvedVmxPath, $resolvedClonePath, $CloneType)
    }
    'getGuestIPAddress' {
        if (-not $resolvedVmxPath) { throw 'VmxPath is required for getGuestIPAddress.' }
        $arguments += @('getGuestIPAddress', $resolvedVmxPath, '-wait')
    }
}

Invoke-VMwareVmrun -VmrunPath $resolvedVmrunPath -Arguments $arguments