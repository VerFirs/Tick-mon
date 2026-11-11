<#
    Quick Tickets (quicktickets.ru) ticket availability monitor.

    Polls event pages, detects when sold-out sessions get tickets again
    (or when new sessions go on sale) and sends Telegram notifications.

    Usage:
      powershell -ExecutionPolicy Bypass -File monitor.ps1                  - monitoring loop
      powershell -ExecutionPolicy Bypass -File monitor.ps1 -Once            - single check (Task Scheduler)
      powershell -ExecutionPolicy Bypass -File monitor.ps1 -TestNotification - send test message

    No external dependencies: Windows 10/11 built-in PowerShell 5.1 + curl.exe.
#>

param(
    [switch]$Once,
    [switch]$TestNotification
)

$ErrorActionPreference = 'Stop'

$Root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$StatePath  = Join-Path $Root 'state.json'

# PowerShell 5.1 may default to TLS 1.0 - force TLS 1.2
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$Script:UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'

# ------------------------------------------------------------- helpers ----

function Read-Config {
    if (-not (Test-Path $ConfigPath)) { throw "config.json not found next to monitor.ps1" }
    $cfg = Get-Content -Raw -Encoding UTF8 $ConfigPath | ConvertFrom-Json

    # overrides via environment variables (used by GitHub Actions - keeps
    # the bot token out of the repository files)
    if ($env:QT_BOT_TOKEN) { $cfg.bot_token = $env:QT_BOT_TOKEN }
    if ($env:QT_CHAT_ID)   { $cfg.chat_id   = $env:QT_CHAT_ID }

    return $cfg
}

function Save-ConfigValue([string]$Name, $Value) {
    # rewrite one top-level scalar value in config.json, keep the rest as-is
    $raw  = Get-Content -Raw -Encoding UTF8 $ConfigPath
    $pat  = '("' + [regex]::Escape($Name) + '"\s*:\s*)("[^"]*"|[0-9]+|true|false|null)'
    $new  = [regex]::Replace($raw, $pat, ('${1}' + $Value))
    [System.IO.File]::WriteAllText($ConfigPath, $new, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-State {
    if (Test-Path $StatePath) {
        try { return (Get-Content -Raw -Encoding UTF8 $StatePath | ConvertFrom-Json) }
        catch { Write-Warning 'state.json corrupted, starting with empty state'; return $null }
    }
    return $null
}

function Save-State($State) {
    $json = $State | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($StatePath, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Fetch-Page([string]$Url, [string]$Proxy) {
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        # curl.exe on Windows, curl on Linux/macOS (GitHub Actions runners)
        $curlCmd = 'curl.exe'
        if ($IsLinux -or $IsMacOS) { $curlCmd = 'curl' }

        $curlArgs = @('-s', '-L', '--max-time', '60', '-A', $Script:UserAgent)
        if ($Proxy) { $curlArgs += @('-x', $Proxy) }
        $curlArgs += @($Url, '-o', $tmp)
        & $curlCmd @curlArgs | Out-Null
        if (-not (Test-Path $tmp) -or (Get-Item $tmp).Length -eq 0) { return $null }
        return [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8)
    }
    catch { return $null }
    finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}

function Decode-Html([string]$s) {
    $s = $s -replace '&quot;', '"'
    $s = $s -replace '&amp;',  '&'
    $s = $s -replace '&nbsp;', ' '
    $s = $s -replace '&#39;',  "'"
    return $s
}

function Get-EventInfo([string]$Html) {
    $title = ''
    $tm = [regex]::Match($Html, '(?s)<title>(.{0,400}?)</title>')
    if ($tm.Success) {
        $title = [regex]::Replace($tm.Groups[1].Value, '\s*[-\u2014]\s*Quick Tickets\s*$', '')
        $title = (Decode-Html $title).Trim()
    }

    $sessions = New-Object System.Collections.Generic.List[object]
    $ms = [regex]::Matches($Html,
        '(?s)class="quick-tickets-session-option([^"]*)"[^>]*>.*?href="(/[^"]+/s\d+)".*?quick-tickets-session-option__label">([^<]+)<')
    foreach ($m in $ms) {
        $sessions.Add([pscustomobject]@{
            Url   = $m.Groups[2].Value
            Label = (Decode-Html $m.Groups[3].Value).Trim()
            Sold  = ($m.Groups[1].Value -match 'sold')
        })
    }
    return [pscustomobject]@{ Title = $title; Sessions = $sessions }
}


# ----------------------------------------------------------- telegram ----

function Send-Telegram($Config, [string]$Text) {
    if (-not $Config.bot_token) { Write-Warning 'bot_token is not set in config.json'; return $false }
    if (-not $Config.chat_id)   { Write-Warning 'chat_id is not set (send /start to your bot, then rerun)'; return $false }

    $uri  = 'https://api.telegram.org/bot' + $Config.bot_token + '/sendMessage'
    $body = @{ chat_id = $Config.chat_id; text = $Text; disable_web_page_preview = 'true' }
    try {
        $p = @{ Uri = $uri; Method = 'Post'; Body = $body; TimeoutSec = 30 }
        if ($Config.proxy_url) { $p.Proxy = $Config.proxy_url }
        Invoke-RestMethod @p | Out-Null
        return $true
    }
    catch {
        Write-Warning ('Telegram send failed: ' + $_.Exception.Message)
        return $false
    }
}

function Update-ChatId($Config) {
    # auto-detect chat_id from the latest message the bot has received
    if ($Config.chat_id -or -not $Config.bot_token) { return $Config }
    try {
        $p = @{ Uri = ('https://api.telegram.org/bot' + $Config.bot_token + '/getUpdates'); TimeoutSec = 30 }
        if ($Config.proxy_url) { $p.Proxy = $Config.proxy_url }
        $resp = Invoke-RestMethod @p
        $msgs = @($resp.result | Where-Object { $_.message -and $_.message.chat })
        if ($msgs.Count -gt 0) {
            $chatId = [string]$msgs[-1].message.chat.id
            Write-Host ('Auto-detected chat_id: ' + $chatId + ' (saved to config.json)')
            Save-ConfigValue 'chat_id' $chatId
            $Config.chat_id = $chatId
        }
        else { Write-Warning 'No messages received by the bot yet - send /start to it in Telegram.' }
    }
    catch { Write-Warning ('getUpdates failed: ' + $_.Exception.Message) }
    return $Config
}

function Get-Template($Config, [string]$Name, [string]$Fallback) {
    if ($Config.templates -and $Config.templates.PSObject.Properties[$Name]) {
        return [string]$Config.templates.$Name
    }
    return $Fallback
}

function Format-Message([string]$Template, [string]$EventTitle, [string]$SessionLabel, [string]$Link) {
    return $Template.Replace('{event}', $EventTitle).Replace('{session}', $SessionLabel).Replace('{link}', $Link)
}


# -------------------------------------------------------------- check ----

function Invoke-Check($Config) {
    $state    = Read-State
    $firstRun = ($null -eq $state)
    $newState = @{}

    $tplAvailable  = Get-Template $Config 'available'  'Tickets available again: {event} / {session} / {link}'
    $tplNewSession = Get-Template $Config 'new_session' 'New session on sale: {event} / {session} / {link}'
    $tplSoldOut    = Get-Template $Config 'sold_out'    'Sold out: {event} / {session}'

    foreach ($ev in @($Config.events)) {
        $url = [string]$ev
        Write-Host ('[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $url)

        $html = Fetch-Page $url $Config.proxy_url
        if (-not $html) {
            Write-Warning '  fetch failed - keeping previous state'
            $prop = $state.PSObject.Properties[$url]
            if ($state -and $prop) { $newState[$url] = $prop.Value }
            continue
        }

        $info = Get-EventInfo $html
        if ($info.Sessions.Count -eq 0) {
            Write-Warning '  no sessions found (event may be in the past or sales not started)'
        }

        # map of previously known sessions: url -> sold(bool)
        $prevMap = @{}
        if (-not $firstRun -and $state) {
            $evProp = $state.PSObject.Properties[$url]
            if ($evProp -and $evProp.Value.sessions) {
                $evProp.Value.sessions.PSObject.Properties |
                    ForEach-Object { $prevMap[$_.Name] = [bool]$_.Value.sold }
            }
        }

        $sessState = @{}
        foreach ($s in $info.Sessions) {
            $link = 'https://quicktickets.ru' + $s.Url

            if (-not $prevMap.ContainsKey($s.Url)) {
                # session unknown so far
                if ((-not $firstRun -or $Config.notify_first_run) -and -not $s.Sold) {
                    $msg = Format-Message $tplNewSession $info.Title $s.Label $link
                    [void](Send-Telegram $Config $msg)
                    Write-Host ('  NEW SESSION ON SALE: ' + $s.Label)
                }
            }
            elseif ($prevMap[$s.Url] -and -not $s.Sold) {
                # SOLD -> AVAILABLE : tickets returned / released
                $msg = Format-Message $tplAvailable $info.Title $s.Label $link
                [void](Send-Telegram $Config $msg)
                Write-Host ('  TICKETS AVAILABLE AGAIN: ' + $s.Label)
            }
            elseif (-not $prevMap[$s.Url] -and $s.Sold) {
                if ($Config.notify_sold_out) {
                    $msg = Format-Message $tplSoldOut $info.Title $s.Label $link
                    [void](Send-Telegram $Config $msg)
                }
                Write-Host ('  sold out: ' + $s.Label)
            }

            $sessState[$s.Url] = @{ label = $s.Label; sold = $s.Sold }
        }

        $soldCount = @($info.Sessions | Where-Object { $_.Sold }).Count
        Write-Host ('  sessions: ' + $info.Sessions.Count + ' (sold out: ' + $soldCount + ')')

        $newState[$url] = @{
            title    = $info.Title
            sessions = $sessState
            checked  = (Get-Date).ToString('s')
        }
    }

    Save-State $newState
    if ($firstRun) {
        Write-Host 'First run: baseline saved to state.json (no notifications sent).'
    }
}

# --------------------------------------------------------------- main ----

$Config = Read-Config

if ($TestNotification) {
    $Config = Update-ChatId $Config
    $ok = [char]::ConvertFromUtf32(0x2705)
    if (Send-Telegram $Config ('Test message from Quick Tickets monitor ' + $ok)) {
        Write-Host 'Test message sent successfully.'
    }
    exit
}

if ($Once) { Write-Host 'Single check mode.' }
else       { Write-Host ('Monitoring loop: interval ' + $Config.interval_minutes + ' min. Press Ctrl+C to stop.') }
Write-Host ('Events monitored: ' + @($Config.events).Count)

while ($true) {
    $Config = Update-ChatId $Config
    Invoke-Check $Config
    if ($Once) { break }
    Start-Sleep -Seconds ([int]($Config.interval_minutes) * 60)
}

Write-Host 'Done.'
