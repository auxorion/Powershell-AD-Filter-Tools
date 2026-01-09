<#
.SYNOPSIS
Idempotent shared mailbox provisioning + repair workflow (single-file version).

.DESCRIPTION
Converges a shared mailbox to a known-good standard. Safe to re-run. Validation-first.
Designed for operators: one command, clear output, optional wait animation.

.PARAMETER MailboxUpn
Shared mailbox UPN / email address (mailbox1@domain.com)

.PARAMETER DelegationGroup
AD group (or directory group) used for delegation mapping

.PARAMETER MultiGeo
Enable multi-geo / location attribute configuration

.PARAMETER GeoLocation
A geo value (e.g., ISO3 "FRA"). Validated against GeoCsvPath if available.

.PARAMETER GeoCsvPath
Optional CSV path used to validate GeoLocation codes.

.PARAMETER ForceGeoLocation
If GeoCsvPath is unavailable or code not found, continue anyway (warns).

.PARAMETER Wait
Enable wait animation for replication/provisioning gates.

.PARAMETER Mode
Mock or Live. Mock demonstrates logic without requiring tenant access.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-SharedMailboxProvisioning {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$MailboxUpn,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DelegationGroup,

        [switch]$MultiGeo,

        [string]$GeoLocation,

        [string]$GeoCsvPath = "\\server\share\geo_codes.csv",  # example default; adjust to taste

        [switch]$ForceGeoLocation,

        [switch]$Wait,

        [ValidateSet('Mock','Live')]
        [string]$Mode = 'Mock'
    )

    Write-Header "Shared Mailbox Provisioning (Idempotent) — $Mode"

    $inputValidation = Test-Input -MailboxUpn $MailboxUpn -DelegationGroup $DelegationGroup -MultiGeo:$MultiGeo -GeoLocation $GeoLocation
    if (-not $inputValidation.Ok) {
        Write-Fail $inputValidation.Message
        return
    }

    $geo = $null
    if ($MultiGeo) {
        $geo = Resolve-GeoLocation -GeoLocation $GeoLocation -GeoCsvPath $GeoCsvPath -Force:$ForceGeoLocation
        if (-not $geo.Ok) { Write-Fail $geo.Message; return }
        Write-Info "Multi-Geo: ON ($($geo.Value.GeoLocation))" 
    }
    else {
        Write-Info "Multi-Geo: OFF"
    }

    Write-Info "Mailbox: $MailboxUpn"
    Write-Info "Delegation Group: $DelegationGroup"
    Write-Info ""

    # --- Steps (idempotent ensure flow) ---
    $steps = @(
        @{ Name="Ensure directory mailbox user object"; Action={ Ensure-MailboxUser -MailboxUpn $MailboxUpn -Mode $Mode } }
        @{ Name="Ensure delegation group exists"; Action={ Ensure-DelegationGroup -GroupName $DelegationGroup -Mode $Mode } }
        @{ Name="Ensure base attributes"; Action={ Ensure-BaseAttributes -MailboxUpn $MailboxUpn -Mode $Mode } }
        @{ Name="Replication gate (directory → cloud)"; Action={ Ensure-ReplicationGate -MailboxUpn $MailboxUpn -Wait:$Wait -Mode $Mode } }
        @{ Name="Ensure geo/location attributes"; Action={ Ensure-GeoAttributes -MailboxUpn $MailboxUpn -Geo $geo.Value -MultiGeo:$MultiGeo -Mode $Mode } }
        @{ Name="Ensure temp license assigned"; Action={ Ensure-LicenseAssigned -MailboxUpn $MailboxUpn -Sku "TEMP_MAILBOX_SKU" -Mode $Mode } }
        @{ Name="Mailbox provisioning gate"; Action={ Ensure-MailboxProvisioned -MailboxUpn $MailboxUpn -Wait:$Wait -Mode $Mode } }
        @{ Name="Ensure shared mailbox"; Action={ Ensure-SharedMailbox -MailboxUpn $MailboxUpn -Mode $Mode } }
        @{ Name="Ensure mailbox permissions (FullAccess + SendAs)"; Action={ Ensure-MailboxPermissions -MailboxUpn $MailboxUpn -DelegationGroup $DelegationGroup -Mode $Mode } }
        @{ Name="Ensure license removed"; Action={ Ensure-LicenseRemoved -MailboxUpn $MailboxUpn -Sku "TEMP_MAILBOX_SKU" -Mode $Mode } }
        @{ Name="Ensure protocol settings (IMAP/MAPI)"; Action={ Ensure-ProtocolSettings -MailboxUpn $MailboxUpn -Mode $Mode } }
    )

    foreach ($s in $steps) {
        Write-Step $s.Name
        try {
            $r = & $s.Action
            Write-StepResult -Result $r
            if ($r.Status -eq "Failed") { break }
        }
        catch {
            Write-Fail $_.Exception.Message
            break
        }
    }

    Write-Header "Done"
}

# -----------------------
# Helpers (private style)
# -----------------------

function Test-Input {
    param([string]$MailboxUpn,[string]$DelegationGroup,[switch]$MultiGeo,[string]$GeoLocation)

    if ($MailboxUpn -notmatch '^[^@]+@[^@]+\.[^@]+$') {
        return @{ Ok=$false; Message="MailboxUpn does not look like an email address: $MailboxUpn" }
    }

    if ($MultiGeo -and [string]::IsNullOrWhiteSpace($GeoLocation)) {
        return @{ Ok=$false; Message="MultiGeo was specified but GeoLocation is empty. Example: -MultiGeo -GeoLocation 'FRA'." }
    }

    return @{ Ok=$true; Message="OK" }
}

function Resolve-GeoLocation {
    param([Parameter(Mandatory)][string]$GeoLocation,[string]$GeoCsvPath,[switch]$Force)

    # If no CSV path provided, we can only proceed with force.
    if ([string]::IsNullOrWhiteSpace($GeoCsvPath)) {
        if ($Force) {
            Write-Warn "GeoCsvPath not provided. Forcing GeoLocation '$GeoLocation' without validation."
            return @{ Ok=$true; Value=@{ GeoLocation=$GeoLocation; Validated=$false } }
        }
        return @{ Ok=$false; Message="GeoCsvPath not provided; cannot validate GeoLocation '$GeoLocation'. Use -ForceGeoLocation to override." }
    }

    if (-not (Test-Path $GeoCsvPath)) {
        if ($Force) {
            Write-Warn "GeoCsvPath not found ($GeoCsvPath). Forcing GeoLocation '$GeoLocation' without validation."
            return @{ Ok=$true; Value=@{ GeoLocation=$GeoLocation; Validated=$false } }
        }
        return @{ Ok=$false; Message="GeoCsvPath not found: $GeoCsvPath. Use -ForceGeoLocation to override." }
    }

    $rows = Import-Csv $GeoCsvPath
    $match = $rows | Where-Object {
        ($_.ISO3 -eq $GeoLocation) -or
        ($_.ISO2 -eq $GeoLocation) -or
        ($_.GeoCode -eq $GeoLocation)
    } | Select-Object -First 1

    if (-not $match) {
        if ($Force) {
            Write-Warn "GeoLocation '$GeoLocation' not found in CSV. Forcing without validation."
            return @{ Ok=$true; Value=@{ GeoLocation=$GeoLocation; Validated=$false } }
        }
        return @{ Ok=$false; Message="GeoLocation '$GeoLocation' not found in Geo CSV. Use -ForceGeoLocation to override." }
    }

    # Normalize: return what matched + any extra fields if you want later
    return @{
        Ok=$true
        Value=@{
            GeoLocation=$GeoLocation
            Validated=$true
            Country=$match.Country
            ISO2=$match.ISO2
            ISO3=$match.ISO3
            GeoCode=$match.GeoCode
        }
    }
}

# -----------------------
# Ensure-* steps (idempotent)
# Each returns: @{ Status="Ok|Changed|Skipped|Failed"; Message="..."; Details=@{} }
# -----------------------

function Ensure-MailboxUser {
    param([string]$MailboxUpn,[string]$Mode)

    if (Test-MailboxUserExists -MailboxUpn $MailboxUpn -Mode $Mode) {
        return @{ Status="Ok"; Message="Mailbox user exists."; Details=@{} }
    }

    if ($PSCmdlet.ShouldProcess($MailboxUpn, "Create mailbox user")) {
        # TODO: Live: New-ADUser (or equivalent) + attribute basics
        return Invoke-MockOrLive -Mode $Mode -OnMock { } -OnLive { } -ChangedMessage "Created mailbox user."
    }

    return @{ Status="Skipped"; Message="WhatIf: would create mailbox user."; Details=@{} }
}

function Ensure-DelegationGroup {
    param([string]$GroupName,[string]$Mode)

    if (Test-GroupExists -GroupName $GroupName -Mode $Mode) {
        return @{ Status="Ok"; Message="Delegation group exists."; Details=@{} }
    }

    if ($PSCmdlet.ShouldProcess($GroupName, "Create delegation group")) {
        # TODO: Live: New-ADGroup (or equivalent)
        return Invoke-MockOrLive -Mode $Mode -OnMock { } -OnLive { } -ChangedMessage "Created delegation group."
    }

    return @{ Status="Skipped"; Message="WhatIf: would create delegation group."; Details=@{} }
}

function Ensure-BaseAttributes {
    param([string]$MailboxUpn,[string]$Mode)

    $delta = Get-BaseAttributeDelta -MailboxUpn $MailboxUpn -Mode $Mode
    if (-not $delta.NeedsChange) {
        return @{ Status="Ok"; Message="Base attributes already compliant."; Details=@{} }
    }

    if ($PSCmdlet.ShouldProcess($MailboxUpn, "Set base attributes")) {
        # TODO: Live: set description/displayName/proxyAddresses/UPN/etc.
        return Invoke-MockOrLive -Mode $Mode -OnMock { } -OnLive { } -ChangedMessage "Updated base attributes."
    }

    return @{ Status="Skipped"; Message="WhatIf: would set base attributes."; Details=$delta }
}

function Ensure-ReplicationGate {
    param([string]$MailboxUpn,[switch]$Wait,[string]$Mode)

    # In real life you might poll until the object is visible in cloud / synced state.
    if ($Wait) { Show-WaitAnimation -Seconds 3 -Label "Waiting for directory replication (simulated)" }
    return @{ Status="Ok"; Message="Replication gate satisfied."; Details=@{} }
}

function Ensure-GeoAttributes {
    param([string]$MailboxUpn,[hashtable]$Geo,[switch]$MultiGeo,[string]$Mode)

    if (-not $MultiGeo) {
        return @{ Status="Ok"; Message="Multi-Geo not requested. Skipping."; Details=@{} }
    }

    $delta = Get-GeoDelta -MailboxUpn $MailboxUpn -Geo $Geo -Mode $Mode
    if (-not $delta.NeedsChange) {
        return @{ Status="Ok"; Message="Geo attributes already compliant."; Details=@{} }
    }

    if ($PSCmdlet.ShouldProcess($MailboxUpn, "Set geo attributes")) {
        # TODO: Live: Set-ADUser geo attributes / group linkage / country codes
        $msg = if ($Geo.Validated) {
            "Set geo attributes ($($Geo.Country) / $($Geo.ISO2)/$($Geo.ISO3))."
        } else {
            "Set geo attributes (forced GeoLocation: $($Geo.GeoLocation))."
        }
        return Invoke-MockOrLive -Mode $Mode -OnMock { } -OnLive { } -ChangedMessage $msg
    }

    return @{ Status="Skipped"; Message="WhatIf: would set geo attributes."; Details=$delta }
}

function Ensure-LicenseAssigned {
    param([string]$MailboxUpn,[string]$Sku,[string]$Mode)

    if (Test-LicenseAssigned -MailboxUpn $MailboxUpn -Sku $Sku -Mode $Mode) {
        return @{ Status="Ok"; Message="License already assigned."; Details=@{} }
    }

    if ($PSCmdlet.ShouldProcess($MailboxUpn, "Assign license $Sku")) {
        # TODO: Live: Graph assign license
        return Invoke-MockOrLive -Mode $Mode -OnMock { } -OnLive { } -ChangedMessage "Assigned temp license ($Sku)."
    }

    return @{ Status="Skipped"; Message="WhatIf: would assign license."; Details=@{} }
}

function Ensure-MailboxProvisioned {
    param([string]$MailboxUpn,[switch]$Wait,[string]$Mode)

    if (Test-MailboxExists -MailboxUpn $MailboxUpn -Mode $Mode) {
        return @{ Status="Ok"; Message="Mailbox exists in EXO."; Details=@{} }
    }

    if ($Wait) { Show-WaitAnimation -Seconds 3 -Label "Waiting for mailbox provisioning (simulated)" }

    # In mock mode we can mark it as provisioned, in live you’d poll.
    return Invoke-MockOrLive -Mode $Mode -OnMock { Set-MockMailboxProvisioned -MailboxUpn $MailboxUpn } -OnLive { } -ChangedMessage "Mailbox now present (post-wait)."
}

function Ensure-SharedMailbox {
    param([string]$MailboxUpn,[string]$Mode)

    if (Test-IsSharedMailbox -MailboxUpn $MailboxUpn -Mode $Mode) {
        return @{ Status="Ok"; Message="Mailbox already shared."; Details=@{} }
    }

    if ($PSCmdlet.ShouldProcess($MailboxUpn, "Convert to shared")) {
        # TODO: Live: Set-Mailbox -Type Shared
        return Invoke-MockOrLive -Mode $Mode -OnMock { Set-MockMailboxShared -MailboxUpn $MailboxUpn } -OnLive { } -ChangedMessage "Converted to shared mailbox."
    }

    return @{ Status="Skipped"; Message="WhatIf: would convert to shared."; Details=@{} }
}

function Ensure-MailboxPermissions {
    param([string]$MailboxUpn,[string]$DelegationGroup,[string]$Mode)

    $delta = Get-PermissionDelta -MailboxUpn $MailboxUpn -DelegationGroup $DelegationGroup -Mode $Mode
    if (-not $delta.NeedsChange) {
        return @{ Status="Ok"; Message="Permissions already compliant (FullAccess + SendAs)."; Details=@{} }
    }

    if ($PSCmdlet.ShouldProcess($MailboxUpn, "Apply FullAccess + SendAs")) {
        # TODO: Live: Add-MailboxPermission, Add-RecipientPermission, etc.
        return Invoke-MockOrLive -Mode $Mode -OnMock { Set-MockMailboxPerms -MailboxUpn $MailboxUpn -DelegationGroup $DelegationGroup } -OnLive { } -ChangedMessage "Applied/verified mailbox permissions."
    }

    return @{ Status="Skipped"; Message="WhatIf: would apply permissions."; Details=$delta }
}

function Ensure-LicenseRemoved {
    param([string]$MailboxUpn,[string]$Sku,[string]$Mode)

    if (-not (Test-LicenseAssigned -MailboxUpn $MailboxUpn -Sku $Sku -Mode $Mode)) {
        return @{ Status="Ok"; Message="License already removed."; Details=@{} }
    }

    if ($PSCmdlet.ShouldProcess($MailboxUpn, "Remove license $Sku")) {
        # TODO: Live: Graph remove license
        return Invoke-MockOrLive -Mode $Mode -OnMock { } -OnLive { } -ChangedMessage "Removed temp license ($Sku)."
    }

    return @{ Status="Skipped"; Message="WhatIf: would remove license."; Details=@{} }
}

function Ensure-ProtocolSettings {
    param([string]$MailboxUpn,[string]$Mode)

    $delta = Get-ProtocolDelta -MailboxUpn $MailboxUpn -Mode $Mode
    if (-not $delta.NeedsChange) {
        return @{ Status="Ok"; Message="IMAP/MAPI already compliant."; Details=@{} }
    }

    if ($PSCmdlet.ShouldProcess($MailboxUpn, "Set IMAP/MAPI")) {
        # TODO: Live: Set-CASMailbox or equivalent settings
        return Invoke-MockOrLive -Mode $Mode -OnMock { } -OnLive { } -ChangedMessage "Set IMAP/MAPI to standard."
    }

    return @{ Status="Skipped"; Message="WhatIf: would set IMAP/MAPI."; Details=$delta }
}

# -----------------------
# Test/Get delta stubs (replace with real checks later)
# -----------------------

function Test-MailboxUserExists { param([string]$MailboxUpn,[string]$Mode) return ($Mode -eq 'Mock') ? $false : $false }
function Test-GroupExists { param([string]$GroupName,[string]$Mode) return ($Mode -eq 'Mock') ? $false : $false }
function Get-BaseAttributeDelta { param([string]$MailboxUpn,[string]$Mode) return @{ NeedsChange=$true } }
function Get-GeoDelta { param([string]$MailboxUpn,[hashtable]$Geo,[string]$Mode) return @{ NeedsChange=$true } }
function Test-LicenseAssigned { param([string]$MailboxUpn,[string]$Sku,[string]$Mode) return $false }
function Test-MailboxExists { param([string]$MailboxUpn,[string]$Mode) return $false }
function Test-IsSharedMailbox { param([string]$MailboxUpn,[string]$Mode) return $false }
function Get-PermissionDelta { param([string]$MailboxUpn,[string]$DelegationGroup,[string]$Mode) return @{ NeedsChange=$true } }
function Get-ProtocolDelta { param([string]$MailboxUpn,[string]$Mode) return @{ NeedsChange=$true } }

# -----------------------
# Mock helpers (so Mock mode shows the full experience)
# -----------------------
$script:MockState = @{
    Provisioned = @{}
    Shared = @{}
    Perms = @{}
}

function Set-MockMailboxProvisioned { param([string]$MailboxUpn) $script:MockState.Provisioned[$MailboxUpn] = $true }
function Set-MockMailboxShared { param([string]$MailboxUpn) $script:MockState.Shared[$MailboxUpn] = $true }
function Set-MockMailboxPerms { param([string]$MailboxUpn,[string]$DelegationGroup) $script:MockState.Perms[$MailboxUpn] = $DelegationGroup }

# -----------------------
# Output helpers (your signature)
# -----------------------
function Write-Header($Text) { Write-Host "`n=== $Text ===" }
function Write-Info($Text)   { Write-Host $Text }
function Write-Warn($Text)   { Write-Host "⚠️  $Text" -ForegroundColor Yellow }
function Write-Fail($Text)   { Write-Host "❌ $Text" -ForegroundColor Red }
function Write-Step($Text)   { Write-Host "`n→ $Text" -ForegroundColor Cyan }

function Write-StepResult {
    param([hashtable]$Result)

    switch ($Result.Status) {
        "Ok"      { Write-Host "✅ $($Result.Message)" -ForegroundColor Green }
        "Changed" { Write-Host "🛠️  $($Result.Message)" -ForegroundColor Green }
        "Skipped" { Write-Host "⚠️  $($Result.Message)" -ForegroundColor Yellow }
        "Failed"  { Write-Host "❌ $($Result.Message)" -ForegroundColor Red }
        default   { Write-Host "• $($Result.Message)" }
    }
}

function Show-WaitAnimation {
    param([int]$Seconds = 10, [string]$Label = "Waiting")

    $frames = @("✉️  ", " ✉️ ", "  ✉️")
    $end = (Get-Date).AddSeconds($Seconds)
    $i = 0
    while ((Get-Date) -lt $end) {
        $frame = $frames[$i % $frames.Count]
        Write-Host -NoNewline "`r$frame $Label..."
        Start-Sleep -Milliseconds 250
        $i++
    }
    Write-Host "`r✅ $Label done.       "
}

function Invoke-MockOrLive {
    param(
        [Parameter(Mandatory)][ValidateSet('Mock','Live')][string]$Mode,
        [Parameter(Mandatory)][scriptblock]$OnMock,
        [Parameter(Mandatory)][scriptblock]$OnLive,
        [Parameter(Mandatory)][string]$ChangedMessage
    )

    if ($Mode -eq 'Mock') {
        & $OnMock
        return @{ Status="Changed"; Message="$ChangedMessage (mock)"; Details=@{} }
    }

    & $OnLive
    return @{ Status="Changed"; Message=$ChangedMessage; Details=@{} }
}
