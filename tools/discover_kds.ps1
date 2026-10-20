<#
  Read-only discovery for a kitchen display (KDS) on a BRANCH server.
  SELECT only (NOLOCK). Nothing is written to Growth. Output: kds_discovery.txt next to this script.
  Run ON the branch server (the PC that holds the branch Growth database):
    powershell -ExecutionPolicy Bypass -File discover_kds.ps1
  Optional: -Server ".\SQLEXPRESS"  -Db "RMV3"  -User "name" (password asked, never saved)
#>
param([string]$Server = '', [string]$Db = '', [string]$User = '')
$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Out = Join-Path $Here 'kds_discovery.txt'
Set-Content -Path $Out -Value '' -Encoding UTF8
function W([string]$s) { Add-Content -Path $Out -Value $s -Encoding UTF8; Write-Host $s }

W ("machine: {0} | time: {1}" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
W ''; W '===== SQL services on this machine ====='
try { Get-Service | Where-Object { $_.Name -like 'MSSQL*' -or $_.Name -like 'SQL*' } | ForEach-Object { W ("{0} | {1} | {2}" -f $_.Name, $_.Status, $_.DisplayName) } } catch { W ('ERR ' + $_.Exception.Message) }

$pw = $null
if ($User) { $sec = Read-Host -AsSecureString "SQL password for $User"; $pw = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)) }
$cands = if ($Server) { @($Server) } else { @('localhost', '.\SQLEXPRESS', '(local)', ".\MSSQLSERVER", "$env:COMPUTERNAME") }
$c = $null
foreach ($s in $cands) {
  $cs = if ($User) { "Server=$s;User ID=$User;Password=$pw;Connect Timeout=5;Application Name=kds-discover" } else { "Server=$s;Integrated Security=True;Connect Timeout=5;Application Name=kds-discover" }
  try { $t = New-Object System.Data.SqlClient.SqlConnection $cs; $t.Open(); $c = $t; W ''; W "connected: $s ($(if ($User) {'sql login'} else {'windows login'}))"; break } catch { W ("cannot connect {0}: {1}" -f $s, $_.Exception.Message) }
}
$pw = $null
if (-not $c) { W ''; W 'NO CONNECTION - send this file as is.'; return }

function Q([string]$title, [string]$sql, [int]$max = 200) {
  W ''; W "===== $title ====="
  try {
    $k = $c.CreateCommand(); $k.CommandText = $sql; $k.CommandTimeout = 60
    $r = $k.ExecuteReader(); $n = 0
    while ($r.Read() -and $n -lt $max) {
      $parts = for ($i = 0; $i -lt $r.FieldCount; $i++) { $v = $r.GetValue($i); if ($v -is [DBNull]) { $v = '' }; '{0}={1}' -f $r.GetName($i), $v }
      W ($parts -join ' | '); $n++
    }
    $r.Close(); if ($n -eq 0) { W '(no rows)' }
  } catch { W ("ERR: " + $_.Exception.Message) }
}

Q 'databases' "SELECT name, create_date FROM sys.databases WHERE database_id > 4 ORDER BY name"
if (-not $Db) {
  $k = $c.CreateCommand(); $k.CommandText = "SELECT TOP 1 name FROM sys.databases WHERE database_id > 4 AND (name LIKE 'RMV%' OR name LIKE '%Growth%' OR name LIKE 'RM%') ORDER BY name"; $Db = [string]$k.ExecuteScalar()
}
if (-not $Db) { W 'no Growth-like database found - send this file.'; $c.Close(); return }
$c.ChangeDatabase($Db); W ''; W "using database: $Db"

Q 'now on server' "SELECT GETDATE() AS server_now"
Q 'latest 8 bills (latency check: InsrtDt vs server_now)' "SELECT TOP 8 Id, BranchId, DocNo, OrdNo, Dt, InsrtDt, InvType, SalType, BillType, Net, MacName, Sync FROM KitchPOSH WITH (NOLOCK) ORDER BY Id DESC" 8
Q 'KitchPOSB columns (bill lines)' "SELECT c.name AS col, t.name AS typ FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id WHERE c.object_id = OBJECT_ID('KitchPOSB') ORDER BY c.column_id" 100
Q 'lines of the latest bill' "SELECT TOP 30 b.* FROM KitchPOSB b WITH (NOLOCK) WHERE b.SysSeq = (SELECT TOP 1 SysSeq FROM KitchPOSH WITH (NOLOCK) ORDER BY Id DESC)" 30
Q 'meals of the latest bill' "SELECT TOP 30 m.* FROM KitchMeals m WITH (NOLOCK) WHERE m.MealId IN (SELECT Item FROM KitchPOSB WITH (NOLOCK) WHERE SysSeq = (SELECT TOP 1 SysSeq FROM KitchPOSH WITH (NOLOCK) ORDER BY Id DESC))" 30
Q 'KitchMeals columns' "SELECT c.name AS col, t.name AS typ FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id WHERE c.object_id = OBJECT_ID('KitchMeals') ORDER BY c.column_id" 100
Q 'order types (KitchInvTypes)' "SELECT * FROM KitchInvTypes WITH (NOLOCK)" 30
Q 'sale types (KitchSalTypes)' "SELECT Id, AraName FROM KitchSalTypes WITH (NOLOCK)" 40
Q 'tables that may hold notes / add-ons / kitchen departments' "SELECT t.name AS tbl, SUM(p.rows) AS rows FROM sys.tables t JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1) WHERE t.name LIKE 'KitchPOS%' OR t.name LIKE '%Note%' OR t.name LIKE '%Addit%' OR t.name LIKE '%Extra%' OR t.name LIKE '%Modif%' OR t.name LIKE 'KitchDept%' OR t.name LIKE '%Printer%' OR t.name LIKE '%KDS%' OR t.name LIKE '%Screen%' GROUP BY t.name ORDER BY t.name" 120
Q 'kitchen departments' "SELECT TOP 30 * FROM KitchDeptPrinters WITH (NOLOCK)" 30
$c.Close()
W ''; W "done -> $Out"
