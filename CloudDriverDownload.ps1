# Load OSD Module
Import-Module OSD

# Configuration
$SmbRepoPath = "\\psd.gslinet.com\psdeploymentshare\PSDResources\DriverPackages"
$DriverDir = "S:\Drivers"
$Product = Get-MyComputerProduct

# Create driver directory
New-Item -Path $DriverDir -ItemType Directory -Force | Out-Null

# Get TS Environment
$TSEnv = New-Object -ComObject Microsoft.SMS.TSEnvironment

# Validate credentials exist
if (-not $TSEnv.Value('DomainAdmin') -or 
    -not $TSEnv.Value('DomainAdminDomain') -or 
    -not $TSEnv.Value('DomainAdminPassword')) {
    throw "Missing DomainAdmin credentials in task sequence variables"
}

# Build credentials
$Username = "$($TSEnv.Value('DomainAdminDomain'))\$($TSEnv.Value('DomainAdmin'))"
$Password = $TSEnv.Value('DomainAdminPassword')
Write-Host "Using credentials for: $Username"  # Debug output

# Create secure password (with validation)
if ([string]::IsNullOrEmpty($Password)) {
    throw "DomainAdminPassword is empty"
}
$SecurePassword = ConvertTo-SecureString $Password -AsPlainText -Force
$Cred = New-Object System.Management.Automation.PSCredential($Username, $SecurePassword)

# Get driver package information
$DriverPack = Get-OSDCloudDriverPack -Product $Product
if (-not $DriverPack) {
    Write-Warning "No driver pack found for $Product"
    exit 0
}

# Extract filename from URL
$FileName = $DriverPack.Url.Split('/')[-1]
$RepoFilePath = Join-Path -Path $SmbRepoPath -ChildPath $FileName
$LocalPath = Join-Path -Path $DriverDir -ChildPath $FileName

# Check repository first
try {
    # Map network drive with corrected drive letter syntax
    $DriveLetter = "Z"  # Without colon for PSDrive name
    Write-Host "Mapping $DriveLetter`: to $SmbRepoPath"
    
    $MappedDrive = New-PSDrive -Name $DriveLetter `
        -PSProvider FileSystem `
        -Root $SmbRepoPath `
        -Credential $Cred `
        -ErrorAction Stop

    # Check if file exists in repo
    $RepoFullPath = Join-Path -Path "$($DriveLetter):" -ChildPath $FileName
    if (Test-Path -Path $RepoFullPath) {
        Write-Host "Found package in repository: $RepoFullPath"
        Copy-Item -Path $RepoFullPath -Destination $LocalPath -Force
        Write-Host "Copied from repository: $LocalPath"
    }
    else {
        # Download from internet
        Write-Host "Package not found in repository, downloading from internet..."
        Invoke-WebRequest -Uri $DriverPack.Url -OutFile $LocalPath -UseBasicParsing
        
        # Upload to repository
        Write-Host "Uploading to repository..."
        Copy-Item -Path $LocalPath -Destination $RepoFullPath -Force
        
        # Verify upload
        if (Test-Path -Path $RepoFullPath) {
            Write-Host "Successfully uploaded to repository"
        }
        else {
            Write-Warning "Upload verification failed"
        }
    }
}
catch {
    Write-Error "Repository operation failed: $_"
    exit 1
}
finally {
    # Cleanup network drive if it exists
    if (Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue) {
        Remove-PSDrive -Name $DriveLetter -Force
        Write-Host "Disconnected from repository"
    }
}

# Set MDT driver path
$TSEnv.Value("OSDDriverPath") = $DriverDir
Write-Host "Driver package ready at: $LocalPath"
