# Blood Trail Mod Menu - Version Switcher (and installer)
#
#   VERSION SWITCHER - Double-Click Me.bat   opens the window
#   INSTALL - Double-Click Me.bat            puts the newest version in, no questions
#
# When a version is picked it:
#   1. finds Blood Trail (Steam's own list of game folders, then the usual
#      folders on every drive, then asks you to show it the folder)
#   2. stops if the game or the Mod Menu app is running
#   3. sets up UE4SS (the mod loader) if the game does not have it yet, and
#      makes sure its settings have the two lines Blood Trail needs
#   4. saves a copy of the Mod Menu you have now, in "Switcher files\Backups"
#   5. copies the version in. Your own files - settings, profiles, music
#      list - are never overwritten and never removed
#   6. writes YOUR game folder into the scripts that name it (they were
#      written for a game on D:\SteamLibrary)
#   7. checks every file it copied, byte for byte
#
# A version is just a folder in "Versions" with a ModMenu folder inside and
# an about.txt. Drop another one in and it shows up in the window.

param(
    [switch]$Install,        # no window: install the newest version and say what happened
    [string]$Version,        # with -Install: this version folder instead of the newest
    [string]$GameFolder,     # use this game folder instead of looking for one
    [switch]$NoShortcut,     # with -Install: do not put a shortcut on the desktop
    [switch]$Check           # change nothing: say where the game is and which version it has
)

$ErrorActionPreference = 'Stop'
$Here     = Split-Path -Parent $MyInvocation.MyCommand.Path      # ...\Switcher files
$Package  = Split-Path -Parent $Here
$Versions = Join-Path $Package 'Versions'
$Backups  = Join-Path $Here 'Backups'
$Remember = Join-Path $Here 'game-folder.txt'
$UE4SSDir = Join-Path $Here 'UE4SS'
$GameExe  = 'BTVR-Win64-Shipping.exe'
$AppName  = 'Blood Trail Mod Menu'

# The player's own files. Never copied over, never removed.
$PlayerFiles = @('control.txt', 'status.txt', 'status-prev.txt', 'breadcrumb.txt',
    'saved_settings.txt', 'saved_profile*.txt', 'lastop.txt', 'lastop-prev.txt',
    'sessions.txt', 'music.json', 'pointercal.txt', 'enabled.txt', '*.tmp', '*.before-*')

function Test-PlayerFile([string]$name) {
    foreach ($p in $PlayerFiles) { if ($name -like $p) { return $true } }
    return $false
}

function Test-SameFile([string]$a, [string]$b) {
    if (-not (Test-Path -LiteralPath $b)) { return $false }
    if ((Get-Item -LiteralPath $a).Length -ne (Get-Item -LiteralPath $b).Length) { return $false }
    return (Get-FileHash -LiteralPath $a -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $b -Algorithm SHA256).Hash
}

# THE FOLDER THE MOD TALKS THROUGH. The mod's scripts name the ModMenu folder
# the headset and the desktop app swap notes in (control.txt, status.txt, the
# saves, the laser calibration). They were written on a PC with the game on
# D:\SteamLibrary - on any other PC the mod looked for a folder that is not
# there. Every copy gets its own game folder written in as it goes in.
$BuiltForDir = 'D:/SteamLibrary/steamapps/common/Blood Trail/BTVR/Binaries/Win64/Mods/ModMenu/'

function Get-ModMenuDirText([string]$win64) {
    return (($win64 -replace '\\', '/').TrimEnd('/') + '/Mods/ModMenu/')
}

# The bytes a version's file should have once it is in THIS game.
function Get-WantedBytes([string]$src, [string]$rel, [string]$win64) {
    $bytes = [System.IO.File]::ReadAllBytes($src)
    if (-not $rel.EndsWith('.lua', [StringComparison]::OrdinalIgnoreCase)) { return , $bytes }
    $here = Get-ModMenuDirText $win64
    if ($here -ieq $BuiltForDir) { return , $bytes }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if (-not $text.Contains($BuiltForDir)) { return , $bytes }
    return , [System.Text.Encoding]::UTF8.GetBytes($text.Replace($BuiltForDir, $here))
}

function Get-BytesHash([byte[]]$bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($bytes)) } finally { $sha.Dispose() }
}

# Is this version's file in the game, as it should be for this game?
function Test-Installed([string]$src, [string]$rel, [string]$dst, [string]$win64) {
    if (-not $rel.EndsWith('.lua', [StringComparison]::OrdinalIgnoreCase)) { return (Test-SameFile $src $dst) }
    if (-not (Test-Path -LiteralPath $dst)) { return $false }
    $want = Get-WantedBytes $src $rel $win64
    if ((Get-Item -LiteralPath $dst).Length -ne $want.Length) { return $false }
    return (Get-BytesHash $want) -eq (Get-BytesHash ([System.IO.File]::ReadAllBytes($dst)))
}

# ---------------------------------------------------------------------------
# the versions in this package, newest first
# ---------------------------------------------------------------------------
function Get-VersionList {
    $list = @()
    $dirs = Get-ChildItem -LiteralPath $Versions -Directory | Sort-Object @{
        Expression = { if ($_.Name -match '^V(\d+)') { [int]$Matches[1] } else { 0 } }; Descending = $true
    }, @{ Expression = 'Name'; Descending = $true }
    foreach ($d in $dirs) {
        $mm = Join-Path $d.FullName 'ModMenu'
        if (-not (Test-Path -LiteralPath (Join-Path $mm 'Scripts\main.lua'))) { continue }
        $about = ''
        $t = Join-Path $d.FullName 'about.txt'
        if (Test-Path -LiteralPath $t) { $about = (Get-Content -LiteralPath $t -Raw).Trim() }
        $files = @(Get-ChildItem -LiteralPath $mm -Recurse -File |
            Where-Object { -not (Test-PlayerFile $_.Name) } |
            ForEach-Object { $_.FullName.Substring($mm.Length + 1) })
        $list += [pscustomobject]@{ Name = $d.Name; Dir = $mm; About = $about; Files = $files }
    }
    return , $list
}

# ---------------------------------------------------------------------------
# finding the game
# ---------------------------------------------------------------------------
# Takes the game folder, BTVR, Binaries or Win64 itself; answers with Win64.
function Find-Win64([string]$folder) {
    if (-not $folder) { return $null }
    foreach ($sub in @('BTVR\Binaries\Win64', 'Binaries\Win64', 'Win64', '.')) {
        $w = Join-Path $folder $sub
        if (Test-Path -LiteralPath (Join-Path $w $GameExe)) {
            return (Resolve-Path -LiteralPath $w).ProviderPath
        }
    }
    return $null
}

function Find-Game {
    if ($GameFolder) { return (Find-Win64 $GameFolder) }
    if (Test-Path -LiteralPath $Remember) {
        $w = Find-Win64 ((Get-Content -LiteralPath $Remember -Raw).Trim())
        if ($w) { return $w }
    }
    $libs = New-Object System.Collections.Generic.List[string]
    # Steam itself, and every library folder it knows about
    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
                       'HKLM:\SOFTWARE\Valve\Steam')) {
        try {
            $p = Get-ItemProperty -Path $key -ErrorAction Stop
            foreach ($v in @($p.SteamPath, $p.InstallPath)) {
                if ($v) { $libs.Add(($v -replace '/', '\')) }
            }
        } catch {}
    }
    foreach ($steam in @($libs)) {
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            $text = Get-Content -LiteralPath $vdf -Raw
            foreach ($m in [regex]::Matches($text, '"path"\s+"([^"]+)"')) {
                $libs.Add(($m.Groups[1].Value -replace '\\\\', '\'))
            }
        }
    }
    # the usual places on every drive, in case Steam is not telling
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $drive.IsReady) { continue }
        if ($drive.DriveType -ne 'Fixed' -and $drive.DriveType -ne 'Removable') { continue }
        $r = $drive.RootDirectory.FullName
        foreach ($s in @('SteamLibrary', 'Steam', 'Program Files (x86)\Steam', 'Program Files\Steam',
                         'Games\SteamLibrary', 'Games\Steam')) {
            $libs.Add((Join-Path $r $s))
        }
    }
    foreach ($lib in $libs) {
        $w = Find-Win64 (Join-Path $lib 'steamapps\common\Blood Trail')
        if ($w) { return $w }
    }
    return $null
}

function Select-GameFolder {
    Add-Type -AssemblyName System.Windows.Forms
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = 'Show me your Blood Trail folder.' + [Environment]::NewLine +
        '(In Steam: right-click Blood Trail > Manage > Browse local files.)'
    $d.ShowNewFolderButton = $false
    if ($d.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    $w = Find-Win64 $d.SelectedPath
    if ($w) {
        try { Set-Content -LiteralPath $Remember -Value $w -Encoding UTF8 } catch {}
    }
    return $w
}

# The game folder people recognise: the one with BTVR in it.
function Get-GameRoot([string]$win64) {
    $root = Split-Path (Split-Path (Split-Path $win64 -Parent) -Parent) -Parent
    if ($root) { return $root } else { return $win64 }
}

# ---------------------------------------------------------------------------
# which version is in the game now
# ---------------------------------------------------------------------------
# A version name, 'none' (no Mod Menu at all) or 'other' (one not in here).
function Get-InstalledVersion([string]$win64, $versions) {
    $mm = Join-Path $win64 'Mods\ModMenu'
    if (-not (Test-Path -LiteralPath (Join-Path $mm 'Scripts\main.lua'))) { return 'none' }
    foreach ($v in $versions) {
        $same = $true
        foreach ($rel in $v.Files) {
            if (-not (Test-Installed (Join-Path $v.Dir $rel) $rel (Join-Path $mm $rel) $win64)) { $same = $false; break }
        }
        if ($same) { return $v.Name }
    }
    return 'other'
}

# ---------------------------------------------------------------------------
# UE4SS - the mod loader
# ---------------------------------------------------------------------------
# Sets Key = value inside [section], adding either if missing. Lines in, lines out.
function Set-IniValue($lines, [string]$section, [string]$key, [string]$value) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($l in $lines) { $out.Add([string]$l) }
    $start = -1
    for ($i = 0; $i -lt $out.Count; $i++) {
        if ($out[$i].Trim() -ieq "[$section]") { $start = $i; break }
    }
    if ($start -lt 0) {
        while ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq '') { $out.RemoveAt($out.Count - 1) }
        $out.Add(''); $out.Add("[$section]"); $out.Add("$key = $value"); $out.Add('')
        return , $out
    }
    $end = $out.Count
    for ($i = $start + 1; $i -lt $out.Count; $i++) {
        if ($out[$i].Trim().StartsWith('[')) { $end = $i; break }
    }
    $last = $start
    for ($i = $start + 1; $i -lt $end; $i++) {
        if ($out[$i] -match ('^\s*' + [regex]::Escape($key) + '\s*=')) {
            $out[$i] = "$key = $value"
            return , $out
        }
        if ($out[$i].Trim() -ne '') { $last = $i }
    }
    $out.Insert($last + 1, "$key = $value")
    return , $out
}

function Initialize-UE4SS([string]$win64, [scriptblock]$say) {
    $dll  = Join-Path $win64 'UE4SS.dll'
    $prox = Join-Path $win64 'dwmapi.dll'
    $ini  = Join-Path $win64 'UE4SS-settings.ini'
    New-Item -ItemType Directory -Force (Join-Path $win64 'Mods') | Out-Null

    if (-not (Test-Path -LiteralPath $dll) -and -not (Test-Path -LiteralPath $prox) -and
        -not (Test-Path -LiteralPath "$prox.off")) {
        & $say 'UE4SS (the mod loader) is not in your game yet - setting it up...'
        Copy-Item -LiteralPath (Join-Path $UE4SSDir 'dwmapi.dll') -Destination $prox
        Copy-Item -LiteralPath (Join-Path $UE4SSDir 'UE4SS.dll') -Destination $dll
        if (-not (Test-Path -LiteralPath $ini)) {
            Copy-Item -LiteralPath (Join-Path $UE4SSDir 'UE4SS-settings.ini') -Destination $ini
        }
        & $say '  UE4SS set up.'
    } elseif ((Test-Path -LiteralPath "$prox.off") -and -not (Test-Path -LiteralPath $prox)) {
        & $say 'NOTE: UE4SS is switched OFF in your game (dwmapi.dll is renamed dwmapi.dll.off).'
        & $say '      The Mod Menu will not run until it is switched back on.'
    } elseif (-not (Test-Path -LiteralPath $dll)) {
        & $say 'NOTE: UE4SS.dll is missing from your game folder - the Mod Menu needs it.'
    } else {
        & $say 'UE4SS (the mod loader) is already in your game.'
    }

    if (-not (Test-Path -LiteralPath $ini)) { return }
    # The two lines Blood Trail needs. Your file is kept as a .before-modmenu copy.
    $bytes = [System.IO.File]::ReadAllBytes($ini)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [System.IO.File]::ReadAllText($ini)
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = $text -split "`r?`n"
    $new = Set-IniValue $lines 'EngineVersionOverride' 'MajorVersion' '4'
    $new = Set-IniValue $new 'EngineVersionOverride' 'MinorVersion' '27'
    $new = Set-IniValue $new 'Hooks' 'HookLoadMap' '0'
    $newText = [string]::Join($nl, $new)
    if ($newText -eq $text) {
        & $say '  Its settings are already right for Blood Trail.'
        return
    }
    $keep = "$ini.before-modmenu"
    if (-not (Test-Path -LiteralPath $keep)) { Copy-Item -LiteralPath $ini -Destination $keep }
    [System.IO.File]::WriteAllText($ini, $newText, (New-Object System.Text.UTF8Encoding($bom)))
    & $say '  Set its engine to 4.27 and turned off its map-load hook (your old file:'
    & $say '  UE4SS-settings.ini.before-modmenu).'
}

# "ModMenu : 1" in Mods\mods.txt, so UE4SS loads it.
function Enable-ModMenu([string]$win64) {
    $p = Join-Path $win64 'Mods\mods.txt'
    if (-not (Test-Path -LiteralPath $p)) {
        [System.IO.File]::WriteAllText($p, "ModMenu : 1`r`n")
        return
    }
    $text = [System.IO.File]::ReadAllText($p)
    if ($text -match '(?m)^[ \t]*ModMenu[ \t]*:[ \t]*1[ \t]*\r?$') { return }
    if ($text -match '(?m)^[ \t]*ModMenu[ \t]*:') {
        $text = [regex]::Replace($text, '(?m)^[ \t]*ModMenu[ \t]*:[^\r\n]*', 'ModMenu : 1')
    } else {
        if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += "`r`n" }
        $text += "ModMenu : 1`r`n"
    }
    [System.IO.File]::WriteAllText($p, $text)
}

# ---------------------------------------------------------------------------
# putting a version in
# ---------------------------------------------------------------------------
function Install-ModVersion($v, [string]$win64, $versions, [scriptblock]$say) {
    $mm = Join-Path $win64 'Mods\ModMenu'

    if (Get-Process -Name 'BTVR-Win64-Shipping' -ErrorAction SilentlyContinue) {
        throw 'Blood Trail is running. Close the game first, then try again.'
    }
    $app = @(Get-Process -Name $AppName -ErrorAction SilentlyContinue | Where-Object {
        -not $_.Path -or $_.Path.StartsWith($mm, [StringComparison]::OrdinalIgnoreCase) })
    if ($app.Count) {
        throw 'The Blood Trail Mod Menu app is open. Close its window (and the music player), then try again.'
    }

    & $say "Game: $(Get-GameRoot $win64)"
    Initialize-UE4SS $win64 $say

    # 1. keep what is there now
    $before = @{}
    if (Test-Path -LiteralPath (Join-Path $mm 'Scripts\main.lua')) {
        $had = Get-InstalledVersion $win64 $versions
        $label = if ($had -eq 'other') { 'another version' } else { $had }
        $dest = Join-Path $Backups ((Get-Date -Format 'yyyy-MM-dd HH-mm-ss') + ' - you had ' + $label)
        & $say "Saving a copy of the version you have now ($label)..."
        robocopy $mm $dest /E /XD __pycache__ Screenshots /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) {
            throw "Could not save a copy of the version you have now, so nothing was changed. (robocopy $LASTEXITCODE)"
        }
        & $say "  saved in: Switcher files\Backups\$(Split-Path $dest -Leaf)"
        foreach ($f in Get-ChildItem -LiteralPath $mm -File) {
            if (Test-PlayerFile $f.Name) { $before[$f.Name] = (Get-FileHash -LiteralPath $f.FullName).Hash }
        }
    }

    # 2. copy the version in - never over the player's own files
    & $say "Putting in $($v.Name)..."
    New-Item -ItemType Directory -Force $mm | Out-Null
    robocopy $v.Dir $mm /E /XD __pycache__ Screenshots /XF $PlayerFiles /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "Copying failed (robocopy $LASTEXITCODE). Close anything using the game folder and try again - if it still fails, right-click the .bat and Run as administrator. Your previous version is saved in Switcher files\Backups."
    }
    $en = Join-Path $v.Dir 'enabled.txt'
    if ((Test-Path -LiteralPath $en) -and -not (Test-Path -LiteralPath (Join-Path $mm 'enabled.txt'))) {
        Copy-Item -LiteralPath $en -Destination (Join-Path $mm 'enabled.txt')
    }

    # 3. take out files that belong only to the OTHER versions (a newer
    #    version's extra scripts, when going back). Nothing else is touched.
    $mine = @{}
    foreach ($r in $v.Files) { $mine[$r.ToLowerInvariant()] = $true }
    $removed = 0
    foreach ($o in $versions) {
        if ($o.Name -eq $v.Name) { continue }
        foreach ($r in $o.Files) {
            if ($mine.ContainsKey($r.ToLowerInvariant())) { continue }
            $t = Join-Path $mm $r
            if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Force; $removed++ }
        }
    }
    if ($removed) { & $say "  took out $removed file(s) that only the other version uses" }

    # 4. tell the scripts where THIS game's ModMenu folder is
    $pointed = 0
    foreach ($r in $v.Files) {
        if (-not $r.EndsWith('.lua', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $src = Join-Path $v.Dir $r
        $want = Get-WantedBytes $src $r $win64
        if ($want.Length -eq (Get-Item -LiteralPath $src).Length -and
            (Get-BytesHash $want) -eq (Get-BytesHash ([System.IO.File]::ReadAllBytes($src)))) { continue }
        [System.IO.File]::WriteAllBytes((Join-Path $mm $r), $want)
        $pointed++
    }
    if ($pointed) { & $say "  pointed $pointed script(s) at your game folder" }

    Enable-ModMenu $win64

    # 5. prove it
    $bad = @()
    foreach ($r in $v.Files) {
        if (-not (Test-Installed (Join-Path $v.Dir $r) $r (Join-Path $mm $r) $win64)) { $bad += $r }
    }
    if ($bad.Count) {
        throw ("These files did not copy correctly: " + ($bad -join ', ') +
               ". Your previous version is saved in Switcher files\Backups.")
    }
    & $say "Checked all $($v.Files.Count) files - every one matches."

    $changed = @()
    foreach ($n in $before.Keys) {
        $p = Join-Path $mm $n
        if (-not (Test-Path -LiteralPath $p) -or (Get-FileHash -LiteralPath $p).Hash -ne $before[$n]) { $changed += $n }
    }
    if ($changed.Count) {
        & $say ("WARNING: these of your own files changed: " + ($changed -join ', '))
    } elseif ($before.Count) {
        & $say "Your settings, profiles and music list were kept ($($before.Count) files untouched)."
    }
    & $say "DONE - you now have $($v.Name)."
}

function Add-DesktopShortcut([string]$win64) {
    $exe = Join-Path $win64 "Mods\ModMenu\$AppName.exe"
    if (-not (Test-Path -LiteralPath $exe)) { return $false }
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "$AppName.lnk"
    if (Test-Path -LiteralPath $lnk) { return $false }
    $sh = New-Object -ComObject WScript.Shell
    $s = $sh.CreateShortcut($lnk)
    $s.TargetPath = $exe
    $s.WorkingDirectory = Split-Path $exe -Parent
    $s.Description = 'Blood Trail Mod Menu - the desktop control panel'
    $s.Save()
    return $true
}

if ($Check) {
    $versions = Get-VersionList
    $win64 = Find-Game
    "versions: " + (($versions | ForEach-Object { "$($_.Name) ($($_.Files.Count) files)" }) -join ', ')
    if ($win64) {
        "game:     $win64"
        "you have: $(Get-InstalledVersion $win64 $versions)"
    } else {
        'game:     not found'
    }
    exit 0
}

# ---------------------------------------------------------------------------
# INSTALL - Double-Click Me.bat
# ---------------------------------------------------------------------------
if ($Install) {
    $versions = Get-VersionList
    $v = $versions[0]
    if ($Version) { $v = $versions | Where-Object { $_.Name -eq $Version } | Select-Object -First 1 }
    if (-not $v) { Write-Host "  No version called '$Version' in the Versions folder."; exit 1 }

    Write-Host ''
    Write-Host '  ======================================================='
    Write-Host "    BLOOD TRAIL MOD MENU  -  INSTALL $($v.Name)"
    Write-Host '  ======================================================='
    Write-Host ''
    $win64 = Find-Game
    if (-not $win64) {
        Write-Host '  Could not find Blood Trail by itself.'
        Write-Host '  A window is opening - show me your Blood Trail folder.'
        $win64 = Select-GameFolder
    }
    if (-not $win64) {
        Write-Host ''
        Write-Host '  No Blood Trail folder was picked, so nothing was changed.'
        exit 1
    }
    try {
        Install-ModVersion $v $win64 $versions { param($m) Write-Host "  $m" }
        if (-not $NoShortcut) {
            if (Add-DesktopShortcut $win64) { Write-Host "  Put a '$AppName' shortcut on your desktop." }
        }
    } catch {
        Write-Host ''
        Write-Host "  STOPPED: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    Write-Host ''
    Write-Host '  Start Blood Trail and press B in the headset (or Insert on the'
    Write-Host '  keyboard) to open the menu.'
    Write-Host ''
    Write-Host '  Want a different version later? Double-click'
    Write-Host '  "VERSION SWITCHER - Double-Click Me.bat".'
    exit 0
}

# ---------------------------------------------------------------------------
# VERSION SWITCHER - Double-Click Me.bat: the window
# ---------------------------------------------------------------------------
function Show-Switcher {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $script:versions = Get-VersionList
    $script:win64 = Find-Game
    $script:buttons = @()

    $bg     = [System.Drawing.Color]::FromArgb(22, 22, 26)
    $card   = [System.Drawing.Color]::FromArgb(36, 36, 42)
    $red    = [System.Drawing.Color]::FromArgb(200, 30, 40)
    $green  = [System.Drawing.Color]::FromArgb(90, 210, 120)
    $grey   = [System.Drawing.Color]::FromArgb(170, 170, 178)
    $white  = [System.Drawing.Color]::White
    $W = 600

    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Blood Trail Mod Menu - Version Switcher'
    $f.StartPosition = 'CenterScreen'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.BackColor = $bg
    $f.ForeColor = $white
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $script:form = $f

    function New-Label([string]$text, [int]$y, [int]$h, $color, $font) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text
        $l.Location = New-Object System.Drawing.Point(20, $y)
        $l.Size = New-Object System.Drawing.Size($W, $h)
        $l.ForeColor = $color
        if ($font) { $l.Font = $font }
        $f.Controls.Add($l)
        return $l
    }

    $y = 16
    [void](New-Label 'BLOOD TRAIL MOD MENU' $y 34 $red (New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)))
    $y += 36
    [void](New-Label 'Version Switcher - click the version you want. Your settings are kept, and the version you have now is saved first.' $y 40 $grey $null)
    $y += 48

    $script:gameLabel = New-Label '' $y 22 $grey $null
    $script:gameLabel.Size = New-Object System.Drawing.Size(470, 22)
    $script:gameLabel.AutoEllipsis = $true
    $script:red = $red
    $script:green = $green
    $find = New-Object System.Windows.Forms.Button
    $find.Text = 'Change...'
    $find.Location = New-Object System.Drawing.Point(500, ($y - 3))
    $find.Size = New-Object System.Drawing.Size(120, 28)
    $find.FlatStyle = 'Flat'
    $find.BackColor = $card
    $find.Add_Click({
        $w = Select-GameFolder
        if ($w) { $script:win64 = $w } elseif ($script:win64 -eq $null) {
            [void][System.Windows.Forms.MessageBox]::Show($script:form,
                'That folder does not have Blood Trail in it (looking for BTVR-Win64-Shipping.exe).',
                'Version Switcher', 'OK', 'Warning')
        }
        Update-Switcher
    })
    $f.Controls.Add($find)
    $script:findButton = $find
    $y += 30

    $script:haveLabel = New-Label '' $y 30 $green (New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold))
    $y += 40

    foreach ($v in $script:versions) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = "Use  $($v.Name)"
        $b.Tag = $v.Name
        $b.Location = New-Object System.Drawing.Point(20, $y)
        $b.Size = New-Object System.Drawing.Size($W, 46)
        $b.FlatStyle = 'Flat'
        $b.FlatAppearance.BorderColor = $red
        $b.BackColor = $card
        $b.ForeColor = $white
        $b.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
        $b.Add_Click({ Invoke-Switch $this.Tag })
        $f.Controls.Add($b)
        $script:buttons += $b
        $y += 50
        [void](New-Label $v.About $y 40 $grey $null)
        $y += 46
    }

    $script:log = New-Object System.Windows.Forms.TextBox
    $script:log.Multiline = $true
    $script:log.ReadOnly = $true
    $script:log.ScrollBars = 'Vertical'
    $script:log.BackColor = [System.Drawing.Color]::FromArgb(12, 12, 14)
    $script:log.ForeColor = $grey
    $script:log.BorderStyle = 'FixedSingle'
    $script:log.Font = New-Object System.Drawing.Font('Consolas', 9)
    $script:log.Location = New-Object System.Drawing.Point(20, $y)
    $script:log.Size = New-Object System.Drawing.Size($W, 130)
    $f.Controls.Add($script:log)
    $y += 142

    $open = New-Object System.Windows.Forms.Button
    $open.Text = 'Open saved copies'
    $open.Location = New-Object System.Drawing.Point(20, $y)
    $open.Size = New-Object System.Drawing.Size(170, 32)
    $open.FlatStyle = 'Flat'
    $open.BackColor = $card
    $open.Add_Click({
        New-Item -ItemType Directory -Force $Backups | Out-Null
        Start-Process explorer.exe -ArgumentList "`"$Backups`""
    })
    $f.Controls.Add($open)

    $close = New-Object System.Windows.Forms.Button
    $close.Text = 'Close'
    $close.Location = New-Object System.Drawing.Point(($W - 100), $y)
    $close.Size = New-Object System.Drawing.Size(120, 32)
    $close.FlatStyle = 'Flat'
    $close.BackColor = $card
    $close.Add_Click({ $script:form.Close() })
    $f.Controls.Add($close)
    $f.CancelButton = $close
    $y += 48

    $f.ClientSize = New-Object System.Drawing.Size(($W + 40), $y)
    Update-Switcher
    if (-not $script:win64) {
        Write-Log 'Could not find Blood Trail by itself. Click "Find my game..." and show me your Blood Trail folder.'
    }
    if ($env:BTMM_SNAPSHOT) {
        # for checking the layout: draw the window to a picture and stop
        $f.Show()
        [System.Windows.Forms.Application]::DoEvents()
        $bmp = New-Object System.Drawing.Bitmap($f.Width, $f.Height)
        $f.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $f.Width, $f.Height)))
        $bmp.Save($env:BTMM_SNAPSHOT)
        $f.Close()
        return
    }
    [void]$f.ShowDialog()
}

function Write-Log([string]$m) {
    $script:log.AppendText($m + [Environment]::NewLine)
    [System.Windows.Forms.Application]::DoEvents()
}

function Update-Switcher {
    if ($script:win64) {
        $script:gameLabel.Text = 'Game:  ' + (Get-GameRoot $script:win64)
        $script:findButton.Text = 'Change...'
        $have = Get-InstalledVersion $script:win64 $script:versions
        switch ($have) {
            'none'  { $script:haveLabel.Text = 'You have:  no Mod Menu yet' }
            'other' { $script:haveLabel.Text = 'You have:  a version that is not in this pack' }
            default { $script:haveLabel.Text = "You have:  $have" }
        }
    } else {
        $script:gameLabel.Text = 'Game:  not found yet'
        $script:findButton.Text = 'Find my game...'
        $script:haveLabel.Text = ''
        $have = ''
    }
    foreach ($b in $script:buttons) {
        $b.Enabled = [bool]$script:win64
        if ($b.Tag -eq $have) {
            $b.Text = "$($b.Tag)   -   you have this one"
            $b.FlatAppearance.BorderColor = $script:green
        } else {
            $b.Text = "Use  $($b.Tag)"
            $b.FlatAppearance.BorderColor = $script:red
        }
    }
}

function Invoke-Switch([string]$name) {
    $v = $script:versions | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    $have = Get-InstalledVersion $script:win64 $script:versions
    $q = if ($have -eq $name) {
        "You already have $name.`n`nPut it in again? (This repairs it - your settings are kept.)"
    } else {
        "Switch to ${name}?`n`nYour settings are kept, and the version you have now is saved first."
    }
    $ans = [System.Windows.Forms.MessageBox]::Show($script:form, $q, 'Version Switcher', 'YesNo', 'Question')
    if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    foreach ($b in $script:buttons) { $b.Enabled = $false }
    $script:form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $script:log.Clear()
    try {
        Install-ModVersion $v $script:win64 $script:versions { param($m) Write-Log $m }
        $script:form.Cursor = [System.Windows.Forms.Cursors]::Default
        [void][System.Windows.Forms.MessageBox]::Show($script:form,
            "Done! You now have $name.`n`nStart Blood Trail to play.", 'Version Switcher', 'OK', 'Information')
    } catch {
        $script:form.Cursor = [System.Windows.Forms.Cursors]::Default
        Write-Log ('STOPPED: ' + $_.Exception.Message)
        [void][System.Windows.Forms.MessageBox]::Show($script:form, $_.Exception.Message,
            'Version Switcher - nothing more was changed', 'OK', 'Warning')
    }
    Update-Switcher
}

try {
    Show-Switcher
} catch {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show("The Version Switcher hit a problem:`n`n$($_.Exception.Message)",
        'Version Switcher', 'OK', 'Error')
    exit 1
}
