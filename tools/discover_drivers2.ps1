<#
  Read-only discovery: where Growth (RMV3) stores the delivery driver of a POS bill.
  SELECT only (NOLOCK). Nothing is written to Growth. Output: drivers_discovery.txt next to this script.
  Usage (from the folder that has growth_pass.txt):  powershell -ExecutionPolicy Bypass -File discover_drivers.ps1
#>
param(
  [string]$SqlServer = 'GROWTHSERVER,1433',
  [string]$SqlDb = 'RMV3',
  [string]$SqlUser = 'platform_reader'
)
$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Out = Join-Path $Here 'drivers_discovery2.txt'
Set-Content -Path $Out -Value '' -Encoding UTF8
function W([string]$s) { Add-Content -Path $Out -Value $s -Encoding UTF8; Write-Host $s }

$gp = (Get-Content (Join-Path $Here 'growth_pass.txt') -Raw -Encoding UTF8).Trim()
$c = New-Object System.Data.SqlClient.SqlConnection "Server=$SqlServer;Database=$SqlDb;User ID=$SqlUser;Password=$gp;Connect Timeout=10;ApplicationIntent=ReadOnly;Application Name=platform-discover"
$gp = $null
$c.Open()

function Q([string]$title, [string]$sql, [int]$max = 200) {
  W ''; W "===== $title ====="
  try {
    $k = $c.CreateCommand(); $k.CommandText = $sql; $k.CommandTimeout = 120
    $r = $k.ExecuteReader(); $n = 0
    while ($r.Read() -and $n -lt $max) {
      $parts = for ($i = 0; $i -lt $r.FieldCount; $i++) { $v = $r.GetValue($i); if ($v -is [DBNull]) { $v = '' }; '{0}={1}' -f $r.GetName($i), $v }
      W ($parts -join ' | '); $n++
    }
    $r.Close()
    if ($n -eq 0) { W '(no rows)' }
  } catch { W ("ERR: " + $_.Exception.Message) }
}


$ss = "4:20261019112830:171411:260020171425:DESKTOP-8PV6JGK"
foreach ($t in 'KitchDelivAllot','KitchDelivRec','KitchDelivBillsMark','KitchDelivCustInfo','KitchDelivAllSalType') {
  Q "$t columns" "SELECT c.name AS col, t.name AS typ FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id WHERE c.object_id = OBJECT_ID('$t') ORDER BY c.column_id" 100
  Q "$t latest 4 rows" "SELECT TOP 4 * FROM $t WITH (NOLOCK) ORDER BY 1 DESC" 4
}
foreach ($t in 'KitchDelivAllot','KitchDelivRec','KitchDelivBillsMark','KitchDelivCustInfo') {
  Q "$t rows for bill 260020171425" "DECLARE @s nvarchar(4000) = N''; SELECT @s = @s + N' OR CAST([' + c.name + N'] AS nvarchar(200)) IN (N''$ss'', N''260020171425'', N''481995'')' FROM sys.columns c JOIN sys.types y ON y.user_type_id = c.user_type_id WHERE c.object_id = OBJECT_ID('$t') AND y.name IN ('varchar','nvarchar','int','bigint','char','nchar'); SET @s = N'SELECT TOP 5 * FROM $t WITH (NOLOCK) WHERE 1=0' + @s; EXEC sp_executesql @s" 5
}
Q 'SalesMenTble all' "SELECT * FROM SalesMenTble WITH (NOLOCK) ORDER BY 1" 40
Q 'SalesMenDetails sample' "SELECT TOP 5 * FROM SalesMenDetails WITH (NOLOCK)" 5
Q 'Allot per driver last 30 days (if Dt exists)' "SELECT TOP 40 a.Driver, COUNT(*) AS n FROM KitchDelivAllot a WITH (NOLOCK) GROUP BY a.Driver ORDER BY 2 DESC" 40

$c.Close()
W ''; W "done -> $Out"
