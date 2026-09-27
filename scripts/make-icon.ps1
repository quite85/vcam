# make-icon.ps1 —— 生成 Sileo 软件源图标 CydiaIcon.png（256x256）
#
# 为什么手写 PNG：CI 上的 make-icon.sh 依赖 python3/ImageMagick，没成功产出。
# 这里用 .NET 的 DeflateStream + 手写 CRC32 生成合法 PNG，
# 只依赖 System.IO.Compression，任何 Windows 都能跑。
#
# 两个 Windows PowerShell 5.1 的坑（本脚本已规避）：
#   1) 本文件必须保存为**带 BOM 的 UTF-8**。
#      无 BOM 时 PS 5.1 按 ANSI 读 .ps1，中文注释会乱码并引发语法错误。
#   2) 不要写 [uint32]0xFFFFFFFF —— PS 5.1 会把它解析成有符号 -1，
#      再转 uint32 就报 "Value was either too large or too small"。
#      一律用十进制字面量（4294967295 / 3988292384 等）。
#
# 图形：蓝紫渐变圆角方块 + 白色相机轮廓 + 红色录制点。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\make-icon.ps1

Add-Type -AssemblyName System.IO.Compression | Out-Null

$POLY = [uint32]3988292384      # 0xEDB88320
$ALLF = [uint32]4294967295      # 0xFFFFFFFF

# ---------- CRC32 ----------
$CrcTable = New-Object 'uint32[]' 256
for ($n = 0; $n -lt 256; $n++) {
    $c = [uint32]$n
    for ($k = 0; $k -lt 8; $k++) {
        if (($c -band 1) -ne 0) { $c = $POLY -bxor ($c -shr 1) }
        else                    { $c = $c -shr 1 }
    }
    $CrcTable[$n] = $c
}

function Get-Crc32([byte[]]$data) {
    $c = $ALLF
    foreach ($b in $data) {
        # 注意：PowerShell 的数组下标里不能直接写 int(...)，
        #       必须先把索引算到一个变量里再 $arr[$var]。
        $idx = [int](($c -bxor $b) -band 255)
        $c = $CrcTable[$idx] -bxor ($c -shr 8)
    }
    return [uint32]($c -bxor $ALLF)
}

# ---------- Adler32 ----------
function Get-Adler32([byte[]]$data) {
    $a = [uint32]1; $b = [uint32]0
    foreach ($x in $data) {
        $a = ($a + $x) % 65521
        $b = ($b + $a) % 65521
    }
    return [uint32](($b -shl 16) -bor $a)
}

# ---------- 构造 PNG chunk ----------
function New-PngChunk([string]$type, [byte[]]$data) {
    $len = [BitConverter]::GetBytes([uint32]$data.Length)
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($len) }
    $t = [System.Text.Encoding]::ASCII.GetBytes($type)
    $payload = New-Object byte[] ($t.Length + $data.Length)
    [Array]::Copy($t, 0, $payload, 0, $t.Length)
    [Array]::Copy($data, 0, $payload, $t.Length, $data.Length)
    $cb = [BitConverter]::GetBytes((Get-Crc32 $payload))
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($cb) }
    $out = New-Object byte[] (4 + $payload.Length + 4)
    [Array]::Copy($len, 0, $out, 0, 4)
    [Array]::Copy($payload, 0, $out, 4, $payload.Length)
    [Array]::Copy($cb, 0, $out, 4 + $payload.Length, 4)
    return $out
}

# ---------- 画图 ----------
$SIZE = 256
$R    = 56                      # 圆角半径
# 取值：0=透明(角外) 1=渐变底 2=白 3=红
$img = New-Object 'byte[,]' $SIZE, $SIZE

function Test-InRoundedRect([int]$x, [int]$y, [int]$w, [int]$h, [int]$r) {
    if ($x -lt 0 -or $y -lt 0 -or $x -ge $w -or $y -ge $h) { return $false }
    $outX = ($x -lt $r) -or ($x -ge ($w - $r))
    $outY = ($y -lt $r) -or ($y -ge ($h - $r))
    if ($outX -and $outY) {
        if ($x -lt $r) { $cx = $r } else { $cx = $w - $r - 1 }
        if ($y -lt $r) { $cy = $r } else { $cy = $h - $r - 1 }
        $dx = $x - $cx; $dy = $y - $cy
        return (($dx * $dx + $dy * $dy) -le ($r * $r))
    }
    return $true
}

for ($y = 0; $y -lt $SIZE; $y++) {
    for ($x = 0; $x -lt $SIZE; $x++) {
        if (Test-InRoundedRect $x $y $SIZE $SIZE $R) { $img[$x, $y] = 1 }
    }
}

function Set-Rect([int]$x0, [int]$y0, [int]$w, [int]$h, [byte]$v) {
    for ($y = $y0; $y -lt ($y0 + $h); $y++) {
        for ($x = $x0; $x -lt ($x0 + $w); $x++) {
            if ($x -ge 0 -and $y -ge 0 -and $x -lt $SIZE -and $y -lt $SIZE) { $img[$x, $y] = $v }
        }
    }
}
function Set-Disc([int]$cx, [int]$cy, [int]$r, [byte]$v) {
    for ($y = ($cy - $r); $y -le ($cy + $r); $y++) {
        for ($x = ($cx - $r); $x -le ($cx + $r); $x++) {
            if ($x -lt 0 -or $y -lt 0 -or $x -ge $SIZE -or $y -ge $SIZE) { continue }
            $dx = $x - $cx; $dy = $y - $cy
            if (($dx * $dx + $dy * $dy) -le ($r * $r)) { $img[$x, $y] = $v }
        }
    }
}

Set-Rect  56  88 144 88 2      # 机身
Set-Rect 100  68  56 24 2      # 取景器凸起
Set-Disc 128 132  33 2         # 镜头外圈（白）
Set-Disc 128 132  21 1         # 镜头内圈（底色）
Set-Disc 186 104  10 3         # 录制红点

# ---------- 原始 RGBA（每行前置 1 字节 filter=0） ----------
$rowBytes = 1 + $SIZE * 4
$raw = New-Object byte[] ($rowBytes * $SIZE)
$i = 0
for ($y = 0; $y -lt $SIZE; $y++) {
    $raw[$i] = 0; $i++
    for ($x = 0; $x -lt $SIZE; $x++) {
        $v = $img[$x, $y]
        if ($v -eq 1) {
            $t = ($x + $y) / (2.0 * ($SIZE - 1))
            $raw[$i]   = [byte][int](0x4C + (0x7B - 0x4C) * $t)
            $raw[$i+1] = [byte][int](0x8D + (0x5C - 0x8D) * $t)
            $raw[$i+2] = [byte]255
            $raw[$i+3] = [byte]255
        } elseif ($v -eq 2) {
            $raw[$i]=255; $raw[$i+1]=255; $raw[$i+2]=255; $raw[$i+3]=255
        } elseif ($v -eq 3) {
            $raw[$i]=255; $raw[$i+1]=59;  $raw[$i+2]=48;  $raw[$i+3]=255
        } else {
            $raw[$i]=0; $raw[$i+1]=0; $raw[$i+2]=0; $raw[$i+3]=0
        }
        $i += 4
    }
}

# ---------- zlib：0x78 0x01 + deflate + adler32 ----------
$ms = New-Object System.IO.MemoryStream
$ms.WriteByte(0x78); $ms.WriteByte(0x01)
$ds = New-Object System.IO.Compression.DeflateStream($ms, [System.IO.Compression.CompressionMode]::Compress, $true)
$ds.Write($raw, 0, $raw.Length)
$ds.Dispose()
$ab = [BitConverter]::GetBytes((Get-Adler32 $raw))
if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($ab) }
$ms.Write($ab, 0, 4)
$zlib = $ms.ToArray()
$ms.Dispose()

# ---------- IHDR ----------
$ihdr = New-Object byte[] 13
$w4 = [BitConverter]::GetBytes([uint32]$SIZE)
if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($w4) }
[Array]::Copy($w4, 0, $ihdr, 0, 4)
[Array]::Copy($w4, 0, $ihdr, 4, 4)
$ihdr[8]  = 8
$ihdr[9]  = 6
$ihdr[10] = 0
$ihdr[11] = 0
$ihdr[12] = 0

# ---------- 拼装 ----------
$out = New-Object System.IO.MemoryStream
$sig = [byte[]]@(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
$out.Write($sig, 0, $sig.Length)
foreach ($chunk in @(
    (New-PngChunk 'IHDR' $ihdr),
    (New-PngChunk 'IDAT' $zlib),
    (New-PngChunk 'IEND' ([byte[]]@()))
)) {
    $out.Write($chunk, 0, $chunk.Length)
}

$outPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\repo\CydiaIcon.png'))
[System.IO.File]::WriteAllBytes($outPath, $out.ToArray())
$out.Dispose()
Write-Host "已生成: $outPath  ($((Get-Item $outPath).Length) 字节)"
