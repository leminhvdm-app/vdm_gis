Add-Type -AssemblyName System.Drawing

$srcPath = Join-Path $PSScriptRoot "assets\icon_app.png"
$baseRes = Join-Path $PSScriptRoot "android\app\src\main\res"

$sizes = @{
    "mipmap-mdpi" = 48
    "mipmap-hdpi" = 72
    "mipmap-xhdpi" = 96
    "mipmap-xxhdpi" = 144
    "mipmap-xxxhdpi" = 192
}

$srcImg = [System.Drawing.Image]::FromFile($srcPath)

foreach ($folder in $sizes.Keys) {
    $dim = $sizes[$folder]
    $destDir = Join-Path $baseRes $folder
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    $destPath = Join-Path $destDir "ic_launcher.png"
    
    $bmp = New-Object System.Drawing.Bitmap($dim, $dim)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    
    $g.DrawImage($srcImg, 0, 0, $dim, $dim)
    $g.Dispose()
    
    # Save as PNG
    if (Test-Path $destPath) {
        Remove-Item $destPath -Force
    }
    $bmp.Save($destPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host "Created: $destPath ($dim x $dim)"
}

$srcImg.Dispose()
Write-Host "All launcher icons generated successfully from icon_app.png!"
