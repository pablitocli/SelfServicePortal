#Requires -Version 7.2
<#
.SYNOPSIS
    TEMPLATE - copy to automation/handlers/<Verb-Noun>.ps1 and reference it from a catalog item.
.DESCRIPTION
    Handler contract:
      * Declare one parameter per catalog input "name" (+ each execution.fixedParameters key).
      * Declare -Context to receive: RequestId, Requester, Site (config), VIServer (open session), RollbackOnFailure.
      * Log with Write-JobLog "text" -Level INFO|STEP|OK|WARN|ERROR (shown live in the portal).
      * Return a hashtable: it is displayed as the request result. Throw to fail the request.
      * Be idempotent where possible and validate before changing anything.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Site,
    [Parameter(Mandatory)] [string] $Example,
    [Parameter(Mandatory)] $Context
)

$ErrorActionPreference = 'Stop'
$vi = $Context.VIServer

Write-JobLog -Level STEP "Doing something with '$Example' on $($vi.Name)"
# ... PowerCLI work here, always with -Server $vi ...
Write-JobLog -Level OK 'Done.'

return [ordered]@{
    Example   = $Example
    NextSteps = @('Describe any manual follow-up here.')
}
