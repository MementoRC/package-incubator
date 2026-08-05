param([string]$Tag = "")

function Seg([string]$s) {
  if (-not $s) { return @() }
  return @($s -split ';' | Where-Object { $_ -ne '' })
}

$vars  = @(Get-ChildItem env:)
$total = 0
foreach ($v in $vars) { $total += $v.Name.Length + ("" + $v.Value).Length + 2 }

$p  = if ($env:PATH)    { $env:PATH.Length }    else { 0 }
$i  = if ($env:INCLUDE) { $env:INCLUDE.Length } else { 0 }
$l  = if ($env:LIB)     { $env:LIB.Length }     else { 0 }
$lp = if ($env:LIBPATH) { $env:LIBPATH.Length } else { 0 }

Write-Host ("[{0}] block={1} (limit ~32767)  vars={2}" -f $Tag, $total, $vars.Count)
Write-Host ("[{0}] PATH={1}  INCLUDE={2}  LIB={3}  LIBPATH={4}  (cmd line limit 8191)" -f $Tag, $p, $i, $l, $lp)

$pa = Seg $env:PATH
$ia = Seg $env:INCLUDE
$la = Seg $env:LIB
$lpa = Seg $env:LIBPATH
Write-Host ("[{0}] PATH    entries={1} unique={2}" -f $Tag, $pa.Count,  (@($pa  | Select-Object -Unique)).Count)
Write-Host ("[{0}] INCLUDE entries={1} unique={2}" -f $Tag, $ia.Count,  (@($ia  | Select-Object -Unique)).Count)
Write-Host ("[{0}] LIB     entries={1} unique={2}" -f $Tag, $la.Count,  (@($la  | Select-Object -Unique)).Count)
Write-Host ("[{0}] LIBPATH entries={1} unique={2}" -f $Tag, $lpa.Count, (@($lpa | Select-Object -Unique)).Count)

Write-Host ("[{0}] VSCMD_VER={1} VCToolsVersion={2} WindowsSDKVersion={3}" -f $Tag, $env:VSCMD_VER, $env:VCToolsVersion, $env:WindowsSDKVersion)

Write-Host ("[{0}] --- top 12 variables by size ---" -f $Tag)
$vars |
  ForEach-Object { [pscustomobject]@{ Name = $_.Name; Len = $_.Name.Length + ("" + $_.Value).Length + 2 } } |
  Sort-Object Len -Descending | Select-Object -First 12 |
  ForEach-Object { Write-Host ("[{0}] {1,8}  {2}" -f $Tag, $_.Len, $_.Name) }
