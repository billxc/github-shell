# Script parameters
param(
    [Parameter(Mandatory=$true)]
    [string]$org,
    
    [Parameter(Mandatory=$true)]
    [string]$repo
)

# # Ensure uv is installed
# powershell -ExecutionPolicy ByPass -c "irm https://get.scoop.sh | iex"
# scoop install python uv

# GitHub CLI Client ID
$GH_CLI_CLIENT_ID = "178c6fc778ccc68e1d6a"

# Function to get GitHub token using Python keyring command-line tool
function Get-GitHubTokenFromKeyring {
    Write-Host "Attempting to read GitHub token from keyring using keyring CLI..." -ForegroundColor Yellow

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
                    Store-GitHubTokenInKeyring -token $tokenResponse.access_token
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

function Get-LatestRelease {
    param(
        [Parameter(Mandatory=$true)]
        [string]$GitHubToken,
        
        [Parameter(Mandatory=$true)]
        [string]$org,
        
        [Parameter(Mandatory=$true)]
        [string]$repo
    )

    $apiHeaders = @{
        'Accept' = 'application/vnd.github.v3+json'
        'User-Agent' = 'PowerShell/7.0'
        'Authorization' = "token $GitHubToken"
    }

    # Download the asset
    $downloadHeaders = @{
        'Accept' = 'application/octet-stream'
        'User-Agent' = 'PowerShell/7.0'
        'Authorization' = "token $GitHubToken"
    }

    try {
        # Get latest release information
        $response = Invoke-RestMethod -Uri "https://api.github.com/repos/$org/$repo/releases/latest" -Headers $apiHeaders
        
        Write-Host "Latest release: $($response.tag_name)" -ForegroundColor Green
        
        $assets = $response.assets
        if (-not $assets) {
            Write-Error "No assets found in the latest release."
            return $null
        }

        # Find .whl asset
        $whlAsset = $assets | Where-Object { $_.name.EndsWith('.whl') } | Select-Object -First 1
        
        if (-not $whlAsset) {
            Write-Error "No .whl asset found in the latest release."
            return $null
        }

        $assetName = $whlAsset.name
        $downloadUrl = $whlAsset.url
        
        Write-Host "Found asset: $assetName at $downloadUrl" -ForegroundColor Green

        # Create temporary directory for download
        $tempDir = [System.IO.Path]::GetTempPath()
        $tempFile = Join-Path $tempDir $assetName

        $downloadResponse = Invoke-WebRequest -Uri $downloadUrl -Headers $downloadHeaders -OutFile $tempFile
        Write-Host "Successfully downloaded $assetName to temp directory" -ForegroundColor Green

        return $tempFile
    }
    catch {
        Write-Error "Error fetching latest release: $($_.Exception.Message)"
        throw
    }
}

# Main execution
try {
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
    
    $downloadedFile = Get-LatestRelease -GitHubToken $token
    Write-Host "GitHub access token: $($token.Substring(0, [Math]::Min(10, $token.Length)))..." -ForegroundColor Green
    
    if ($downloadedFile) {
        Write-Host "Downloaded file: $(Split-Path $downloadedFile -Leaf)" -ForegroundColor Green
        # Install the downloaded package
        uv tool install $downloadedFile
        
        # Clean up temporary file
        try {
            Remove-Item $downloadedFile -Force
            Write-Host "Cleaned up temporary file" -ForegroundColor Green
        }
        catch {
            Write-Warning "Could not clean up temporary file: $downloadedFile"
        }
    }
}
catch {
    Write-Error "Failed to complete GitHub operations: $($_.Exception.Message)"
    exit 1
}