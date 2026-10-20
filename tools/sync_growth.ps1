<#
  Growth (RMV3) -> Supabase sync. Read-only on Growth. No install needed (PowerShell 5.1 + System.Data.SqlClient).
  Usage:  powershell -ExecutionPolicy Bypass -File sync_growth.ps1 [-DryRun] [-SecretsDir <dir>]
  Secrets (never logged): growth_pass.txt and portal_pass.txt, read from the script's own folder (or -SecretsDir if given).
#>
param(
  [switch]$DryRun,
  [switch]$ShowShifts,
  [switch]$AccountsOnly,    # run only the customers/vendors balances sync
  [switch]$ForceAccounts,   # also run it now, regardless of the half-hour window
  [switch]$FullMoves,       # statement movements from 2026-01-01 instead of the last 3 days
  [switch]$CatsOnly,        # run only the sales-by-category sync
  [switch]$FullCats,        # sales by category from 2026-01-01 instead of the current month
  [switch]$ChannelsOnly,    # run only the sales-by-type sync
  [switch]$FullChannels,    # sales by type from 2026-01-01 instead of the current month
  [switch]$GlOnly,          # run only the general-ledger lines sync
  [switch]$FullGl,          # ledger lines from 2026-01-01 instead of the last 3 days
  [switch]$InvOnly,         # run only the items/stock + purchases/issues sync
  [switch]$FullInv,         # purchases/issues from 2026-01-01 instead of the last 3 days
  [switch]$SkipItems,       # with -InvOnly: skip the items/stock call
  [switch]$TbOnly,          # run only the chart of accounts + trial balance sync
  [switch]$FullTb,          # trial balance from "0000-00" (opening + all 2026) instead of the current month
  [switch]$DelivOnly,       # run only the delivery-drivers sync
  [switch]$FullDeliv,       # delivery bills from 2026-01-01 instead of the last 3 days
  [switch]$CashOnly,        # run only the cashier-sales sync
  [switch]$FullCash,        # cashier sales from 2026-01-01 instead of the last 3 days
  [string]$SecretsDir = '',
  [string]$SqlServer = 'GROWTHSERVER,1433',
  [string]$SqlDb = 'RMV3',
  [string]$SqlUser = 'platform_reader'
)
$ErrorActionPreference = 'Stop'
$SbUrl   = 'https://olsqykputyhigalzmlbs.supabase.co'
$SbKey   = 'sb_publishable_KLB7HL6IGxhNj_8PSebE6w_F_CpCM8r'   # publishable (public-by-design) key
$SbEmail = 'sync@myreportshub.report'
$Here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile = Join-Path $Here 'sync_growth.log'
$BranchMap = @{ 2 = 'az'; 3 = 'sh'; 5 = 'pc' }

function Log([string]$m) {
  $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  Add-Content -Path $LogFile -Value $line -Encoding UTF8
  Write-Host $line
}
function Find-Secret([string]$name) {
  $dir = if ($SecretsDir) { $SecretsDir } else { $Here }
  $p = Join-Path $dir $name
  if (Test-Path $p) { return (Get-Content $p -Raw -Encoding UTF8).Trim() }
  throw "secret file not found: $p"
}
function N($v) { if ($v -is [DBNull]) { 0 } else { [math]::Round([double]$v, 4) } }

# Branch of a ledger line: BranchsTable.Code 1001 -> az, 1002 -> sh, 3001 -> pc, any other branch -> its original ID as text ("7", "8"), same as the chart-of-accounts branches
$BranchCase = "CASE b.Code WHEN '1001' THEN 'az' WHEN '1002' THEN 'sh' WHEN '3001' THEN 'pc' ELSE CAST(f.Branch AS varchar(10)) END"

# One row per (account x branch)
$AccountsSql = @"
SELECT CASE WHEN v.TreeLoc LIKE '%,36,%' THEN 'cust' ELSE 'vend' END AS kind, v.ID AS acc_id, $BranchCase AS branch, v.Code AS code, v.Name AS name,
       COALESCE(NULLIF(v.Mobil,''), NULLIF(v.TelNo,''), '') AS phone, g.Name AS grp,
       SUM(CASE WHEN f.Amount < 0 THEN -f.Amount ELSE 0 END) AS debit,
       SUM(CASE WHEN f.Amount > 0 THEN  f.Amount ELSE 0 END) AS credit,
       SUM(-f.Amount) AS balance, MAX(h.DtTim) AS last_move
FROM CustVendTree v WITH (NOLOCK)
JOIN TransBdyFA2 f WITH (NOLOCK) ON f.CustVendId = v.ID
LEFT JOIN TransHds2 h WITH (NOLOCK) ON h.DocSeq = f.DocSeq
LEFT JOIN BranchsTable b WITH (NOLOCK) ON b.ID = f.Branch
LEFT JOIN CustVendTree g WITH (NOLOCK) ON g.ID = v.ParentId
WHERE v.GrpLeave = 2 AND v.ID <> 0 AND f.Other13 <> 3
GROUP BY v.TreeLoc, v.ID, $BranchCase, v.Code, v.Name, COALESCE(NULLIF(v.Mobil,''), NULLIF(v.TelNo,''), ''), g.Name
"@
# NOTE: TransBdyFA2.Other13 = 3 marks memo (non-posting) lines; the ledger only balances without them, so every ledger query excludes them.

# Statement lines (account movements) from @from on. line_id = TransBdyFA2.Id (unique per ledger line).
$MovesSql = @"
SELECT CASE WHEN v.TreeLoc LIKE '%,36,%' THEN 'cust' ELSE 'vend' END AS kind, v.ID AS acc_id, $BranchCase AS branch,
       f.Id AS line_id, CONVERT(varchar(10), h.DtTim, 120) AS dt, h.DocNo AS doc,
       COALESCE(t.nm, N'مستند ' + CAST(h.DocType AS varchar(10))) AS typ, f.Narration AS descr,
       CASE WHEN f.Amount < 0 THEN -f.Amount ELSE 0 END AS debit, CASE WHEN f.Amount > 0 THEN f.Amount ELSE 0 END AS credit
FROM TransBdyFA2 f WITH (NOLOCK)
JOIN TransHds2 h WITH (NOLOCK) ON h.DocSeq = f.DocSeq
JOIN CustVendTree v WITH (NOLOCK) ON v.ID = f.CustVendId AND v.GrpLeave = 2 AND v.ID <> 0
LEFT JOIN BranchsTable b WITH (NOLOCK) ON b.ID = f.Branch
LEFT JOIN (SELECT DocTId, MIN(DisplayName) AS nm FROM SysMenu WITH (NOLOCK) WHERE DocTId > 0 GROUP BY DocTId) t ON t.DocTId = h.DocType
WHERE h.DtTim >= @from AND f.Other13 <> 3
ORDER BY f.Id
"@

# Chart of accounts: every level; parent = parent's account number ('' for the 4 roots); lvl = depth (root = 1); leaf = posting account.
$CoaSql = @"
WITH t AS (
  SELECT ID, Code, Name, ParentId, GrpLeave, CAST('' AS varchar(50)) AS ParentCode, 1 AS lvl FROM AccTree WITH (NOLOCK) WHERE ParentId = 0
  UNION ALL
  SELECT c.ID, c.Code, c.Name, c.ParentId, c.GrpLeave, CAST(t.Code AS varchar(50)), t.lvl + 1 FROM AccTree c WITH (NOLOCK) JOIN t ON c.ParentId = t.ID
)
SELECT Code AS acc, Name AS name, ParentCode AS parent, lvl, GrpLeave FROM t ORDER BY Code
"@

# Real branches only (GrpLeave = 2); entity = the branch-group name without the "مجموعه فروع" prefix.
$BranchesSql = @"
SELECT b.ID, b.Code, b.Name, p.Name AS GroupName
FROM BranchsTable b WITH (NOLOCK) LEFT JOIN BranchsTable p WITH (NOLOCK) ON p.ID = b.ParentID
WHERE b.GrpLeave = 2 ORDER BY b.ID
"@

# Trial balance: per (branch x posting account x month) gross debit/credit; opening balances (DocType 1) netted per account under ym '0000-00'.
$TbSql = @"
SELECT branch, acc, ym, debit, credit FROM (
  SELECT CASE b.Code WHEN '1001' THEN 'az' WHEN '1002' THEN 'sh' WHEN '3001' THEN 'pc' ELSE CAST(f.Branch AS varchar(10)) END AS branch,
         x.Code AS acc, CONVERT(char(7), h.DtTim, 120) AS ym,
         SUM(CASE WHEN f.Amount < 0 THEN -f.Amount ELSE 0 END) AS debit, SUM(CASE WHEN f.Amount > 0 THEN f.Amount ELSE 0 END) AS credit
  FROM TransBdyFA2 f WITH (NOLOCK)
  JOIN TransHds2 h WITH (NOLOCK) ON h.DocSeq = f.DocSeq
  JOIN AccTree x WITH (NOLOCK) ON x.ID = f.AccId
  LEFT JOIN BranchsTable b WITH (NOLOCK) ON b.ID = f.Branch
  WHERE f.Other13 <> 3 AND h.DocType <> 1 AND h.DtTim >= @from
  GROUP BY CASE b.Code WHEN '1001' THEN 'az' WHEN '1002' THEN 'sh' WHEN '3001' THEN 'pc' ELSE CAST(f.Branch AS varchar(10)) END, x.Code, CONVERT(char(7), h.DtTim, 120)
  UNION ALL
  SELECT CASE b.Code WHEN '1001' THEN 'az' WHEN '1002' THEN 'sh' WHEN '3001' THEN 'pc' ELSE CAST(f.Branch AS varchar(10)) END, x.Code, '0000-00',
         CASE WHEN SUM(-f.Amount) > 0 THEN SUM(-f.Amount) ELSE 0 END, CASE WHEN SUM(-f.Amount) < 0 THEN SUM(f.Amount) ELSE 0 END
  FROM TransBdyFA2 f WITH (NOLOCK)
  JOIN TransHds2 h WITH (NOLOCK) ON h.DocSeq = f.DocSeq
  JOIN AccTree x WITH (NOLOCK) ON x.ID = f.AccId
  LEFT JOIN BranchsTable b WITH (NOLOCK) ON b.ID = f.Branch
  WHERE f.Other13 <> 3 AND h.DocType = 1 AND @withOpen = 1
  GROUP BY CASE b.Code WHEN '1001' THEN 'az' WHEN '1002' THEN 'sh' WHEN '3001' THEN 'pc' ELSE CAST(f.Branch AS varchar(10)) END, x.Code
) u WHERE debit <> 0 OR credit <> 0 ORDER BY branch, acc, ym
"@

function Get-Login {
  $pp = Find-Secret 'portal_pass.txt'
  $loginBody = @{ email = $SbEmail; password = $pp } | ConvertTo-Json -Compress
  $pp = $null
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $a = Invoke-RestMethod -Method Post -Uri "$SbUrl/auth/v1/token?grant_type=password" `
       -Headers @{ apikey = $SbKey } -ContentType 'application/json' -Body $loginBody
  if (-not $a.access_token) { throw 'login returned no access_token' }
  return $a
}

# Customers + vendors balances (debit/credit/balance = debit - credit), all accounts in one call.
function Sync-Accounts($auth, [bool]$Send) {
  $gp = Find-Secret 'growth_pass.txt'
  $c = New-Object System.Data.SqlClient.SqlConnection "Server=$SqlServer;Database=$SqlDb;User ID=$SqlUser;Password=$gp;Connect Timeout=10;ApplicationIntent=ReadOnly;Application Name=platform-sync"
  $gp = $null
  $c.Open()
  $k = $c.CreateCommand(); $k.CommandText = $AccountsSql; $k.CommandTimeout = 120
  $r = $k.ExecuteReader()
  $list = New-Object System.Collections.Generic.List[object]
  while ($r.Read()) {
    $lm = $null
    if ($r['last_move'] -isnot [DBNull]) { $lm = ([datetime]$r['last_move']).ToString("yyyy-MM-dd'T'HH:mm:ss") + '+03:00' }
    $list.Add([ordered]@{
      kind = [string]$r['kind']; acc_id = [int]$r['acc_id']; branch = [string]$r['branch']; code = [string]$r['code']; name = [string]$r['name']
      phone = [string]$r['phone']; grp = $(if ($r['grp'] -is [DBNull]) { '' } else { [string]$r['grp'] })
      debit = [math]::Round([double]$r['debit'], 2); credit = [math]::Round([double]$r['credit'], 2)
      balance = [math]::Round([double]$r['balance'], 2); last_move = $lm
    })
  }
  $r.Close(); $c.Close()
  $nc = @($list | Where-Object { $_.kind -eq 'cust' }).Count; $nv = @($list | Where-Object { $_.kind -eq 'vend' }).Count
  Log ("accounts read: {0} (cust={1}, vend={2})" -f $list.Count, $nc, $nv)
  if (-not $Send) { Log 'accounts: dry-run, not sent'; return }
  $b = @{ p_rows = $list.ToArray(); p_kinds = @('cust', 'vend') } | ConvertTo-Json -Depth 4 -Compress
  $res = Invoke-RestMethod -Method Post -Uri "$SbUrl/rest/v1/rpc/growth_ingest_accounts" `
         -Headers @{ apikey = $SbKey; Authorization = "Bearer $($auth.access_token)" } `
         -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($b))
  if ($res.ok -ne $true) { throw ("accounts ingest not ok: " + ($res | ConvertTo-Json -Compress)) }
  Log ("accounts ingest ok, rows={0}" -f $res.rows)
}

# Statement movements from $From on, sent in batches of <= 8000 rows (first batch p_reset=true, the rest false, same p_from).
function Sync-Moves($auth, [bool]$Send, [datetime]$From) {
  $gp = Find-Secret 'growth_pass.txt'
  $c = New-Object System.Data.SqlClient.SqlConnection "Server=$SqlServer;Database=$SqlDb;User ID=$SqlUser;Password=$gp;Connect Timeout=10;ApplicationIntent=ReadOnly;Application Name=platform-sync"
  $gp = $null
  $c.Open()
  $k = $c.CreateCommand(); $k.CommandText = $MovesSql; $k.CommandTimeout = 180
  [void]$k.Parameters.AddWithValue('@from', $From)
  $r = $k.ExecuteReader()
  $list = New-Object System.Collections.Generic.List[object]
  while ($r.Read()) {
    $list.Add([ordered]@{
      kind = [string]$r['kind']; acc_id = [int]$r['acc_id']; branch = [string]$r['branch']; line_id = [int]$r['line_id']
      dt = [string]$r['dt']; doc = $(if ($r['doc'] -is [DBNull]) { '' } else { ([string]$r['doc']).Trim() }); typ = [string]$r['typ']
      descr = $(if ($r['descr'] -is [DBNull]) { '' } else { ([string]$r['descr']).Trim() })
      debit = [math]::Round([double]$r['debit'], 4); credit = [math]::Round([double]$r['credit'], 4)
    })
  }
  $r.Close(); $c.Close()
  $pFrom = $From.ToString('yyyy-MM-dd')
  $batches = [math]::Max(1, [int][math]::Ceiling($list.Count / 8000.0))
  Log ("moves read: {0} lines from {1} ({2} batch(es))" -f $list.Count, $pFrom, $batches)
  if (-not $Send) { Log 'moves: dry-run, not sent'; return }
  $total = 0
  for ($i = 0; $i -lt $batches; $i++) {
    $chunk = $list.GetRange($i * 8000, [math]::Min(8000, $list.Count - $i * 8000))
    $b = @{ p_rows = $chunk.ToArray(); p_from = $pFrom; p_reset = ($i -eq 0) } | ConvertTo-Json -Depth 4 -Compress
    $res = Invoke-RestMethod -Method Post -Uri "$SbUrl/rest/v1/rpc/growth_ingest_moves" `
           -Headers @{ apikey = $SbKey; Authorization = "Bearer $($auth.access_token)" } `
           -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($b))
    if ($res.ok -ne $true) { throw ("moves ingest not ok (batch {0}): {1}" -f ($i + 1), ($res | ConvertTo-Json -Compress)) }
    $total += $chunk.Count
    Log ("moves ingest ok, batch {0}/{1}, rows={2}" -f ($i + 1), $batches, $res.rows)
  }
}

# Accounts balances + statement movements. Full year (from 2026-01-01) when $Full, else the last 3 days.
function Sync-AccountsAndMoves($auth, [bool]$Send, [bool]$Full) {
  Sync-Accounts $auth $Send
  $from = if ($Full) { [datetime]'2026-01-01' } else { (Get-Date).Date.AddDays(-3) }
  Sync-Moves $auth $Send $from
}

# General ledger lines (all accounts). Same rules as the trial balance: posted lines only (Other13 <> 3), same branch codes, same account numbers.
# Opening-balance lines (DocType 1, dated 2026-01-01) are included as ordinary lines. Read page by page (keyset on the line id).
$GlSql = @"
SELECT TOP (8000)
       CASE b.Code WHEN '1001' THEN 'az' WHEN '1002' THEN 'sh' WHEN '3001' THEN 'pc' ELSE CAST(f.Branch AS varchar(10)) END AS branch,
       f.Id AS line_id, x.Code AS acc, CONVERT(varchar(10), h.DtTim, 120) AS dt, h.DocNo AS doc,
       COALESCE(t.nm, N'مستند ' + CAST(h.DocType AS varchar(10))) AS typ, f.Narration AS descr,
       CASE WHEN f.Amount < 0 THEN -f.Amount ELSE 0 END AS debit, CASE WHEN f.Amount > 0 THEN f.Amount ELSE 0 END AS credit
FROM TransBdyFA2 f WITH (NOLOCK)
JOIN TransHds2 h WITH (NOLOCK) ON h.DocSeq = f.DocSeq
JOIN AccTree x WITH (NOLOCK) ON x.ID = f.AccId
LEFT JOIN BranchsTable b WITH (NOLOCK) ON b.ID = f.Branch
LEFT JOIN (SELECT DocTId, MIN(DisplayName) AS nm FROM SysMenu WITH (NOLOCK) WHERE DocTId > 0 GROUP BY DocTId) t ON t.DocTId = h.DocType
WHERE f.Other13 <> 3 AND h.DtTim >= @from AND f.Id > @last
ORDER BY f.Id
"@

# ---------------- Inventory ----------------
# Leaf items (Code = item number), base unit name, parent group name.
$ItemsSql = @"
SELECT i.Code AS item, i.Name AS name,
       COALESCE((SELECT TOP 1 u.Name FROM Units u WITH (NOLOCK) WHERE u.ItmId = i.ID ORDER BY CASE WHEN u.Unit = u.BaseUnit THEN 0 ELSE 1 END, u.Unit), N'') AS unit,
       COALESCE(p.Name, N'') AS grp
FROM ItemsTable i WITH (NOLOCK) LEFT JOIN ItemsTable p WITH (NOLOCK) ON p.ID = i.Parentid
WHERE i.GrpLeave = 2 AND i.ID <> 0 ORDER BY i.Code
"@

# Current stock per (warehouse x item): qty = sum of signed Qty; cost = StockRate of the last movement (Growth keeps a moving average:
# receipts carry the new average, issues the average at issue time); value = qty x cost. Non-zero balances only. Memo lines (Other13 = 3) excluded.
$StockSql = @"
WITH m AS (
  SELECT s.WH, s.Item, s.Qty, s.StockRate, ROW_NUMBER() OVER (PARTITION BY s.WH, s.Item ORDER BY h.DtTim DESC, s.Id DESC) AS rn
  FROM TransBdyStck2 s WITH (NOLOCK) JOIN TransHds2 h WITH (NOLOCK) ON h.DocSeq = s.DocSeq
  WHERE s.Other13 <> 3
)
SELECT CASE b.Code WHEN '1001' THEN 'az' WHEN '1002' THEN 'sh' WHEN '3001' THEN 'pc' ELSE CAST(w.Branch AS varchar(10)) END AS branch,
       w.Name AS wh, i.Code AS item, SUM(m.Qty) AS qty, MAX(CASE WHEN m.rn = 1 THEN m.StockRate END) AS cost
FROM m JOIN WHTable w WITH (NOLOCK) ON w.ID = m.WH JOIN ItemsTable i WITH (NOLOCK) ON i.ID = m.Item LEFT JOIN BranchsTable b WITH (NOLOCK) ON b.ID = w.Branch
GROUP BY b.Code, w.Branch, w.Name, i.Code HAVING ABS(SUM(m.Qty)) > 0.0005 ORDER BY 1, 2, 3
"@

# Purchase invoices (801), purchase returns (851), direct warehouse issues = "Stock Direct Issue" (908, Arabic: صرف مخزني; NOT 904 = سند صرف مخزني, an internal transfer-out) - one row per stock line.
# pur/pret: price = unit price before tax (Rate), amount = qty x price, tax = the document's VAT (acct 712) allocated by line amount.
# iss: price = unit cost (StockRate), amount = qty x cost, tax = 0. qty is always positive.
$InvSql = @"
SELECT CASE h.DocType WHEN 801 THEN 'pur' WHEN 851 THEN 'pret' ELSE 'iss' END AS kind,
       CASE b.Code WHEN '1001' THEN 'az' WHEN '1002' THEN 'sh' WHEN '3001' THEN 'pc' ELSE CAST(s.Branch AS varchar(10)) END AS branch,
       s.Id AS line_id, CONVERT(varchar(10), h.DtTim, 120) AS dt, w.Name AS wh, h.DocNo AS doc,
       CASE WHEN h.DocType = 908 THEN COALESCE(NULLIF(LTRIM(RTRIM(c.CashCustVendName)), N''), NULLIF(LTRIM(RTRIM(CAST(s.Narration AS nvarchar(200)))), N''), N'')
            ELSE COALESCE(v.Name, c.CashCustVendName, N'') END AS party,
       i.Code AS item, ABS(s.Qty) AS qty,
       CASE WHEN h.DocType = 908 THEN s.StockRate ELSE ABS(s.Rate) END AS price,
       CASE WHEN h.DocType = 908 THEN ABS(s.Qty) * s.StockRate ELSE ABS(s.Qty * s.Rate) END AS amount,
       CASE WHEN h.DocType = 908 THEN 0
            ELSE ABS(s.Qty * s.Rate) * COALESCE(
                 (SELECT ABS(SUM(f.Amount)) FROM TransBdyFA2 f WITH (NOLOCK) WHERE f.DocSeq = s.DocSeq AND f.AccId = 712 AND f.Other13 <> 3)
                 / NULLIF(SUM(ABS(s.Qty * s.Rate)) OVER (PARTITION BY s.DocSeq), 0), 0) END AS tax
FROM TransBdyStck2 s WITH (NOLOCK)
JOIN TransHds2 h WITH (NOLOCK) ON h.DocSeq = s.DocSeq
JOIN ItemsTable i WITH (NOLOCK) ON i.ID = s.Item
LEFT JOIN WHTable w WITH (NOLOCK) ON w.ID = s.WH
LEFT JOIN BranchsTable b WITH (NOLOCK) ON b.ID = s.Branch
LEFT JOIN TransHdsDocCustsVends2 c WITH (NOLOCK) ON c.DocSeq = s.DocSeq
LEFT JOIN CustVendTree v WITH (NOLOCK) ON v.ID = c.CustVendId AND c.CustVendId <> 0
WHERE h.DocType IN (801, 851, 908) AND s.Other13 <> 3 AND h.DtTim >= @from
ORDER BY s.Id
"@

function Open-Growth {
  $gp = Find-Secret 'growth_pass.txt'
  $c = New-Object System.Data.SqlClient.SqlConnection "Server=$SqlServer;Database=$SqlDb;User ID=$SqlUser;Password=$gp;Connect Timeout=10;ApplicationIntent=ReadOnly;Application Name=platform-sync"
  $gp = $null
  $c.Open()
  return $c
}

function Post-Rpc($auth, [string]$Fn, $Body) {
  $json = $Body | ConvertTo-Json -Depth 5 -Compress
  return Invoke-RestMethod -Method Post -Uri "$SbUrl/rest/v1/rpc/$Fn" `
         -Headers @{ apikey = $SbKey; Authorization = "Bearer $($auth.access_token)" } `
         -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json))
}

# Chart of accounts (all levels) + real branches
function Sync-Coa($auth, [bool]$Send) {
  $c = Open-Growth
  $k = $c.CreateCommand(); $k.CommandText = $CoaSql; $k.CommandTimeout = 60
  $r = $k.ExecuteReader()
  $accs = New-Object System.Collections.Generic.List[object]
  while ($r.Read()) {
    $accs.Add([ordered]@{ acc = ([string]$r['acc']).Trim(); name = ([string]$r['name']).Trim(); parent = ([string]$r['parent']).Trim(); lvl = [int]$r['lvl']; leaf = ([int]$r['GrpLeave'] -eq 2) })
  }
  $r.Close()
  $k2 = $c.CreateCommand(); $k2.CommandText = $BranchesSql; $k2.CommandTimeout = 60
  $r2 = $k2.ExecuteReader()
  $brs = New-Object System.Collections.Generic.List[object]
  while ($r2.Read()) {
    $code = switch (([string]$r2['Code']).Trim()) { '1001' { 'az' } '1002' { 'sh' } '3001' { 'pc' } default { [string][int]$r2['ID'] } }
    $ent = if ($r2['GroupName'] -is [DBNull]) { '' } else { (([string]$r2['GroupName']) -replace '^\s*مجموعه فروع\s*', '').Trim() }
    $brs.Add([ordered]@{ code = $code; name = ([string]$r2['Name']).Trim(); entity = $ent })
  }
  $r2.Close(); $c.Close()
  Log ("coa read: {0} accounts, {1} branches" -f $accs.Count, $brs.Count)
  if (-not $Send) { Log 'coa: dry-run, not sent'; return }
  $res = Post-Rpc $auth 'growth_ingest_coa' @{ p_rows = $accs.ToArray(); p_branches = $brs.ToArray() }
  if ($res.ok -ne $true) { throw ("coa ingest not ok: " + ($res | ConvertTo-Json -Compress)) }
  Log ("coa ingest ok, rows={0}" -f $res.rows)
}

# Monthly trial balance. $Full: from '0000-00' (opening + every month of 2026); else the current month only.
function Sync-Tb($auth, [bool]$Send, [bool]$Full) {
  $from = if ($Full) { [datetime]'2026-01-01' } else { Get-Date -Day 1 -Hour 0 -Minute 0 -Second 0 -Millisecond 0 }
  $fromYm = if ($Full) { '0000-00' } else { $from.ToString('yyyy-MM') }
  $c = Open-Growth
  $k = $c.CreateCommand(); $k.CommandText = $TbSql; $k.CommandTimeout = 180
  [void]$k.Parameters.AddWithValue('@from', $from)
  [void]$k.Parameters.AddWithValue('@withOpen', [int]$Full)
  $r = $k.ExecuteReader()
  $list = New-Object System.Collections.Generic.List[object]
  while ($r.Read()) {
    $list.Add([ordered]@{ branch = [string]$r['branch']; acc = ([string]$r['acc']).Trim(); ym = ([string]$r['ym']).Trim()
                          debit = [math]::Round([double]$r['debit'], 2); credit = [math]::Round([double]$r['credit'], 2) })
  }
  $r.Close(); $c.Close()
  $batches = [math]::Max(1, [int][math]::Ceiling($list.Count / 8000.0))
  Log ("tb read: {0} rows from {1} ({2} batch(es))" -f $list.Count, $fromYm, $batches)
  if (-not $Send) { Log 'tb: dry-run, not sent'; return }
  for ($i = 0; $i -lt $batches; $i++) {
    $chunk = $list.GetRange($i * 8000, [math]::Min(8000, $list.Count - $i * 8000))
    $res = Post-Rpc $auth 'growth_ingest_tb' @{ p_rows = $chunk.ToArray(); p_from_ym = $fromYm; p_reset = ($i -eq 0) }
    if ($res.ok -ne $true) { throw ("tb ingest not ok (batch {0}): {1}" -f ($i + 1), ($res | ConvertTo-Json -Compress)) }
    Log ("tb ingest ok, batch {0}/{1}, rows={2}" -f ($i + 1), $batches, $res.rows)
  }
}

# Sales by type (channel) per branch per day. net = sales before tax = Net - Tax (= Gross + extra amount), refund rows (BillType 6) included
# as negatives; tax = VAT incl. refund rows; bills = number of non-refund bills. channel = KitchPOSH.SalType (0 = local, no row in KitchSalTypes).
# Column of the Growth report "مفصل المبيعات حسب النوع" for each bill, first match wins:
#   PayType = 4                -> "اجل عملاء"   (code 'pay4')
#   SalType <> 0               -> KitchSalTypes name (code = SalType: توالف, اعاشة العمال, تطبيق هانقرستيشن/كيتا/تويو/الشادن/بونات/نينجا, قسم العائلات, وجبات)
#   otherwise (SalType = 0)    -> order type from KitchInvTypes (code 'i' + InvType: محلي, سفري, عوائل, توصيل, مطبخ)
$ChannelsSql = @"
SELECT branch, day, channel, name, SUM(net) AS net, SUM(tax) AS tax, SUM(bills) AS bills FROM (
  SELECT CASE h.BranchId WHEN 2 THEN 'az' WHEN 3 THEN 'sh' WHEN 5 THEN 'pc' END AS branch, CONVERT(varchar(10), h.Dt, 120) AS day,
         CASE WHEN h.PayType = 4 THEN 'pay4' WHEN h.SalType <> 0 THEN CAST(h.SalType AS varchar(10)) ELSE 'i' + CAST(h.InvType AS varchar(10)) END AS channel,
         CASE WHEN h.PayType = 4 THEN N'اجل عملاء'
              WHEN h.SalType <> 0 THEN COALESCE(st.AraName, N'نوع ' + CAST(h.SalType AS varchar(10)))
              ELSE COALESCE(it.Name, N'نوع طلب ' + CAST(h.InvType AS varchar(10))) END AS name,
         h.Net - h.Tax AS net, h.Tax AS tax, CASE WHEN h.BillType <> 6 THEN 1 ELSE 0 END AS bills
  FROM KitchPOSH h WITH (NOLOCK)
  LEFT JOIN KitchSalTypes st WITH (NOLOCK) ON st.Id = h.SalType
  LEFT JOIN KitchInvTypes it WITH (NOLOCK) ON it.InvType = h.InvType
  WHERE h.Dt >= @from AND h.BranchId IN (2, 3, 5)
) x GROUP BY branch, day, channel, name ORDER BY 1, 2, 3
"@

function Sync-Channels($auth, [bool]$Send, [datetime]$From) {
  $c = Open-Growth
  $k = $c.CreateCommand(); $k.CommandText = $ChannelsSql; $k.CommandTimeout = 60
  [void]$k.Parameters.AddWithValue('@from', $From)
  $r = $k.ExecuteReader()
  $list = New-Object System.Collections.Generic.List[object]
  while ($r.Read()) {
    $list.Add([ordered]@{ branch = [string]$r['branch']; day = [string]$r['day']; channel = [string]$r['channel']; name = ([string]$r['name']).Trim()
                          net = [math]::Round([double]$r['net'], 2); tax = [math]::Round([double]$r['tax'], 2); bills = [int]$r['bills'] })
  }
  $r.Close(); $c.Close()
  $pFrom = $From.ToString('yyyy-MM-dd')
  $batches = [math]::Max(1, [int][math]::Ceiling($list.Count / 8000.0))
  Log ("channels read: {0} rows from {1} ({2} batch(es))" -f $list.Count, $pFrom, $batches)
  if (-not $Send) { Log 'channels: dry-run, not sent'; return }
  for ($i = 0; $i -lt $batches; $i++) {
    $chunk = $list.GetRange($i * 8000, [math]::Min(8000, $list.Count - $i * 8000))
    $res = Post-Rpc $auth 'growth_ingest_channels' @{ p_rows = $chunk.ToArray(); p_from = $pFrom; p_reset = ($i -eq 0) }
    if ($res.ok -ne $true) { throw ("channels ingest not ok (batch {0}): {1}" -f ($i + 1), ($res | ConvertTo-Json -Compress)) }
    Log ("channels ingest ok, batch {0}/{1}, reply: {2}" -f ($i + 1), $batches, ($res | ConvertTo-Json -Depth 6 -Compress))
  }
}

# Report "اجمالي مبيعات الفئات": per branch, per day, per top-level POS category (sub-categories roll up to their parent).
# cat = first 3 digits of the top-level KitchCat.ItmCode; name = top-level category name.
# qty = sum(KitchPOSB.Qty x KitchMeals.CategQty)  (CategQty = the meal's share of a category unit, e.g. a quarter chicken = 0.25)
# net = sum(KitchPOSB.Qty x Amt)  (line value as printed, VAT included). Refund bills (BillType 6) are not part of this report.
$CatsSql = @"
SELECT CASE h.BranchId WHEN 2 THEN 'az' WHEN 3 THEN 'sh' WHEN 5 THEN 'pc' END AS branch, CONVERT(varchar(10), h.Dt, 120) AS day,
       LEFT(CASE WHEN c.Parent = 0 THEN c.ItmCode ELSE p.ItmCode END, 3) AS cat, MIN(CASE WHEN c.Parent = 0 THEN c.Name ELSE p.Name END) AS name,
       SUM(b.Qty * m.CategQty) AS qty, SUM(b.Qty * b.Amt) AS net
FROM KitchPOSH h WITH (NOLOCK)
JOIN KitchPOSB b WITH (NOLOCK) ON b.SysSeq = h.SysSeq
JOIN KitchMeals m WITH (NOLOCK) ON m.MealId = b.Item
JOIN KitchCat c WITH (NOLOCK) ON c.Id = m.CatId
LEFT JOIN KitchCat p WITH (NOLOCK) ON p.Id = c.Parent
WHERE h.Dt >= @from AND h.BranchId IN (2, 3, 5) AND h.BillType <> 6
GROUP BY h.BranchId, CONVERT(varchar(10), h.Dt, 120), LEFT(CASE WHEN c.Parent = 0 THEN c.ItmCode ELSE p.ItmCode END, 3)
ORDER BY 1, 2, 3
"@

function Sync-Cats($auth, [bool]$Send, [datetime]$From) {
  $c = Open-Growth
  $k = $c.CreateCommand(); $k.CommandText = $CatsSql; $k.CommandTimeout = 180
  [void]$k.Parameters.AddWithValue('@from', $From)
  $r = $k.ExecuteReader()
  $list = New-Object System.Collections.Generic.List[object]
  while ($r.Read()) {
    $list.Add([ordered]@{ branch = [string]$r['branch']; day = [string]$r['day']; cat = ([string]$r['cat']).Trim(); name = ([string]$r['name']).Trim()
                          qty = [math]::Round([double]$r['qty'], 4); net = [math]::Round([double]$r['net'], 2) })
  }
  $r.Close(); $c.Close()
  $pFrom = $From.ToString('yyyy-MM-dd')
  $batches = [math]::Max(1, [int][math]::Ceiling($list.Count / 8000.0))
  Log ("cats read: {0} rows from {1} ({2} batch(es))" -f $list.Count, $pFrom, $batches)
  if (-not $Send) { Log 'cats: dry-run, not sent'; return }
  for ($i = 0; $i -lt $batches; $i++) {
    $chunk = $list.GetRange($i * 8000, [math]::Min(8000, $list.Count - $i * 8000))
    $res = Post-Rpc $auth 'growth_ingest_cats' @{ p_rows = $chunk.ToArray(); p_from = $pFrom; p_reset = ($i -eq 0) }
    if ($res.ok -ne $true) { throw ("cats ingest not ok (batch {0}): {1}" -f ($i + 1), ($res | ConvertTo-Json -Compress)) }
    Log ("cats ingest ok, batch {0}/{1}, reply: {2}" -f ($i + 1), $batches, ($res | ConvertTo-Json -Depth 6 -Compress))
  }
}

# Delivery drivers: one row per delivery bill = the latest driver allotment (KitchDelivAllot, re-allotments keep the last one)
# joined to the POS bill (KitchPOSH.SysSeq) + customer info (KitchDelivCustInfo). Driver = SalesMenTble.Id. Refund bills (BillType 6) excluded.
# Same rows as the Growth report "تقرير السائقين" (detailed): bill date, driver, customer, mobile, address, bill no., amount (Net).
$DelivSql = @"
SELECT h.BranchId, a.SysSeq, h.DocNo, h.Dt, a.Driver, COALESCE(NULLIF(LTRIM(RTRIM(sm.Name)), ''), '') AS DriverName,
       COALESCE(ci.Customer, '') AS Customer, COALESCE(ci.Mobil, '') AS Mobil, COALESCE(ci.Address, '') AS Address,
       COALESCE(CASE WHEN h.SalType <> 0 THEN st.AraName END, it.Name, '') AS ChName, h.Net, a.Clsd
FROM (SELECT SysSeq, Driver, Clsd, ROW_NUMBER() OVER (PARTITION BY SysSeq ORDER BY Dt DESC) AS rn
      FROM KitchDelivAllot WITH (NOLOCK) WHERE Dt >= DATEADD(day, -2, @from)) a
JOIN KitchPOSH h WITH (NOLOCK) ON h.SysSeq = a.SysSeq
LEFT JOIN SalesMenTble sm WITH (NOLOCK) ON sm.Id = a.Driver
OUTER APPLY (SELECT TOP 1 x.Customer, x.Mobil, x.Address FROM KitchDelivCustInfo x WITH (NOLOCK) WHERE x.SysSeq = a.SysSeq) ci
LEFT JOIN KitchSalTypes st WITH (NOLOCK) ON st.Id = h.SalType
LEFT JOIN KitchInvTypes it WITH (NOLOCK) ON it.InvType = h.InvType
WHERE a.rn = 1 AND h.Dt >= @from AND h.BillType <> 6 AND h.BranchId IN (2, 3, 5)
ORDER BY h.Dt
"@

function Sync-Deliv($auth, [bool]$Send, [datetime]$From) {
  $c = Open-Growth
  $k = $c.CreateCommand(); $k.CommandText = $DelivSql; $k.CommandTimeout = 120
  [void]$k.Parameters.AddWithValue('@from', $From)
  $r = $k.ExecuteReader()
  $list = New-Object System.Collections.Generic.List[object]
  $S = { param($v) if ($v -is [DBNull]) { '' } else { ([string]$v).Trim() } }
  while ($r.Read()) {
    $dt = [datetime]$r['Dt']
    $list.Add([ordered]@{
      branch = $BranchMap[[int]$r['BranchId']]; bill_id = [string]$r['SysSeq']; doc = (& $S $r['DocNo'])
      bdate = $dt.ToString('yyyy-MM-dd'); dt = $dt.ToString("yyyy-MM-dd'T'HH:mm:ss") + '+03:00'
      driver_id = [int](N $r['Driver']); driver = (& $S $r['DriverName']); customer = (& $S $r['Customer'])
      mobile = (& $S $r['Mobil']); address = (& $S $r['Address']); channel = (& $S $r['ChName'])
      net = [math]::Round((N $r['Net']), 2); clsd = [int](N $r['Clsd'])
    })
  }
  $r.Close(); $c.Close()
  $pFrom = $From.ToString('yyyy-MM-dd')
  $batches = [math]::Max(1, [int][math]::Ceiling($list.Count / 8000.0))
  Log ("deliv read: {0} bills from {1} ({2} batch(es))" -f $list.Count, $pFrom, $batches)
  if (-not $Send) { Log 'deliv: dry-run, not sent'; return }
  for ($i = 0; $i -lt $batches; $i++) {
    $chunk = $list.GetRange($i * 8000, [math]::Min(8000, $list.Count - $i * 8000))
    $res = Post-Rpc $auth 'growth_ingest_deliv' @{ p_rows = $chunk.ToArray(); p_from = $pFrom; p_reset = ($i -eq 0) }
    if ($res.ok -ne $true) { throw ("deliv ingest not ok (batch {0}): {1}" -f ($i + 1), ($res | ConvertTo-Json -Compress)) }
    Log ("deliv ingest ok, batch {0}/{1}, rows={2}" -f ($i + 1), $batches, $res.rows)
  }
}

# Cashier sales per cashier (SalMan) per branch per day, from $From on. SELECT only, NOLOCK.
$CashSql = @"
SELECT h.BranchId, h.SalMan, MAX(COALESCE(NULLIF(LTRIM(RTRIM(sm.Name)),''), NULLIF(LTRIM(RTRIM(u.EmpName)),''), u.UserName)) AS Cashier,
       CONVERT(varchar(10), h.Dt, 120) AS Bdate,
       SUM(CASE WHEN h.BillType <> 6 THEN 1 ELSE 0 END) AS Bills,
       SUM(CASE WHEN h.BillType <> 6 AND h.PayType <> 4 THEN h.Net ELSE 0 END) AS Sales,
       SUM(CASE WHEN h.BillType <> 6 AND h.PayType = 4 THEN h.Net ELSE 0 END) AS Credit,
       SUM(CASE WHEN h.BillType <> 6 THEN ISNULL(h.VisaAmt,0) + ISNULL(h.MasterAmt,0) + ISNULL(h.SpamAmt,0) ELSE 0 END) AS Card,
       -SUM(CASE WHEN h.BillType = 6 THEN h.Net ELSE 0 END) AS Refunds,
       SUM(CASE WHEN h.BillType = 6 THEN 1 ELSE 0 END) AS RefCnt,
       SUM(CASE WHEN h.BillType <> 6 THEN ISNULL(h.DiscAmt,0) ELSE 0 END) AS Disc,
       MIN(h.Dt) AS FirstAt, MAX(h.Dt) AS LastAt
FROM KitchPOSH h WITH (NOLOCK)
LEFT JOIN SalesMenTble sm WITH (NOLOCK) ON sm.Id = h.SalMan
LEFT JOIN Users u WITH (NOLOCK) ON u.UserId = h.UserId
WHERE h.Dt >= @from AND h.BranchId IN (2,3,5)
GROUP BY h.BranchId, h.SalMan, CONVERT(varchar(10), h.Dt, 120)
"@

function Sync-Cash($auth, [bool]$Send, [datetime]$From) {
  $c = Open-Growth
  $k = $c.CreateCommand(); $k.CommandText = $CashSql; $k.CommandTimeout = 120
  [void]$k.Parameters.AddWithValue('@from', $From)
  $r = $k.ExecuteReader()
  $list = New-Object System.Collections.Generic.List[object]
  while ($r.Read()) {
    $sales = N $r['Sales']; $card = N $r['Card']; $ref = N $r['Refunds']
    $list.Add([ordered]@{
      branch = $BranchMap[[int]$r['BranchId']]; bdate = [string]$r['Bdate']; salman = [int](N $r['SalMan'])
      cashier = $(if ($r['Cashier'] -is [DBNull]) { '' } else { ([string]$r['Cashier']).Trim() })
      bills = [int](N $r['Bills']); sales = [math]::Round($sales, 2); credit = [math]::Round((N $r['Credit']), 2)
      card = [math]::Round($card, 2); cash = [math]::Round($sales - $card - $ref, 2); refunds = [math]::Round($ref, 2)
      ref_cnt = [int](N $r['RefCnt']); disc = [math]::Round((N $r['Disc']), 2)
      first_at = ([datetime]$r['FirstAt']).ToString("yyyy-MM-dd'T'HH:mm:ss") + '+03:00'
      last_at  = ([datetime]$r['LastAt']).ToString("yyyy-MM-dd'T'HH:mm:ss") + '+03:00'
    })
  }
  $r.Close(); $c.Close()
  $pFrom = $From.ToString('yyyy-MM-dd')
  $batches = [math]::Max(1, [int][math]::Ceiling($list.Count / 8000.0))
  Log ("cash read: {0} cashier-days from {1} ({2} batch(es))" -f $list.Count, $pFrom, $batches)
  if (-not $Send) { Log 'cash: dry-run, not sent'; return }
  for ($i = 0; $i -lt $batches; $i++) {
    $chunk = $list.GetRange($i * 8000, [math]::Min(8000, $list.Count - $i * 8000))
    $res = Post-Rpc $auth 'growth_ingest_cashiers' @{ p_rows = $chunk.ToArray(); p_from = $pFrom; p_reset = ($i -eq 0) }
    if ($res.ok -ne $true) { throw ("cash ingest not ok (batch {0}): {1}" -f ($i + 1), ($res | ConvertTo-Json -Compress)) }
    Log ("cash ingest ok, batch {0}/{1}, rows={2}" -f ($i + 1), $batches, $res.rows)
  }
}

# Ledger lines from $From on, pages of 8000 (first page p_reset=true, the rest false, same p_from)
function Sync-Gl($auth, [bool]$Send, [datetime]$From) {
  $c = Open-Growth
  $pFrom = $From.ToString('yyyy-MM-dd')
  $last = [int64]0; $page = 0; $total = 0
  while ($true) {
    $k = $c.CreateCommand(); $k.CommandText = $GlSql; $k.CommandTimeout = 120
    [void]$k.Parameters.AddWithValue('@from', $From)
    [void]$k.Parameters.AddWithValue('@last', $last)
    $r = $k.ExecuteReader()
    $list = New-Object System.Collections.Generic.List[object]
    while ($r.Read()) {
      $list.Add([ordered]@{
        branch = [string]$r['branch']; line_id = [string]$r['line_id']; acc = ([string]$r['acc']).Trim(); dt = [string]$r['dt']
        doc = $(if ($r['doc'] -is [DBNull]) { '' } else { ([string]$r['doc']).Trim() }); typ = [string]$r['typ']
        descr = $(if ($r['descr'] -is [DBNull]) { '' } else { ([string]$r['descr']).Trim() })
        debit = [math]::Round([double]$r['debit'], 4); credit = [math]::Round([double]$r['credit'], 4)
      })
      $last = [int64]$r['line_id']
    }
    $r.Close()
    if ($list.Count -eq 0 -and $page -gt 0) { break }
    $page++; $total += $list.Count
    if ($Send) {
      $res = Post-Rpc $auth 'growth_ingest_gl' @{ p_rows = $list.ToArray(); p_from = $pFrom; p_reset = ($page -eq 1) }
      if ($res.ok -ne $true) { throw ("gl ingest not ok (batch {0}): {1}" -f $page, ($res | ConvertTo-Json -Compress)) }
    }
    if ($list.Count -lt 8000) { break }
  }
  $c.Close()
  Log ("gl {0}: {1} lines from {2} ({3} batch(es))" -f $(if ($Send) { 'ingest ok' } else { 'read, dry-run, not sent' }), $total, $pFrom, $page)
}

# Items + current stock (replaces the whole stock table on every call)
function Sync-Items($auth, [bool]$Send) {
  $c = Open-Growth
  $k = $c.CreateCommand(); $k.CommandText = $ItemsSql; $k.CommandTimeout = 60
  $r = $k.ExecuteReader()
  $items = New-Object System.Collections.Generic.List[object]
  while ($r.Read()) {
    $items.Add([ordered]@{ item = ([string]$r['item']).Trim(); name = ([string]$r['name']).Trim(); unit = ([string]$r['unit']).Trim(); grp = ([string]$r['grp']).Trim() })
  }
  $r.Close()
  $k2 = $c.CreateCommand(); $k2.CommandText = $StockSql; $k2.CommandTimeout = 120
  $r2 = $k2.ExecuteReader()
  $stock = New-Object System.Collections.Generic.List[object]
  while ($r2.Read()) {
    $qty = [math]::Round([double]$r2['qty'], 4); $cost = if ($r2['cost'] -is [DBNull]) { 0.0 } else { [math]::Round([double]$r2['cost'], 6) }
    $stock.Add([ordered]@{ branch = [string]$r2['branch']; wh = ([string]$r2['wh']).Trim(); item = ([string]$r2['item']).Trim(); qty = $qty; cost = $cost; value = [math]::Round($qty * $cost, 2) })
  }
  $r2.Close(); $c.Close()
  Log ("items read: {0} items, {1} stock rows" -f $items.Count, $stock.Count)
  if (-not $Send) { Log 'items: dry-run, not sent'; return }
  $res = Post-Rpc $auth 'growth_ingest_items' @{ p_items = $items.ToArray(); p_stock = $stock.ToArray() }
  if ($res.ok -ne $true) { throw ("items ingest not ok: " + ($res | ConvertTo-Json -Compress)) }
  Log ("items ingest ok, rows={0}" -f $res.rows)
}

# Purchases / purchase returns / direct issues from $From on, batches of <= 8000 (first p_reset=true, rest false, same p_from)
function Sync-Inv($auth, [bool]$Send, [datetime]$From) {
  $c = Open-Growth
  $k = $c.CreateCommand(); $k.CommandText = $InvSql; $k.CommandTimeout = 180
  [void]$k.Parameters.AddWithValue('@from', $From)
  $r = $k.ExecuteReader()
  $list = New-Object System.Collections.Generic.List[object]
  while ($r.Read()) {
    $list.Add([ordered]@{
      kind = [string]$r['kind']; branch = [string]$r['branch']; line_id = [string]$r['line_id']; dt = [string]$r['dt']
      wh = $(if ($r['wh'] -is [DBNull]) { '' } else { ([string]$r['wh']).Trim() }); doc = $(if ($r['doc'] -is [DBNull]) { '' } else { ([string]$r['doc']).Trim() })
      party = ([string]$r['party']).Trim(); item = ([string]$r['item']).Trim()
      qty = [math]::Round([double]$r['qty'], 4); price = [math]::Round([double]$r['price'], 6)
      amount = [math]::Round([double]$r['amount'], 4); tax = [math]::Round([double]$r['tax'], 4)
    })
  }
  $r.Close(); $c.Close()
  $pFrom = $From.ToString('yyyy-MM-dd')
  $batches = [math]::Max(1, [int][math]::Ceiling($list.Count / 8000.0))
  Log ("inv read: {0} lines from {1} ({2} batch(es))" -f $list.Count, $pFrom, $batches)
  if (-not $Send) { Log 'inv: dry-run, not sent'; return }
  for ($i = 0; $i -lt $batches; $i++) {
    $chunk = $list.GetRange($i * 8000, [math]::Min(8000, $list.Count - $i * 8000))
    $res = Post-Rpc $auth 'growth_ingest_inv' @{ p_rows = $chunk.ToArray(); p_from = $pFrom; p_reset = ($i -eq 0) }
    if ($res.ok -ne $true) { throw ("inv ingest not ok (batch {0}): {1}" -f ($i + 1), ($res | ConvertTo-Json -Compress)) }
    Log ("inv ingest ok, batch {0}/{1} (p_from={2}, p_reset={3}, sent={4}), reply: {5}" -f ($i + 1), $batches, $pFrom, ($i -eq 0), $chunk.Count, ($res | ConvertTo-Json -Depth 6 -Compress))
  }
}

try {
  Log 'start'
  $now = Get-Date
  $fullTb = $FullTb -or ($now.Hour -eq 3 -and $now.Minute -lt 5)   # once a day at 03:00 (+ on demand)
  $fullInv = $FullInv -or ($now.Hour -eq 3 -and $now.Minute -lt 5)
  $invFrom = if ($fullInv) { [datetime]'2026-01-01' } else { $now.Date.AddDays(-3) }
  $fullGl = $FullGl -or ($now.Hour -eq 3 -and $now.Minute -lt 5)
  $glFrom = if ($fullGl) { [datetime]'2026-01-01' } else { $now.Date.AddDays(-3) }
  $fullCh = $FullChannels -or ($now.Hour -eq 3 -and $now.Minute -lt 5)
  $chFrom = if ($fullCh) { [datetime]'2026-01-01' } else { Get-Date -Day 1 -Hour 0 -Minute 0 -Second 0 -Millisecond 0 }
  $fullCats = $FullCats -or ($now.Hour -eq 3 -and $now.Minute -lt 5)
  $catsFrom = if ($fullCats) { [datetime]'2026-01-01' } else { Get-Date -Day 1 -Hour 0 -Minute 0 -Second 0 -Millisecond 0 }
  $fullDeliv = $FullDeliv -or ($now.Hour -eq 3 -and $now.Minute -lt 5)
  $delivFrom = if ($fullDeliv) { [datetime]'2026-01-01' } else { $now.Date.AddDays(-3) }
  $fullCash = $FullCash -or ($now.Hour -eq 3 -and $now.Minute -lt 5)
  $cashFrom = if ($fullCash) { [datetime]'2026-01-01' } else { $now.Date.AddDays(-3) }
  if ($CashOnly) { $a = if ($DryRun) { $null } else { Get-Login }; Sync-Cash $a (-not $DryRun) $cashFrom; return }
  if ($DelivOnly) { $a = if ($DryRun) { $null } else { Get-Login }; Sync-Deliv $a (-not $DryRun) $delivFrom; return }
  if ($CatsOnly) { $a = if ($DryRun) { $null } else { Get-Login }; Sync-Cats $a (-not $DryRun) $catsFrom; return }
  if ($ChannelsOnly) { $a = if ($DryRun) { $null } else { Get-Login }; Sync-Channels $a (-not $DryRun) $chFrom; return }
  if ($GlOnly) { $a = if ($DryRun) { $null } else { Get-Login }; Sync-Gl $a (-not $DryRun) $glFrom; return }
  if ($InvOnly) { $a = if ($DryRun) { $null } else { Get-Login }; if (-not $SkipItems) { Sync-Items $a (-not $DryRun) }; Sync-Inv $a (-not $DryRun) $invFrom; return }
  if ($TbOnly) { $a = if ($DryRun) { $null } else { Get-Login }; Sync-Coa $a (-not $DryRun); Sync-Tb $a (-not $DryRun) $fullTb; return }
  $fullMoves = $FullMoves -or ($now.Hour -eq 3 -and $now.Minute -lt 5)   # once a day at 03:00 (+ on demand)
  if ($AccountsOnly) { Sync-AccountsAndMoves (Get-Login) (-not $DryRun) $fullMoves; return }
  $accountsDue = $ForceAccounts -or ($now.Minute % 30 -lt 5)
  $today = (Get-Date).Date
  $days  = @($today.AddDays(-1).ToString('yyyy-MM-dd'), $today.ToString('yyyy-MM-dd'))
  $from  = $today.AddDays(-1)
  $to    = $today.AddDays(1)

  # ---- 1) Read from Growth (SELECT only, NOLOCK) ----
  $gp = Find-Secret 'growth_pass.txt'
  $cs = "Server=$SqlServer;Database=$SqlDb;User ID=$SqlUser;Password=$gp;Connect Timeout=10;ApplicationIntent=ReadOnly;Application Name=platform-sync"
  $gp = $null
  $sql = @"
SELECT h.BranchId, h.SysSeq, h.Dt, h.BillType, h.SalType, st.AraName AS ChName, h.UserId,
       COALESCE(NULLIF(LTRIM(RTRIM(u.EmpName)),''), u.UserName) AS Cashier,
       h.Gross, h.Tax, h.Net, h.DiscAmt, h.ExtAmt, h.PaidAmt, h.RestAmt, h.VisaAmt, h.MasterAmt, h.PayType
FROM KitchPOSH h WITH (NOLOCK)
LEFT JOIN KitchSalTypes st WITH (NOLOCK) ON st.Id = h.SalType
LEFT JOIN Users u WITH (NOLOCK) ON u.UserId = h.UserId
WHERE h.Dt >= @from AND h.Dt < @to AND h.BranchId IN (2,3,5)
"@
  $conn = New-Object System.Data.SqlClient.SqlConnection $cs
  $conn.Open()
  $cmd = $conn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 60
  [void]$cmd.Parameters.AddWithValue('@from', $from)
  [void]$cmd.Parameters.AddWithValue('@to',   $to)
  $rdr = $cmd.ExecuteReader()
  $rows = New-Object System.Collections.Generic.List[object]
  while ($rdr.Read()) {
    $dt = [datetime]$rdr['Dt']
    $visa = N $rdr['VisaAmt']; $mst = N $rdr['MasterAmt']
    $rows.Add([ordered]@{
      branch       = $BranchMap[[int]$rdr['BranchId']]
      bill_id      = [string]$rdr['SysSeq']
      bdate        = $dt.ToString('yyyy-MM-dd')
      dt           = $dt.ToString("yyyy-MM-dd'T'HH:mm:ss") + '+03:00'
      bill_type    = [int](N $rdr['BillType'])
      channel      = [int](N $rdr['SalType'])
      channel_name = $(if ($rdr['ChName'] -is [DBNull]) { '' } else { [string]$rdr['ChName'] })
      cashier_id   = [int](N $rdr['UserId'])
      cashier      = $(if ($rdr['Cashier'] -is [DBNull]) { '' } else { [string]$rdr['Cashier'] })
      gross        = N $rdr['Gross']
      tax          = N $rdr['Tax']
      net          = N $rdr['Net']
      disc         = N $rdr['DiscAmt']
      extra        = N $rdr['ExtAmt']
      cash         = [math]::Round((N $rdr['PaidAmt']) - (N $rdr['RestAmt']) - $visa - $mst, 4)
      visa         = $visa
      master       = $mst
      pay_type     = [int](N $rdr['PayType'])
    })
  }
  $rdr.Close()

  # ---- 1b) Shifts: Growth keeps no live shift records (KitchCashrsShift/KitchCahRec2 are empty), so a
  #          shift = one cashier (SalMan) in one branch on one business day, derived from KitchPOSH. ----
  $sqlShift = @"
SELECT h.BranchId, h.SalMan, COALESCE(NULLIF(LTRIM(RTRIM(sm.Name)),''), NULLIF(LTRIM(RTRIM(u.EmpName)),''), u.UserName) AS Cashier,
       CONVERT(varchar(10), h.Dt, 120) AS Bdate, h.UserId, h.SalType, st.AraName AS ChName,
       SUM(CASE WHEN h.BillType <> 6 THEN 1 ELSE 0 END) AS Bills,
       SUM(CASE WHEN h.BillType <> 6 AND h.PayType <> 4 THEN h.Net ELSE 0 END) AS Sales,
       SUM(CASE WHEN h.BillType <> 6 AND h.PayType = 4 THEN h.Net ELSE 0 END) AS Credit,
       SUM(CASE WHEN h.BillType <> 6 THEN h.VisaAmt + h.MasterAmt + h.SpamAmt ELSE 0 END) AS Card,
       -SUM(CASE WHEN h.BillType = 6 THEN h.Net ELSE 0 END) AS Refunds,
       SUM(h.Net) AS AppNet,
       MIN(h.Dt) AS Opened, MAX(h.Dt) AS Closed
FROM KitchPOSH h WITH (NOLOCK)
LEFT JOIN SalesMenTble sm WITH (NOLOCK) ON sm.Id = h.SalMan
LEFT JOIN Users u WITH (NOLOCK) ON u.UserId = h.UserId
LEFT JOIN KitchSalTypes st WITH (NOLOCK) ON st.Id = h.SalType
WHERE h.Dt >= @from AND h.Dt < @to AND h.BranchId IN (2,3,5)
GROUP BY h.BranchId, h.SalMan, COALESCE(NULLIF(LTRIM(RTRIM(sm.Name)),''), NULLIF(LTRIM(RTRIM(u.EmpName)),''), u.UserName),
         CONVERT(varchar(10), h.Dt, 120), h.UserId, h.SalType, st.AraName
"@
  $cmd2 = $conn.CreateCommand(); $cmd2.CommandText = $sqlShift; $cmd2.CommandTimeout = 60
  [void]$cmd2.Parameters.AddWithValue('@from', $from)
  [void]$cmd2.Parameters.AddWithValue('@to',   $to)
  $rdr2 = $cmd2.ExecuteReader()
  $sh = @{}
  while ($rdr2.Read()) {
    $br = $BranchMap[[int]$rdr2['BranchId']]; $bd = [string]$rdr2['Bdate']; $sm = [int]$rdr2['SalMan']
    $key = "$br-$sm-$bd"
    if (-not $sh.ContainsKey($key)) {
      $sh[$key] = [ordered]@{ branch = $br; shift_id = $key; bdate = $bd; user_id = 0; cashier = ''; opened = $null; closed = $null
                              bills = 0; net = 0.0; sales = 0.0; credit = 0.0; deposit = 0.0; deposit_ret = 0.0; refunds = 0.0; due = 0.0
                              cash = 0.0; card = 0.0; apps = [ordered]@{}; _u = @{} }
    }
    $s = $sh[$key]
    if ($rdr2['Cashier'] -isnot [DBNull] -and -not $s.cashier) { $s.cashier = [string]$rdr2['Cashier'] }
    $o = [datetime]$rdr2['Opened']; $c = [datetime]$rdr2['Closed']
    if (-not $s.opened -or $o -lt $s.opened) { $s.opened = $o }
    if (-not $s.closed -or $c -gt $s.closed) { $s.closed = $c }
    $s.bills += [int](N $rdr2['Bills']);  $s.sales += N $rdr2['Sales'];  $s.credit += N $rdr2['Credit']
    $s.card  += N $rdr2['Card'];          $s.refunds += N $rdr2['Refunds']
    $uid = [int](N $rdr2['UserId']); $s._u[$uid] = [int]$s._u[$uid] + [int](N $rdr2['Bills'])
    $ch = [int](N $rdr2['SalType'])
    if ($ch -ne 0) {
      $cn = if ($rdr2['ChName'] -is [DBNull]) { "قناة $ch" } else { [string]$rdr2['ChName'] }
      $s.apps[$cn] = [math]::Round([double]$s.apps[$cn] + (N $rdr2['AppNet']), 4)
    }
  }
  $rdr2.Close()

  # ---- 1c) Deposits (تأمين) = KitchPOSMatrAmts.Amt, deposit returns = KitchPOSMatrAmtsRet.Amt, per cashier (SalMan) per day ----
  foreach ($kind in @(@{ tbl = 'KitchPOSMatrAmts'; field = 'deposit' }, @{ tbl = 'KitchPOSMatrAmtsRet'; field = 'deposit_ret' })) {
    $cmd3 = $conn.CreateCommand(); $cmd3.CommandTimeout = 60
    $cmd3.CommandText = @"
SELECT d.BranchId, d.SalMan, sm.Name AS Cashier, CONVERT(varchar(10), d.Dt, 120) AS Bdate, SUM(d.Amt) AS Amt, MIN(d.Dt) AS Opened, MAX(d.Dt) AS Closed
FROM $($kind.tbl) d WITH (NOLOCK)
LEFT JOIN SalesMenTble sm WITH (NOLOCK) ON sm.Id = d.SalMan
WHERE d.Dt >= @from AND d.Dt < @to AND d.BranchId IN (2,3,5)
GROUP BY d.BranchId, d.SalMan, sm.Name, CONVERT(varchar(10), d.Dt, 120)
"@
    [void]$cmd3.Parameters.AddWithValue('@from', $from)
    [void]$cmd3.Parameters.AddWithValue('@to',   $to)
    $rdr3 = $cmd3.ExecuteReader()
    while ($rdr3.Read()) {
      $br = $BranchMap[[int]$rdr3['BranchId']]; $bd = [string]$rdr3['Bdate']; $sm = [int]$rdr3['SalMan']
      $key = "$br-$sm-$bd"
      if (-not $sh.ContainsKey($key)) {   # cashier with deposits only
        $sh[$key] = [ordered]@{ branch = $br; shift_id = $key; bdate = $bd; user_id = $sm; cashier = $(if ($rdr3['Cashier'] -is [DBNull]) { '' } else { [string]$rdr3['Cashier'] })
                                opened = [datetime]$rdr3['Opened']; closed = [datetime]$rdr3['Closed']
                                bills = 0; net = 0.0; sales = 0.0; credit = 0.0; deposit = 0.0; deposit_ret = 0.0; refunds = 0.0; due = 0.0
                                cash = 0.0; card = 0.0; apps = [ordered]@{}; _u = @{} }
      }
      $sh[$key][$kind.field] += N $rdr3['Amt']
    }
    $rdr3.Close()
  }
  $conn.Close()
  $shiftRows = New-Object System.Collections.Generic.List[object]
  foreach ($s in $sh.Values) {
    if ($s._u.Count -gt 0) { $s.user_id = ($s._u.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key }
    $s.opened  = $s.opened.ToString("yyyy-MM-dd'T'HH:mm:ss") + '+03:00'
    $s.closed  = $s.closed.ToString("yyyy-MM-dd'T'HH:mm:ss") + '+03:00'
    $s.net  = $s.sales + $s.credit - $s.refunds
    $s.due  = $s.sales + $s.deposit - $s.deposit_ret - $s.refunds
    $s.cash = $s.due - $s.card
    foreach ($f in 'net','sales','credit','deposit','deposit_ret','refunds','due','cash','card') { $s[$f] = [math]::Round($s[$f], 2) }
    $s.Remove('_u')
    $shiftRows.Add($s)
  }
  Log ("built {0} shifts" -f $shiftRows.Count)
  Log ("read {0} bills from {1} for days {2}" -f $rows.Count, $SqlDb, ($days -join ','))
  foreach ($b in 'az','sh','pc') {
    $g = @($rows | Where-Object { $_.branch -eq $b })
    Log ("  {0}: {1} bills, net={2:N2}" -f $b, $g.Count, (($g | ForEach-Object { $_.net } | Measure-Object -Sum).Sum))
  }

  $body = @{ p_rows = $rows.ToArray(); p_days = $days } | ConvertTo-Json -Depth 5 -Compress
  $bodyShifts = @{ p_rows = $shiftRows.ToArray(); p_days = $days } | ConvertTo-Json -Depth 6 -Compress
  if ($DryRun) {
    Log "dry-run: bills payload $($body.Length) chars, shifts payload $($bodyShifts.Length) chars, not sent"
    if ($ShowShifts) { $shiftRows | ForEach-Object { '{0} | {1} | bills={2} sales={3} credit={4} net={5} refunds={6} deposit={10} deposit_ret={11} due={7} cash={8} card={9}' -f $_.shift_id, $_.cashier, $_.bills, $_.sales, $_.credit, $_.net, $_.refunds, $_.due, $_.cash, $_.card, $_.deposit, $_.deposit_ret } }
    Sync-AccountsAndMoves $null $false $fullMoves
    Sync-Items $null $false
    if ($accountsDue) { Sync-Coa $null $false }
    Sync-Tb $null $false $fullTb
    Sync-Inv $null $false $invFrom
    Sync-Gl $null $false $glFrom
    Sync-Channels $null $false $chFrom
    Sync-Cats $null $false $catsFrom
    Sync-Deliv $null $false $delivFrom
    Sync-Cash $null $false $cashFrom
    return
  }

  # ---- 2) Supabase login ----
  $auth = Get-Login

  # ---- 3) One ingest call with both days ----
  $bytes = [Text.Encoding]::UTF8.GetBytes($body)
  $res = Invoke-RestMethod -Method Post -Uri "$SbUrl/rest/v1/rpc/growth_ingest" `
         -Headers @{ apikey = $SbKey; Authorization = "Bearer $($auth.access_token)" } `
         -ContentType 'application/json; charset=utf-8' -Body $bytes
  if ($res.ok -ne $true) { throw ("ingest not ok: " + ($res | ConvertTo-Json -Compress)) }
  Log ("ingest ok, rows={0}" -f $res.rows)

  # ---- 4) Shifts, one call with both days ----
  $res2 = Invoke-RestMethod -Method Post -Uri "$SbUrl/rest/v1/rpc/growth_ingest_shifts" `
          -Headers @{ apikey = $SbKey; Authorization = "Bearer $($auth.access_token)" } `
          -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($bodyShifts))
  if ($res2.ok -ne $true) { throw ("shifts ingest not ok: " + ($res2 | ConvertTo-Json -Compress)) }
  Log ("shifts ingest ok, rows={0}" -f $res2.rows)

  # ---- 5) Customers/vendors balances + statement movements (last 3 days): every run. Items/stock: every run. Chart of accounts: every 30 min ----
  Sync-AccountsAndMoves $auth $true $fullMoves
  Sync-Items $auth $true
  if ($accountsDue) { Sync-Coa $auth $true }

  # ---- 6) Trial balance: current month every run; opening + all 2026 once a day at 03:00 ----
  Sync-Tb $auth $true $fullTb

  # ---- 7) Purchases / returns / direct issues: last 3 days every run; from 2026-01-01 once a day at 03:00 ----
  Sync-Inv $auth $true $invFrom

  # ---- 8) General-ledger lines: last 3 days every run; from 2026-01-01 once a day at 03:00 ----
  Sync-Gl $auth $true $glFrom

  # ---- 9) Sales by type: current month every run; from 2026-01-01 once a day at 03:00 ----
  Sync-Channels $auth $true $chFrom

  # ---- 10) Sales by category: current month every run; from 2026-01-01 once a day at 03:00 ----
  Sync-Cats $auth $true $catsFrom

  # ---- 11) Delivery drivers: last 3 days every run; from 2026-01-01 once a day at 03:00 ----
  Sync-Deliv $auth $true $delivFrom

  # ---- 12) Cashier sales: last 3 days every run; from 2026-01-01 once a day at 03:00 ----
  Sync-Cash $auth $true $cashFrom
}
catch {
  $msg = $_.Exception.Message
  if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg += ' | ' + $_.ErrorDetails.Message }
  elseif ($_.Exception.Response) {
    try { $msg += ' | ' + (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch {}
  }
  Log "ERROR: $msg"
  exit 1
}
