$ErrorActionPreference='Stop'
$source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'AppHost.cs'))
Add-Type -TypeDefinition $source -ReferencedAssemblies @([System.Management.Automation.PowerShell].Assembly.Location,'System.Windows.Forms.dll','System.Core.dll') -OutputAssembly (Join-Path $PSScriptRoot 'CET4Desktop.exe') -OutputType WindowsApplication
