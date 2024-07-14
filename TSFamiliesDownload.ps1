[CmdletBinding()]
param (
    [Parameter()]
    [string]
    $earliestDate,

    [Parameter()]
    [string]
    $latestDate
)

if ($earliestDate -ne "") {
    try {
        $earliestDate = [DateTime]::Parse($earliestDate).Date
    } catch {
        Write-Host "Invalid date format. Please use a format like '2021-01-01'"
        return
    }
}
if ($latestDate -ne "") {
    try {
        $latestDate = [DateTime]::Parse($latestDate).Date.AddDays(1).AddSeconds(-1)
    } catch {
        Write-Host "Invalid date format. Please use a format like '2021-01-01'"
        return
    }
} else {
    $latestDate = [DateTime]::Now
}

$userName = Read-Host -Prompt "Tadpoles username"
$password = Read-Host -Prompt "Tadpoles password" -AsSecureString

$eventRangeInDays = 30

# Get the local time zone UTC offset, formatted as a string, e.g., +02:00 or -07:00, and URI-escaped
$localTimeZone = [System.TimeZoneInfo]::Local
$utcOffset = $localTimeZone.BaseUtcOffset
$utcOffsetString = [uri]::EscapeDataString([string]::Format("{0}{1:D2}:{2:D2}", $(if($utcOffset.Hours -ge 0) {"+"} else {"-"}), [Math]::Abs($utcOffset.Hours), $utcOffset.Minutes))
$usesDst = if ($localTimeZone.SupportsDaylightSavingTime) {1} else {0}

$tadpolesApi = "https://www.tadpoles.com/remote/v1"
$authBody = "email=" + [uri]::EscapeDataString($userName) + "&service=tadpoles&password=" + [uri]::EscapeDataString([Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)))

# Known issue: $admitBody must specify `&tz=<time zone>`, but I don't have a good way to get the string format necessary from the local time zone.
# So &tz=America%2FLos_Angeles is hard-coded for now.
$admitBody = "state=client&tz=America%2FLos_Angeles&battery_level=-1&locale=en-US&platform_version=17.5.1&logged_in=1&uses_dst=$usesDst&utc_offset=$utcOffsetString&v=2"

$ProgressPreference = 'SilentlyContinue'

# Log in to tadpoles
try {
    $resp = Invoke-WebRequest -Method Post -Uri https://www.tadpoles.com/auth/login -Body $authBody -SessionVariable webSession 
    $resp = Invoke-WebRequest -Method Post -Uri $($tadpolesApi + "/athome/admit") -Body $admitBody -WebSession $webSession
}
catch {
    Write-Host "Failed to log in. Please check your username and password."
    return
}

Write-Host "Logged in to tadpoles.com as $userName"

# Get dependants
$resp = Invoke-WebRequest -Method Get -Uri $($tadpolesApi + "/parameters?include_all_kids=true") -WebSession $webSession

$dependants = @{}
($resp.Content | ConvertFrom-Json).memberships[0].dependants.GetEnumerator() | ForEach-Object {
    $dependants[$_.key] = @{
        name = $_.display_name
        firstName = $_.first_name
        enrolled = Get-Date $_.ed
        hasImage = $_.has_image
        image = $_.image_attachment
    }
}

$earliestEnrolledDate = Get-Date

Write-Host "Dependants:"
$dependants.GetEnumerator() | ForEach-Object {
    Write-Host "    $($_.Value.name) (enrolled $($_.Value.enrolled.ToShortDateString()))"

    if ($_.Value.hasImage) {
        Invoke-WebRequest -Method Get -Uri $($tadpolesApi + "/attachment?thumbnail=false&key=$($_.Value.image)") -WebSession $webSession -OutFile "$($_.Value.name) Profile Pic.jpg"
    }

    if (-not (Test-Path $_.Value.name)) {
        New-Item -Path $_.Value.name -ItemType Directory > $null
    }

    if ($_.Value.enrolled -lt $earliestEnrolledDate) {
        $earliestEnrolledDate = $_.Value.enrolled
    }
}

$date = [DateTime]$latestDate

if ($earliestDate -eq "") {
    $earliestDate = [DateTime]$earliestEnrolledDate
}

Write-Host "Finding events"

$imageKeys = @()

$imagesPerDate = @{}
$imageCountPerDate = @{}

$continuationToken = $null
while ($date -ge $earliestDate) {
    $eventCount = 0

    $earliestRequestDate = ([DateTimeOffset]$date.AddDays(-$eventRangeInDays))
    $latestRequestDate = ([DateTimeOffset]$date)

    Write-Host "   $($earliestRequestDate.ToString("d")) - $($latestRequestDate.ToString("d"))"

    do {
        $queryParams = "num_events=100&state=client&direction=range&earliest_event_time=$($earliestRequestDate.ToUnixTimeSeconds())&latest_event_time=$($latestRequestDate.ToUnixTimeSeconds())"

        if ($null -ne $continuationToken) {
            $queryParams += "&cursor=$continuationToken"
        }

        $resp = Invoke-WebRequest -Method Get -Uri $($tadpolesApi + "/events?$queryParams") -WebSession $webSession

        $events = $resp.Content | ConvertFrom-Json

        $continuationToken = $events.cursor

        $events.events | Where-Object { "Activity" -eq $_.type } | ForEach-Object {
            $attachments = $_.new_attachments
            $member = $_.member
            
            if (-not $imagesPerDate.ContainsKey($_.event_date)) {
                $imagesPerDate[$_.event_date] = @()
                $imageCountPerDate[$_.event_date] = 0
            }

            $eventDate = $_.event_date
            $attachments | ForEach-Object {
                $imagesPerDate[$eventDate] += @{
                    key = $_.key
                    member = $member
                }

                $imageCountPerDate[$eventDate] = $imageCountPerDate[$eventDate] + 1

                $imageKeys += @{
                    key = $_.key
                    childName = $dependants[$member].name
                    uri = $tadpolesApi + "/attachment?thumbnail=false&key=$($_.key)"
                    imageName = "$eventDate ($($imageCountPerDate[$eventDate])).jpg"
                }
            }

            $eventCount++
        }
    } while ($null -ne $continuationToken)

    $date = $date.AddDays(-$eventRangeInDays)
}

$totalImages = $imageKeys.Count
Write-Host "Downloading $totalImages images"

# Downloads images in parallel if supported
if ($PSVersionTable.PSVersion.Major -ge 7) {
    # Set up synced hashtable to track parallel image download progress
    $completedImages = @{}
    $imageKeys | ForEach-Object {
        $completedImages[$_.key] = $false
    }
    $sync = [System.Collections.Hashtable]::Synchronized($completedImages)

    $downloadJob = $imageKeys | ForEach-Object -ThrottleLimit 5 -AsJob -Parallel {
        $syncCopy = $using:sync
        $resp = Invoke-WebRequest -Method Get -Uri $_.uri -WebSession $using:webSession -OutFile "$($_.childName)\$($_.imageName)"

        $syncCopy[$_.key] = $true
    }

    while ($downloadJob.State -ne "Completed") {
        $progress = $sync.Values | Where-Object { $_ -eq $true } | Measure-Object | Select-Object -ExpandProperty Count

        $ProgressPreference = 'Continue'
        Write-Progress -Activity "Downloading Images" -Status "Progress: $progress/$totalImages" -PercentComplete (($progress / $totalImages) * 100)
        $ProgressPreference = 'SilentlyContinue'
        
        Start-Sleep -Seconds 1
    }
}
# Downloads images sequentially if parallel downloads are not supported
else {
    $progress = 0
    $imageKeys | ForEach-Object {
        $resp = Invoke-WebRequest -Method Get -Uri $_.uri -WebSession $webSession -OutFile "$($_.childName)\$($_.imageName)"
        $progress++

        $ProgressPreference = 'Continue'
        Write-Progress -Activity "Downloading Images" -Status "Progress: $progress/$totalImages" -PercentComplete (($progress / $totalImages) * 100)
        $ProgressPreference = 'SilentlyContinue'
    }
}

Write-Host "Download complete"
