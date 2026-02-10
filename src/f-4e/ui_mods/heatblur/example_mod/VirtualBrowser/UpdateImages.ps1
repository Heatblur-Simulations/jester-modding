# ══════════════════════════════════════════════════════════════
#  Grease Pencil – Update Images.json
#  Run this script to scan the Images folder and update the list
# ══════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "====================================" -ForegroundColor Cyan
Write-Host "  Grease Pencil - Image Updater" -ForegroundColor Cyan
Write-Host "====================================" -ForegroundColor Cyan
Write-Host ""

# Get the script's directory
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$imagesDir = Join-Path $scriptDir "Images"
$jsonPath = Join-Path $imagesDir "Images.json"

Write-Host "[GreasePencil] Scanning: $imagesDir" -ForegroundColor Yellow

# Check if Images folder exists
if (-not (Test-Path $imagesDir)) {
    Write-Host "[ERROR] Images folder not found!" -ForegroundColor Red
    Write-Host "Expected: $imagesDir" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit
}

# Define valid image extensions
$validExtensions = @(".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".svg")

# Get all image files
$imageFiles = Get-ChildItem -Path $imagesDir -File | Where-Object {
    $validExtensions -contains $_.Extension.ToLower()
} | Sort-Object Name | Select-Object -ExpandProperty Name

# Convert to array (handle single item case)
$imageArray = @($imageFiles)

Write-Host ""
Write-Host "[GreasePencil] Found $($imageArray.Count) image(s):" -ForegroundColor Green

foreach ($img in $imageArray) {
    Write-Host "  - $img" -ForegroundColor Gray
}

# Create the JSON structure
$jsonContent = @{
    images = $imageArray
} | ConvertTo-Json -Depth 10

# Write to file
$jsonContent | Out-File -FilePath $jsonPath -Encoding UTF8 -Force

Write-Host ""
Write-Host "[GreasePencil] Images.json updated successfully!" -ForegroundColor Green
Write-Host "Saved to: $jsonPath" -ForegroundColor Gray
Write-Host ""
Read-Host "Press Enter to close"
