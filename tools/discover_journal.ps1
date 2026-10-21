<#
  Read-only discovery: how Growth stores journal entries (قيود اليومية) and financial vouchers.
  SELECT only (NOLOCK). Nothing is written to Growth. Uses the existing read-only login of the sync (growth_pass.txt).
  Run on the server, in C:\GrowthSync:
    powershell -ExecutionPolicy Bypass -File "C:\GrowthSync\discover_journal.ps1"
  Output: C:\GrowthSync\journal_discovery.txt  (send this file back)
#>
param([string]$SqlServer = 'GROWTHSERVER,1433', [string]$SqlDb = 'RMV3', [string]$SqlUser = 'platform_reader')
$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Out = Join-Path $Here 'journal_discovery.txt'
Set-Content -Path $Out -Value '' -Encoding UTF8
function W([string]$s) { Add-Content -Path $Out -Value $s -Encoding UTF8; Write-Host $s }
$pf = Join-Path $Here 'growth_pass.txt'
if (-not (Test-Path $pf)) { W "growth_pass.txt not found in $Here"; return }
$gp = (Get-Content $pf -Raw).Trim()
$c = New-Object System.Data.SqlClient.SqlConnection "Server=$SqlServer;Database=$SqlDb;User ID=$SqlUser;Password=$gp;Connect Timeout=10;ApplicationIntent=ReadOnly;Application Name=journal-discover"
$gp = $null
$c.Open()
W ("connected {0} / {1} at {2}" -f $SqlServer, $SqlDb, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

function Q([string]$title, [string]$sql, [int]$max = 200) {
  W ''; W "===== $title ====="
  try {
    $k = $c.CreateCommand(); $k.CommandText = $sql; $k.CommandTimeout = 90
    $r = $k.ExecuteReader(); $n = 0
    while ($r.Read() -and $n -lt $max) {
      $parts = for ($i = 0; $i -lt $r.FieldCount; $i++) { $v = $r.GetValue($i); if ($v -is [DBNull]) { $v = '' }; '{0}={1}' -f $r.GetName($i), $v }
      W ($parts -join ' | '); $n++
    }
    $r.Close(); if ($n -eq 0) { W '(no rows)' }
  } catch { W ("ERR: " + $_.Exception.Message) }
}
function Cols([string]$t) {
  Q "columns of $t" "SELECT c.column_id, c.name AS col, t.name AS typ, c.max_length, c.is_nullable, c.is_identity, OBJECT_DEFINITION(c.default_object_id) AS dflt FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id WHERE c.object_id = OBJECT_ID('$t') ORDER BY c.column_id" 200
}

Q 'tables like Trans* / Jour* / Ked* / Serial* / Seq* (row counts)' "SELECT t.name AS tbl, SUM(p.rows) AS rows FROM sys.tables t JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1) WHERE t.name LIKE 'Trans%' OR t.name LIKE '%Jour%' OR t.name LIKE '%Ked%' OR t.name LIKE '%Serial%' OR t.name LIKE '%Seq%' OR t.name LIKE '%Counter%' OR t.name LIKE '%DocNo%' OR t.name LIKE 'Doc%' GROUP BY t.name ORDER BY t.name" 200
Cols 'TransHds2'
Cols 'TransBdyFA2'
Q 'triggers on TransHds2 / TransBdyFA2' "SELECT OBJECT_NAME(parent_id) AS tbl, name, is_disabled FROM sys.triggers WHERE parent_id IN (OBJECT_ID('TransHds2'), OBJECT_ID('TransBdyFA2'))" 50
Q 'foreign keys / other tables pointing to TransHds2' "SELECT OBJECT_NAME(f.parent_object_id) AS child, COL_NAME(fc.parent_object_id, fc.parent_column_id) AS col FROM sys.foreign_keys f JOIN sys.foreign_key_columns fc ON fc.constraint_object_id = f.object_id WHERE f.referenced_object_id = OBJECT_ID('TransHds2')" 50
Q 'tables having a DocSeq column (header children)' "SELECT OBJECT_NAME(object_id) AS tbl FROM sys.columns WHERE name = 'DocSeq' AND OBJECTPROPERTY(object_id, 'IsUserTable') = 1 ORDER BY 1" 100
Q 'document types (SysMenu DocTId with names)' "SELECT DocTId, MIN(DisplayName) AS name, COUNT(*) AS n FROM SysMenu WITH (NOLOCK) WHERE DocTId > 0 GROUP BY DocTId ORDER BY DocTId" 200
Q 'doc types used in last 60 days (count, min/max DocNo)' "SELECT h.DocType, COUNT(*) AS docs, MIN(h.DocNo) AS min_no, MAX(h.DocNo) AS max_no, MAX(h.DtTim) AS last_dt FROM TransHds2 h WITH (NOLOCK) WHERE h.DtTim >= DATEADD(day, -60, GETDATE()) GROUP BY h.DocType ORDER BY docs DESC" 100
Q 'Other13 values on lines (status flag?)' "SELECT Other13, COUNT(*) AS n FROM TransBdyFA2 WITH (NOLOCK) GROUP BY Other13 ORDER BY Other13" 30
Q 'menu entries for the two target documents' "SELECT DocTId, DisplayName FROM SysMenu WITH (NOLOCK) WHERE DocTId > 0 AND (DisplayName LIKE N'%قيود آلية%' OR DisplayName LIKE N'%AI%' OR DisplayName LIKE N'%تحويل بنكي%' OR DisplayName LIKE N'%صرف شيك%' OR DisplayName LIKE N'%صرف آلي%')" 50
# For each target document: latest 2 headers + every row in every DocSeq child table for the latest one
$targets = @(
  @{ n = 'قيود آلية (قيود اليومية)'; w = "DisplayName LIKE N'%قيود آلية%'" },
  @{ n = 'AI تحويل بنكي (سند صرف شيك)'; w = "(DisplayName LIKE N'%AI%' OR DisplayName LIKE N'%تحويل بنكي%' OR DisplayName LIKE N'%صرف شيك%' OR DisplayName LIKE N'%صرف آلي%')" }
)
$kids = @()
try { $k = $c.CreateCommand(); $k.CommandText = "SELECT OBJECT_NAME(object_id) FROM sys.columns WHERE name = 'DocSeq' AND OBJECTPROPERTY(object_id, 'IsUserTable') = 1 AND OBJECT_NAME(object_id) <> 'TransHds2'"; $r = $k.ExecuteReader(); while ($r.Read()) { $kids += [string]$r.GetValue(0) }; $r.Close() } catch {}
foreach ($t in $targets) {
  $sub = "SELECT DocTId FROM SysMenu WITH (NOLOCK) WHERE DocTId > 0 AND $($t.w)"
  Q ("[{0}] latest 2 headers (all columns)" -f $t.n) "SELECT TOP 2 h.* FROM TransHds2 h WITH (NOLOCK) WHERE h.DocType IN ($sub) ORDER BY h.DocSeq DESC" 2
  $seq = $null
  try { $k = $c.CreateCommand(); $k.CommandText = "SELECT TOP 1 h.DocSeq FROM TransHds2 h WITH (NOLOCK) WHERE h.DocType IN ($sub) ORDER BY h.DocSeq DESC"; $seq = $k.ExecuteScalar() } catch {}
  if ($seq -eq $null -or $seq -is [DBNull]) { W ("[{0}] no document found" -f $t.n); continue }
  W ("[{0}] latest DocSeq = {1}" -f $t.n, $seq)
  foreach ($kt in $kids) {
    Q ("[{0}] rows in {1} for DocSeq {2}" -f $t.n, $kt, $seq) "SELECT * FROM [$kt] WITH (NOLOCK) WHERE DocSeq = $seq" 40
  }
}
Q 'max DocSeq / max line Id (numbering)' "SELECT (SELECT MAX(DocSeq) FROM TransHds2 WITH (NOLOCK)) AS max_docseq, (SELECT MAX(Id) FROM TransBdyFA2 WITH (NOLOCK)) AS max_line_id" 1
Q 'stored procedures that insert into TransHds2' "SELECT o.name FROM sys.sql_modules m JOIN sys.objects o ON o.object_id = m.object_id WHERE m.definition LIKE '%INSERT%TransHds2%' OR m.definition LIKE '%INSERT INTO%TransBdyFA2%'" 50
Q 'branches' "SELECT ID, Code, Name FROM BranchsTable WITH (NOLOCK) ORDER BY ID" 50
Q 'currencies' "SELECT TOP 10 * FROM Currency WITH (NOLOCK)" 10
$c.Close()
W ''; W "done -> $Out"
