$ErrorActionPreference = "Continue"
$USB_Drive = (Get-Item $MyInvocation.MyCommand.Path).Directory.Parent.FullName
$SharedRoot = Join-Path $USB_Drive "Shared"
$ModelsDir = Join-Path $SharedRoot "models"
$BinDir = Join-Path $SharedRoot "bin"
$PythonDir = Join-Path $SharedRoot "python"
$ChatDataDir = Join-Path $SharedRoot "chat_data"
$InstalledListPath = Join-Path $ModelsDir "installed-models.txt"
$LegacyModelfile = Join-Path $ModelsDir "Modelfile"
$OllamaExe = Join-Path $BinDir "ollama-windows.exe"
$OllamaDataDir = Join-Path $ModelsDir "ollama_data"
$OllamaRuntimeShared = Join-Path $SharedRoot ".ollama-runtime"
$OllamaRuntimeModels = Join-Path $ModelsDir ".ollama-runtime"

function Confirm-IsChildPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $sharedFull = [System.IO.Path]::GetFullPath($SharedRoot)
        $targetFull = [System.IO.Path]::GetFullPath($Path)
    } catch {
        return $false
    }
    return $targetFull.StartsWith($sharedFull, [System.StringComparison]::OrdinalIgnoreCase)
}

function Remove-SafePath {
    param([string]$Path, [string]$Label)

    if (-Not (Test-Path $Path)) {
        Write-Host "      Not found: $Label" -ForegroundColor DarkGray
        return
    }

    if (-Not (Confirm-IsChildPath -Path $Path)) {
        Write-Host "      SKIPPED (outside Shared): $Path" -ForegroundColor Yellow
        return
    }

    try {
        Remove-Item -LiteralPath $Path -Force -Recurse -ErrorAction Stop
        Write-Host "      Removed: $Label" -ForegroundColor Green
    } catch {
        Write-Host "      Failed to remove ${Label}: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Stop-EngineProcesses {
    Stop-Process -Name "ollama-windows" -Force -ErrorAction SilentlyContinue
    Stop-Process -Name "ollama" -Force -ErrorAction SilentlyContinue
    Stop-Process -Name "llama-server-android" -Force -ErrorAction SilentlyContinue
}

function Get-GGUFFileFromModelfile {
    param([string]$ModelfilePath)

    if (-Not (Test-Path $ModelfilePath)) { return $null }
    $fromLine = Get-Content -Path $ModelfilePath -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($fromLine -match '^\s*FROM\s+\./(.+)\s*$') {
        return $Matches[1].Trim()
    }
    return $null
}

function Get-ModelEntries {
    $map = @{}

    if (Test-Path $InstalledListPath) {
        $lines = Get-Content -Path $InstalledListPath -ErrorAction SilentlyContinue
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $parts = $line -split "\|"
            if ($parts.Count -lt 1) { continue }

            $local = $parts[0].Trim()
            if ([string]::IsNullOrWhiteSpace($local)) { continue }

            $name = if ($parts.Count -gt 1 -and -not [string]::IsNullOrWhiteSpace($parts[1])) { $parts[1].Trim() } else { $local }
            $mf = Join-Path $ModelsDir ("Modelfile-" + $local)
            $gguf = Get-GGUFFileFromModelfile -ModelfilePath $mf

            $map[$local] = [PSCustomObject]@{
                Local        = $local
                Name         = $name
                GGUFFile     = $gguf
                Modelfile    = $mf
            }
        }
    }

    $mfFiles = Get-ChildItem -Path $ModelsDir -File -Filter "Modelfile-*" -ErrorAction SilentlyContinue
    foreach ($mf in $mfFiles) {
        $local = $mf.Name.Substring("Modelfile-".Length)
        if ([string]::IsNullOrWhiteSpace($local)) { continue }
        $gguf = Get-GGUFFileFromModelfile -ModelfilePath $mf.FullName

        if ($map.ContainsKey($local)) {
            if ([string]::IsNullOrWhiteSpace($map[$local].GGUFFile)) {
                $map[$local].GGUFFile = $gguf
            }
            $map[$local].Modelfile = $mf.FullName
        } else {
            $map[$local] = [PSCustomObject]@{
                Local        = $local
                Name         = $local
                GGUFFile     = $gguf
                Modelfile    = $mf.FullName
            }
        }
    }

    return @($map.Values | Sort-Object Name)
}

function Select-Models {
    param([object[]]$Entries)

    if ($Entries.Count -eq 0) {
        Write-Host "      No installed models found." -ForegroundColor Yellow
        return @()
    }

    Write-Host ""
    Write-Host "Installed models:" -ForegroundColor White
    for ($i = 0; $i -lt $Entries.Count; $i++) {
        $m = $Entries[$i]
        $ggufLabel = if ([string]::IsNullOrWhiteSpace($m.GGUFFile)) { "unknown" } else { $m.GGUFFile }
        Write-Host "  [$($i + 1)] $($m.Name)  ($($m.Local))  -> $ggufLabel" -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "Select removal mode:" -ForegroundColor White
    Write-Host "  [1] One model" -ForegroundColor Yellow
    Write-Host "  [2] Many models" -ForegroundColor Yellow
    Write-Host "  [3] All models" -ForegroundColor Yellow
    Write-Host "  [Q] Cancel" -ForegroundColor DarkGray
    $mode = (Read-Host "Mode").Trim().ToLower()

    switch ($mode) {
        "1" {
            $numRaw = (Read-Host "Enter model number").Trim()
            if ($numRaw -notmatch '^\d+$') { return @() }
            $idx = [int]$numRaw - 1
            if ($idx -lt 0 -or $idx -ge $Entries.Count) { return @() }
            return @($Entries[$idx])
        }
        "2" {
            $raw = (Read-Host "Enter model numbers (comma separated, e.g. 1,3,4)").Trim()
            if ([string]::IsNullOrWhiteSpace($raw)) { return @() }

            $picked = @{}
            $selected = @()
            foreach ($token in ($raw -split ",")) {
                $t = $token.Trim()
                if ($t -notmatch '^\d+$') { continue }
                $idx = [int]$t - 1
                if ($idx -lt 0 -or $idx -ge $Entries.Count) { continue }
                $key = $Entries[$idx].Local
                if (-Not $picked.ContainsKey($key)) {
                    $picked[$key] = $true
                    $selected += $Entries[$idx]
                }
            }
            return $selected
        }
        "3" {
            return @($Entries)
        }
        default {
            return @()
        }
    }
}

function Remove-OllamaAliases {
    param([string[]]$Locals)

    if ($Locals.Count -eq 0) { return }
    if (-Not (Test-Path $OllamaExe)) {
        Write-Host "      Ollama binary not found. Skipping alias removal." -ForegroundColor DarkGray
        return
    }
    if (-Not (Test-Path $OllamaDataDir)) {
        Write-Host "      ollama_data not found. Skipping alias removal." -ForegroundColor DarkGray
        return
    }

    $env:OLLAMA_MODELS = $OllamaDataDir
    Stop-EngineProcesses
    Start-Sleep -Seconds 1

    try {
        $server = Start-Process -FilePath $OllamaExe -ArgumentList "serve" -WindowStyle Hidden -PassThru
    } catch {
        Write-Host "      Could not start Ollama server. Skipping alias removal." -ForegroundColor Yellow
        return
    }

    Start-Sleep -Seconds 4
    foreach ($local in ($Locals | Sort-Object -Unique)) {
        $null = & $OllamaExe rm $local 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "      Engine alias removed: $local" -ForegroundColor Green
        } else {
            Write-Host "      Alias '$local' not found in engine (skipped)." -ForegroundColor DarkGray
        }
    }

    if ($server) {
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    }
    Stop-EngineProcesses
}

function Update-InstalledList {
    param([string[]]$RemovedLocals)

    if (-Not (Test-Path $InstalledListPath)) { return }
    $lines = Get-Content -Path $InstalledListPath -ErrorAction SilentlyContinue
    $kept = @()

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $local = ($line -split "\|")[0].Trim()
        if ($RemovedLocals -notcontains $local) {
            $kept += $line
        }
    }

    if ($kept.Count -gt 0) {
        Set-Content -Path $InstalledListPath -Value ($kept -join "`n") -Force -Encoding UTF8
    } else {
        Remove-SafePath -Path $InstalledListPath -Label "installed-models.txt"
    }
}

function Refresh-LegacyModelfile {
    $remaining = Get-ModelEntries
    if ($remaining.Count -gt 0 -and (Test-Path $remaining[0].Modelfile)) {
        Copy-Item -LiteralPath $remaining[0].Modelfile -Destination $LegacyModelfile -Force
        Write-Host "      Updated legacy Modelfile to: $($remaining[0].Local)" -ForegroundColor DarkGray
    } else {
        Remove-SafePath -Path $LegacyModelfile -Label "Modelfile"
    }
}

function Run-ModelRemover {
    Write-Host ""
    Write-Host "[1/2] Remove selected model(s)" -ForegroundColor Yellow

    $entries = Get-ModelEntries
    $selected = Select-Models -Entries $entries
    if ($selected.Count -eq 0) {
        Write-Host "      Nothing selected. Cancelled." -ForegroundColor Yellow
        return
    }

    $locals = @($selected | ForEach-Object { $_.Local })
    Remove-OllamaAliases -Locals $locals

    foreach ($m in $selected) {
        if (-not [string]::IsNullOrWhiteSpace($m.GGUFFile)) {
            Remove-SafePath -Path (Join-Path $ModelsDir $m.GGUFFile) -Label ("models\" + $m.GGUFFile)
        }
        Remove-SafePath -Path $m.Modelfile -Label ("models\" + [System.IO.Path]::GetFileName($m.Modelfile))
    }

    Update-InstalledList -RemovedLocals $locals
    Refresh-LegacyModelfile

    $remaining = Get-ModelEntries
    if ($remaining.Count -eq 0) {
        Remove-SafePath -Path $OllamaDataDir -Label "models\\ollama_data"
        Remove-SafePath -Path $OllamaRuntimeShared -Label ".ollama-runtime"
        Remove-SafePath -Path $OllamaRuntimeModels -Label "models\\.ollama-runtime"
    }
}

function Run-DownloadedDataCleanup {
    Write-Host ""
    Write-Host "[2/2] Remove all downloaded files (keeping base files)" -ForegroundColor Yellow

    Stop-EngineProcesses

    if (Test-Path $ModelsDir) {
        $ggufs = Get-ChildItem -Path $ModelsDir -File -Filter "*.gguf" -ErrorAction SilentlyContinue
        foreach ($g in $ggufs) {
            Remove-SafePath -Path $g.FullName -Label ("models\" + $g.Name)
        }

        $modelfiles = Get-ChildItem -Path $ModelsDir -File -Filter "Modelfile*" -ErrorAction SilentlyContinue
        foreach ($m in $modelfiles) {
            Remove-SafePath -Path $m.FullName -Label ("models\" + $m.Name)
        }
    }

    Remove-SafePath -Path $InstalledListPath -Label "models\\installed-models.txt"
    Remove-SafePath -Path $OllamaDataDir -Label "models\\ollama_data"
    Remove-SafePath -Path $OllamaRuntimeShared -Label ".ollama-runtime"
    Remove-SafePath -Path $OllamaRuntimeModels -Label "models\\.ollama-runtime"

    Remove-SafePath -Path (Join-Path $BinDir "ollama-windows.exe") -Label "bin\\ollama-windows.exe"
    Remove-SafePath -Path (Join-Path $BinDir "ollama-linux") -Label "bin\\ollama-linux"
    Remove-SafePath -Path (Join-Path $BinDir "ollama-darwin") -Label "bin\\ollama-darwin"
    Remove-SafePath -Path (Join-Path $BinDir "llama-server-android") -Label "bin\\llama-server-android"
    Remove-SafePath -Path (Join-Path $BinDir "llama.cpp") -Label "bin\\llama.cpp"
    Remove-SafePath -Path (Join-Path $BinDir "temp_ollama") -Label "bin\\temp_ollama"
    Remove-SafePath -Path (Join-Path $SharedRoot "llama-server.log") -Label "llama-server.log"
    Remove-SafePath -Path (Join-Path $SharedRoot "__pycache__") -Label "__pycache__"

    Remove-SafePath -Path (Join-Path $SharedRoot "python-embed.zip") -Label "python-embed.zip"
    Remove-SafePath -Path $PythonDir -Label "python"
    Remove-SafePath -Path $ChatDataDir -Label "chat_data"
}

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "   PORTABLE AI UNINSTALLER                                " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  [1] Remove selected model(s) (one / many / all)" -ForegroundColor Yellow
Write-Host "  [2] Remove all downloaded files (except base files)" -ForegroundColor Yellow
Write-Host "  [Q] Quit" -ForegroundColor DarkGray
Write-Host ""

$choice = (Read-Host "Your choice").Trim().ToLower()
if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "q" }

switch ($choice) {
    "1" { Run-ModelRemover }
    "2" { Run-DownloadedDataCleanup }
    default {
        Write-Host ""
        Write-Host "Uninstall cancelled." -ForegroundColor Yellow
        exit 0
    }
}

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "   UNINSTALL COMPLETE                                     " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Press any key to close..." -ForegroundColor Yellow
$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
