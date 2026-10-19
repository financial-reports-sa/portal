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
$Out = Join-Path $Here 'drivers_discovery.txt'
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

Q '1) KitchPOSH columns' "SELECT c.name AS col, t.name AS typ FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id WHERE c.object_id = OBJECT_ID('KitchPOSH') ORDER BY c.column_id" 400

Q '2) Tables named like driver/delivery' "SELECT t.name AS tbl, SUM(p.rows) AS rows FROM sys.tables t JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1) WHERE t.name LIKE '%Driv%' OR t.name LIKE '%Deliv%' OR t.name LIKE '%Captin%' OR t.name LIKE '%Captain%' OR t.name LIKE '%Tawsel%' OR t.name LIKE '%Ship%' OR t.name LIKE '%SalesMen%' GROUP BY t.name ORDER BY t.name"

Q '3) Columns named like driver/delivery (any table)' "SELECT OBJECT_NAME(c.object_id) AS tbl, c.name AS col FROM sys.columns c JOIN sys.tables t ON t.object_id = c.object_id WHERE c.name LIKE '%Driv%' OR c.name LIKE '%Deliv%' OR c.name LIKE '%Captin%' OR c.name LIKE '%Captain%' OR c.name LIKE '%Tawsel%' ORDER BY 1, 2" 300

Q '4) Sample bills (19/10/2026 11:28-11:30, driver should be خضر الظاهر)' "SELECT TOP 3 * FROM KitchPOSH WITH (NOLOCK) WHERE Dt >= '2026-10-19T11:27:00' AND Dt < '2026-10-19T11:31:00' ORDER BY Dt" 3

Q '5) Sample bills (19/10/2026 20:24-20:27)' "SELECT TOP 3 * FROM KitchPOSH WITH (NOLOCK) WHERE Dt >= '2026-10-19T20:24:00' AND Dt < '2026-10-19T20:27:00' ORDER BY Dt" 3

# 6) Which name tables contain the driver name
$k = $c.CreateCommand(); $k.CommandTimeout = 60
$k.CommandText = "SELECT OBJECT_NAME(c.object_id) AS tbl, c.name AS col FROM sys.columns c JOIN sys.tables t ON t.object_id = c.object_id JOIN sys.types y ON y.user_type_id = c.user_type_id WHERE y.name IN ('nvarchar','nchar') AND (c.name IN ('Name','AraName','EmpName','UserName','DriverName','EName') ) ORDER BY 1"
$r = $k.ExecuteReader(); $cols = @(); while ($r.Read()) { $cols += ,@([string]$r['tbl'], [string]$r['col']) }; $r.Close()
W ''; W '===== 6) Tables containing the name خضر ====='
foreach ($tc in $cols) {
  try {
    $k2 = $c.CreateCommand(); $k2.CommandTimeout = 30
    $k2.CommandText = "SELECT TOP 5 * FROM [$($tc[0])] WITH (NOLOCK) WHERE [$($tc[1])] LIKE N'%خضر%'"
    $r2 = $k2.ExecuteReader()
    while ($r2.Read()) {
      $parts = for ($i = 0; $i -lt [math]::Min($r2.FieldCount, 25); $i++) { $v = $r2.GetValue($i); if ($v -is [DBNull]) { $v = '' }; '{0}={1}' -f $r2.GetName($i), $v }
      W ("[{0}.{1}] {2}" -f $tc[0], $tc[1], ($parts -join ' | '))
    }
    $r2.Close()
  } catch {}
}

$c.Close()
W ''; W "done -> $Out"
