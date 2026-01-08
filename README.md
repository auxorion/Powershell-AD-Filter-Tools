# PowerShell AD Filter Tools

Small helper utilities for building safe, readable Active Directory filter strings.

## New-AdFilterOrExpression

Builds an `-or` expression for a single AD property using `-eq` or `-like`.

### Why this exists
When you need to query AD for *multiple possible values* of the same attribute, you often end up building filter strings manually. This function generates the filter safely and consistently (including escaping apostrophes).

## Usage

```powershell
. .\src\New-AdFilterOrExpression.ps1

$filter = New-AdFilterOrExpression -Property 'sAMAccountName' -Values @('rperez','jsmith','adoe')
Get-ADUser -Filter $filter
