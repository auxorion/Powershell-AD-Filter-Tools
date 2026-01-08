function New-AdFilterOrExpression {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Property,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Values,

        [ValidateSet('eq','like')]
        [string]$Operator = 'eq'
    )

    $escaped = $Values | ForEach-Object { $_.Replace("'", "''") }

    $parts = $escaped | ForEach-Object {
        if ($Operator -eq 'like') { "($Property -like '$_')" }
        else { "($Property -eq '$_')" }
    }

    return ($parts -join ' -or ')
}
