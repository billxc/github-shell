# Script parameters
param(
    [Parameter(Mandatory=$true)]
    [string]$org,
    
    [Parameter(Mandatory=$true)]
    [string]$repo,

    [Parameter(Mandatory=$true)]
    [string]$filePath,

    [Parameter(Mandatory=$false)]
    [string]$outputPath = $null,

    [Parameter(Mandatory=$false)]
    [string]$branch = "main"

)

# Load required assemblies
Add-Type -AssemblyName System.Web

# # Ensure uv is installed
# powershell -ExecutionPolicy ByPass -c "irm https://get.scoop.sh | iex"
# scoop install python uv

# GitHub CLI Client ID
$GH_CLI_CLIENT_ID = "178c6fc778ccc68e1d6a"

# Function to get GitHub token using Python keyring command-line tool
function Get-GitHubTokenFromKeyring {
    Write-Host "Attempting to read GitHub token from keyring using keyring CLI..." -ForegroundColor Yellow
    # check if keyring command-line tool is available
    if (-not (Get-Command keyring -ErrorAction SilentlyContinue)) {
        Write-Error "keyring command-line tool is not installed. Please install it to use this feature."
        return $null
    }
    # Use keyring command-line tool to get password
    $token = & keyring get $repo "gh_access_token" 2>$null
    if ($LASTEXITCODE -eq 0 -and $token -and $token.Trim() -ne "") {
        Write-Host "Successfully retrieved GitHub token from keyring (service: $repo, user: gh_access_token)" -ForegroundColor Green
        return $token.Trim()
    } else {
        Write-Host "No valid GitHub token found in keyring" -ForegroundColor Yellow
        return $null
    }
}

function Store-GitHubTokenInKeyring {
    param(
        [Parameter(Mandatory=$true)]
        [string]$token
    )

    Write-Host "Storing GitHub token in keyring..." -ForegroundColor Yellow
    
    # Use keyring command-line tool to set password
    cmdkey /generic:$repo /user:gh_access_token /pass:$token
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Successfully stored GitHub token in keyring" -ForegroundColor Green
    } else {
        Write-Error "Failed to store GitHub token in keyring"
    }
}

# GitHub Authentication configuration
$AUTH_HEADERS = @{
    'accept' = 'application/json'
    'content-type' = 'application/json'
}

function Get-GitHubToken {
    try {
        # Request device code
        $deviceCodeBody = @{
            client_id = $GH_CLI_CLIENT_ID
            scope = "repo"
        } | ConvertTo-Json

        $deviceCodeResponse = Invoke-RestMethod -Uri 'https://github.com/login/device/code' -Method Post -Headers $AUTH_HEADERS -Body $deviceCodeBody
        
        # Extract device_code, user_code, and verification_uri
        $deviceCode = $deviceCodeResponse.device_code
        $userCode = $deviceCodeResponse.user_code
        $verificationUri = $deviceCodeResponse.verification_uri

        # Display authentication instructions
        Write-Host "Please visit $verificationUri and enter code $userCode to authenticate." -ForegroundColor Yellow

        # Poll for access token
        while ($true) {
            Start-Sleep -Seconds 5
            
            $tokenBody = @{
                client_id = $GH_CLI_CLIENT_ID
                device_code = $deviceCode
                grant_type = "urn:ietf:params:oauth:grant-type:device_code"
            } | ConvertTo-Json

            try {
                $tokenResponse = Invoke-RestMethod -Uri 'https://github.com/login/oauth/access_token' -Method Post -Headers $AUTH_HEADERS -Body $tokenBody
                
                if ($tokenResponse.access_token) {
                    Write-Host "Successfully authenticated and received access token." -ForegroundColor Green
                    $ignore_output = Store-GitHubTokenInKeyring -token $tokenResponse.access_token
                    return $tokenResponse.access_token
                }
            }
            catch {
                # Continue polling if authorization is pending
                if ($_.Exception.Response.StatusCode -eq 400) {
                    continue
                }
                else {
                    throw
                }
            }
        }
    }
    catch {
        Write-Error "Error when getting GitHub token: $($_.Exception.Message)"
        throw
    }
}

function Download-RepoFile {
    param(
        [Parameter(Mandatory=$true)]
        [string]$GitHubToken,
        
        [Parameter(Mandatory=$true)]
        [string]$FilePath,
        
        [Parameter()]
        [string]$OutputPath = $null,
        
        [Parameter()]
        [string]$Branch = "master"
    )

    $apiHeaders = @{
        'Accept' = 'application/vnd.github.v3+json'
        'User-Agent' = 'PowerShell/7.0'
        'Authorization' = "token $GitHubToken"
    }

    try {
        Write-Host "Downloading file: $FilePath from branch: $Branch" -ForegroundColor Yellow
        
        # Get file content from GitHub API
        $encodedFilePath = [System.Web.HttpUtility]::UrlEncode($FilePath)
        $apiUrl = "https://api.github.com/repos/$org/$repo/contents/$encodedFilePath"
        
        # Add branch parameter if specified
        if ($Branch -ne "main") {
            $apiUrl += "?ref=$Branch"
        }
        
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $apiHeaders
        
        if ($response.type -ne "file") {
            Write-Error "The specified path is not a file: $FilePath"
            return $null
        }
        
        # GitHub API returns file content in base64 encoding for several reasons:
        # 1. Handle binary files (images, executables, etc.) in JSON format
        # 2. Avoid character encoding issues with different text files
        # 3. Provide consistent data format regardless of file type
        # 4. Ensure JSON compatibility and safe transmission
        Write-Host "File encoding: $($response.encoding)" -ForegroundColor Cyan
        
        # Decode base64 content
        $fileContent = [System.Convert]::FromBase64String($response.content)
        
        # Determine output path
        if (-not $OutputPath) {
            $fileName = Split-Path $FilePath -Leaf
            $OutputPath = Join-Path (Get-Location) $fileName
        }
        
        # Create directory if it doesn't exist
        $outputDir = Split-Path $OutputPath -Parent
        if ($outputDir -and -not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        }
        
        # Write file content
        [System.IO.File]::WriteAllBytes($OutputPath, $fileContent)
        
        Write-Host "Successfully downloaded $FilePath to $OutputPath" -ForegroundColor Green
        Write-Host "File size: $($response.size) bytes" -ForegroundColor Green
        
        return $OutputPath
    }
    catch {
        if ($_.Exception.Response.StatusCode -eq 404) {
            Write-Error "File not found: $FilePath (make sure the file exists and the branch is correct)"
        } else {
            Write-Error "Error downloading file: $($_.Exception.Message)"
        }
        throw
    }
}


# Main execution
# Check for environment variable first
$envToken = $env:GH_CLI_TOKEN
if ($envToken) {
    Write-Host "Using GitHub token from environment variable GH_CLI_TOKEN" -ForegroundColor Green
    $token = $envToken
} else {
    # Try to read from keyring using Python keyring library
    Write-Host "Environment variable GH_CLI_TOKEN not found, attempting to read from keyring..." -ForegroundColor Yellow
    $token = Get-GitHubTokenFromKeyring
    
    if (-not $token) {
        Write-Host "No GitHub token found in keyring, requesting new token..." -ForegroundColor Yellow
        $token = Get-GitHubToken
    }
}


# Usage examples:
# To download a specific file from the repository:
$downloadedFile = Download-RepoFile -GitHubToken $token -FilePath $filePath -OutputPath $outputPath -Branch $branch
