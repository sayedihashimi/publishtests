<#
.SYNOPSIS
  This will print out some diagnostic info regarding publish times.

  # 1. Average publish time for a default VS project
  # 2. Average publish time for a default VS project
  #     w/o publishing the runtime & packages folder
  # 3. Average publish time for a default VS project
  #     and publishing only needed files (i.e. don't
  #     publish files under wwwroot that are not needed)
  # 4. Average publish time for a default VS project
  #     w/o publishing the runtime & packages folder and
  #     and publishing only needed files (i.e. don't
  #     publish files under wwwroot that are not needed)
  # 5. Average publish time for a VS project
  #     w/o publishing source and
  #     w/o publishing the runtime & packages folder and
  #     and publishing only needed files (i.e. don't
  #     publish files under wwwroot that are not needed)
#>
[cmdletbinding()]
param()

function InternalGet-ScriptDirectory{
    split-path (((Get-Variable MyInvocation -Scope 1).Value).MyCommand.Path)
}
$scriptDir = ((InternalGet-ScriptDirectory) + "\")

$global:publishsettings = New-Object -TypeName psobject -Property @{
    MinGeoffreyModuleVersion = '0.0.10.1'
    PubSamplesRoot = [System.IO.DirectoryInfo](Join-Path $scriptDir 'publish-samples')
    NumIterations = 10
    AzureSiteName = 'sayedpubdemo01'
}

function Ensure-GeoffreyLoaded{
    [cmdletbinding()]
    param(
        [string]$minGeoffreyModuleVersion = $global:publishsettings.MinGeoffreyModuleVersion
    )
    process{
        # see if nuget-powershell is available and load if not
        $geoffreyloaded = $false
        if((get-command Invoke-Geoffrey -ErrorAction SilentlyContinue)){
            if($env:GeoffreySkipReload -eq $true){
                $geoffreyloaded = $true
            }
            else{
                # check the module to ensure we have the correct version
                $currentversion = (Get-Module -Name geoffrey).Version
                if( ($currentversion -ne $null) -and ($currentversion.CompareTo([version]::Parse($minGeoffreyModuleVersion)) -ge 0 )){
                    $geoffreyloaded = $true
                }
            }
        }

        if(!$geoffreyloaded){
            (new-object Net.WebClient).DownloadString('https://raw.githubusercontent.com/geoffrey-ps/geoffrey/master/getgeoffrey.ps1') | Invoke-Expression
        }

        # verify it was loaded
        if(-not (get-command Invoke-Geoffrey -ErrorAction SilentlyContinue)){
            throw ('Unable to load geoffrey, unknown error')
        }
    }
}

Ensure-GeoffreyLoaded

[array]$global:publishResults = @()

task default -dependsOn stop-all-sites,publish-default,publish-no-source,publish-no-pkgs,publish-no-runtime,publish-no-runtime-no-pkgs,publish-no-extra-client-files,publish-no-extra-client-files-no-runtime-no-pkgs,publish-no-source-no-extra-client-files-no-runtime-no-pkgs,wap-01-2013rtm, wap-02-2013rtmu5, wap-03-2015rtm,print-results

task init {
    requires -nameorurl publish-module -version 1.0.2-beta1 -noprefix
    requires -nameorurl psbuild -version '1.1.5-beta' -noprefix -condition (-not (Get-Command -Module psbuild -Name Invoke-MSBuild -ErrorAction SilentlyContinue) )
    # requires 'https://raw.githubusercontent.com/ligershark/psbuild/master/src/GetPSBuild.ps1' -condition (-not (Get-Command -Module psbuild -Name Invoke-MSBuild -ErrorAction SilentlyContinue) )
}

task stop-all-sites {
    # stop all remote sites here
    Stop-Site -sitename ($global:publishsettings.AzureSiteName) | Out-Null
}

task publish-default {

    [System.IO.DirectoryInfo]$path = (Join-Path ($global:publishsettings.PubSamplesRoot) '01-default')
    InternalExecute-Test -testName 'publish-default' -path $path

} -dependsOn stop-all-sites

task publish-no-source{

    [System.IO.DirectoryInfo]$path = (Join-Path ($global:publishsettings.PubSamplesRoot) '02-no-source')
    InternalExecute-Test -testName 'publish-no-source' -path $path

} -dependsOn stop-all-sites

task publish-no-pkgs{

    [System.IO.DirectoryInfo]$path = (Join-Path ($global:publishsettings.PubSamplesRoot) '03-no-pkgs')
    InternalExecute-Test -testName 'publish-no-pkgs' -path $path

} -dependsOn stop-all-sites

task publish-no-runtime{

    [System.IO.DirectoryInfo]$path = (Join-Path ($global:publishsettings.PubSamplesRoot) '04-no-runtime')
    InternalExecute-Test -testName 'publish-no-runtime' -path $path

} -dependsOn stop-all-sites

task publish-no-runtime-no-pkgs{

    [System.IO.DirectoryInfo]$path = (Join-Path ($global:publishsettings.PubSamplesRoot) '05-no-runtime-no-pkgs')
    InternalExecute-Test -testName 'publish-no-runtime-no-pkgs' -path $path

} -dependsOn stop-all-sites

task publish-no-extra-client-files{

    [System.IO.DirectoryInfo]$path = (Join-Path ($global:publishsettings.PubSamplesRoot) '06-no-extra-client-files')
    InternalExecute-Test -testName 'publish-no-extra-client-files' -path $path

} -dependsOn stop-all-sites

task publish-no-extra-client-files-no-runtime-no-pkgs{

    [System.IO.DirectoryInfo]$path = (Join-Path ($global:publishsettings.PubSamplesRoot) '07-no-extra-client-files-no-runtime-no-pkgs')
    InternalExecute-Test -testName 'publish-no-extra-client-files-no-runtime-no-pkgs' -path $path

} -dependsOn stop-all-sites

task publish-no-source-no-extra-client-files-no-runtime-no-pkgs{

    [System.IO.DirectoryInfo]$path = (Join-Path ($global:publishsettings.PubSamplesRoot) '08-no-source-no-extra-client-files-no-runtime-no-pkgs')
    InternalExecute-Test -testName 'publish-no-source-no-extra-client-files-no-runtime-no-pkgs' -path $path

} -dependsOn stop-all-sites


task wap-all -dependsOn wap-01-2013rtm, wap-02-2013rtmu5, wap-03-2015rtm

task wap-01-2013rtm {

    [System.IO.DirectoryInfo]$path = (Join-Path ($global:publishsettings.PubSamplesRoot) 'wap-01-2013rtm')
    InternalExecute-Test -testName 'wap-01-2013rtm' -path $path -publishType wap -wapProjectPath (Join-Path $path 'src\Wap2013RTM.csproj')
}

task wap-02-2013rtmu5 {

    [System.IO.DirectoryInfo]$path = (Join-Path ($global:publishsettings.PubSamplesRoot) 'wap-02-2013rtmu5')
    InternalExecute-Test -testName 'wap-02-2013rtmu5' -path $path -publishType wap -wapProjectPath (Join-Path $path 'src\Wap2013U5.csproj')
}

task wap-03-2015rtm {

    [System.IO.DirectoryInfo]$path = (Join-Path ($global:publishsettings.PubSamplesRoot) 'wap-03-2015rtm')
    InternalExecute-Test -testName 'wap-03-2015rtm' -path $path -publishType wap -wapProjectPath (Join-Path $path 'src\Wap2015.csproj')
}

task print-results{
    $global:publishResults | Write-Output
    Get-PublishReport -allresults $global:publishResults | Select-Object TestName,NumFiles,SizeKB,AverageTime,MinimumTime,MaximumTime|ft -AutoSize
}

function Stop-Site{
    [cmdletbinding()]
    param(
        [Parameter(Position=0,Mandatory=$true,ValueFromPipeline=$true)]
        [ValidateNotNullOrEmpty()]
        $sitename
    )
    process{
        # stop the site here
        Stop-AzureWebsite -Name $sitename
    }
}

function InternalExecute-Test{
    [cmdletbinding()]
    param(
        [Parameter(Position=0,Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$testName,

        [Parameter(Position=1,Mandatory=$true)]
        [System.IO.DirectoryInfo]$path,

        [Parameter(Position=2)]
        [ValidateNotNull()]
        [hashtable]$publishProperties = (InternalGet-PublishProperties),

        [Parameter(Position=3)]
        [ValidateSet('dnx','wap')]
        [string]$publishType = 'dnx',

        [Parameter(Position=4)]
        [System.IO.FileInfo]$wapProjectPath
    )
    process{

        $pubProps = InternalGet-PublishProperties -sitename ($publishProperties.DeployIisAppPath)

        for($i = 0;$i -lt ($global:publishsettings.NumIterations);$i++){
            Delete-RemoteSiteContent -publishProperties $pubProps | Write-Verbose
            Start-Sleep -Seconds 1

            $pubresult = $null
            switch ($publishType){
                'dnx' { 
                    $pubresult = (Publish-FolderToSite -testName $testName -path ($path.FullName) -publishProperties $pubProps) 
                }
                
                'wap' { 
                    InternalAssert-NotEmpty -name 'wapProjectPath' -value $wapProjectPath
                    $pubresult = (Publish-WapProject -projectPath $wapProjectPath -publishProperties $pubProps)
                }
                
                default {
                    throw ('Unknown value for publishType [{0}]' -f $publishType)
                }
            }
            
            $global:publishResults += $pubresult
        }
    }
}

function Invoke-CommandString{
    [cmdletbinding()]
    param(
        [Parameter(Mandatory=$true,Position=0,ValueFromPipeline=$true)]
        [string[]]$command,

        [Parameter(Position=1)]
        $commandArgs,

        $ignoreErrors
    )
    process{
        foreach($cmdToExec in $command){
            'Executing command [{0}]' -f $cmdToExec | Write-Verbose

            # write it to a .cmd file
            $destPath = "$([System.IO.Path]::GetTempFileName()).cmd"
            if(Test-Path $destPath){Remove-Item $destPath|Out-Null}

            try{
                '"{0}" {1}' -f $cmdToExec, ($commandArgs -join ' ') | Set-Content -Path $destPath | Out-Null

                $actualCmd = ('"{0}"' -f $destPath)
                cmd.exe /D /C $actualCmd

                if(-not $ignoreErrors -and ($LASTEXITCODE -ne 0)){
                    $msg = ('The command [{0}] exited with code [{1}]' -f $cmdToExec, $LASTEXITCODE)
                    throw $msg
                }
            }
            finally{
                if(Test-Path $destPath){Remove-Item $destPath -ErrorAction SilentlyContinue |Out-Null}
            }
        }
    }
}

function InternalAssert-NotEmpty{
    [cmdletbinding()]
    param(
        [Parameter(Position=0,Mandatory=$true)]
        [string]$name,

        [Parameter(Position=1,Mandatory=$true)]
        [AllowNull()]
        $value
    )
    process{
        if($value -eq $null){
            throw ('{0} is null' -f $name)
        }
    }
}

function Delete-RemoteSiteContent{
    [cmdletbinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$true)]
        [hashtable[]]$publishProperties
    )
    process{
        foreach($props in $publishProperties){
            'Deleting remote content for site [{0}]' -f ($props.DeployIisAppPath) | Write-Verbose
            # publish an empty app to delete all remote files
            [System.IO.DirectoryInfo]$emptyprojpath = (Join-Path ($global:publishsettings.PubSamplesRoot) '0x-empty')
            Publish-AspNet -packOutput ($emptyprojpath.FullName) -publishProperties (InternalGet-PublishProperties)
        }
    }
}

[hashtable]$script:pubProps = $null
function InternalGet-PublishProperties{
    [cmdletbinding()]
    param(
        [Parameter(Position=0)]
        $sitename = ($global:publishsettings.AzureSiteName)
    )
    process{
        if($script:pubProps -eq $null){
            'Getting azure site object for site [{0}]' -f $sitename | Write-Verbose
            # download the publish settings from Azure and then convert to publishProperties hashtable
            $siteobj = (Get-AzureWebsite -Name $sitename)
            [hashtable]$props = @{
                WebPublishMethod = 'MSDeploy'
                WebRoot = 'wwwroot'
                SkipExtraFilesOnServer = $false
                MSDeployServiceURL = ('{0}:443/msdeploy.axd' -f ($siteobj.SiteProperties.Properties|%{ if($_.Name -eq 'RepositoryUri'){$_.Value} }) )
                DeployIisAppPath = ($siteobj.Name)
                Username = ($siteobj.SiteProperties.Properties|%{ if($_.Name -eq 'PublishingUsername'){$_.Value} })
                Password = ($siteobj.SiteProperties.Properties|%{ if($_.Name -eq 'PublishingPassword'){$_.Value} })
                Sitename = ($sitename)
            }

            $script:pubProps = $props
        }

        # return the publish properties
        $script:pubProps
    }
}

function Get-PublishReport{
    [cmdletbinding()]
    param(
        [array]$allresults = ($global:publishResults)
    )
    process{
        $allresults | Group-Object -Property Testname |% {
            $current = $_
            $result = ($current.Group.ElapsedTime|Measure-Object -Sum -Minimum -Maximum -Average|Select-Object -Property Average,Minimum,Maximum,Sum)
            #$current.Group
            [int]$numfiles = ($current.Group.NumFiles|Select-Object -First 1)
            [int]$sizekb = ($current.Group.SizeKB|Select-Object -First 1)

            New-Object -TypeName psobject -Property @{
                Testname = $current.Name
                AverageTime = [int]$result.Average
                MinimumTime = [int]$result.Minimum
                MaximumTime = [int]$result.Maximum
                TotalTimeAll = [int]$result.Sum
                NumFiles = $numfiles
                SizeKB = $sizekb
            }
        }
    }
}

function Format-PublishReport{
    [cmdletbinding()]
    param(
        [array]$allResults = (Get-PublishReport)
    )
    process{
        $allResults | Select-Object TestName,NumFiles,SizeKB,AverageTime,MinimumTime,MaximumTime|ft -AutoSize
    }
}

function get-standarddeviation {            
    [CmdletBinding()]
    param(
        [Parameter(Position=0)]
        [double[]]$numbers
    )
    begin{
        $avg = 0;
        $nums=@()
    }
    process{
        
        $nums += $numbers
        $avg = ($nums | Measure-Object -Average).Average
        $sum = 0;
        $nums | ForEach-Object { $sum += ($avg - $_) * ($avg - $_) }
        [Math]::Sqrt($sum / $nums.Length)
    }
}

function Remove-OutliersFromData{
    [cmdletbinding()]
    param(
        [array]$allresults = ($global:publishResults)
    )
    process{
        # get the data into groups then for each group find and remove outliers
        # $fromfile|Where-Object {$_.TestName -eq 'publish-default'}|Select-Object -ExpandProperty ElapsedTime|%{$diff=$avg-$_;if([Math]::Abs($diff) -gt (2*(589.12)) ){"$_ inside"}}

        foreach($testname in ($allresults.TestName)){
            $current = ($allresults|Where-Object {$_.TestName -eq $testname})

            [double]$average = (($current|Select-Object -ExpandProperty ElapsedTime|Measure-Object -Average).Average)
            #$stddev = get-standarddeviation ($current|Select-Object -ExpandProperty ElapsedTime)
            foreach($item in $current){
                # if the result in withing 2 standard deviations then output the result, otherwise filter it out
                $difference = [Math]::Abs( $average - ($item.ElapsedTime))
                if($difference -lt ($average*0.25)){
                    $item
                }
                else{
                    'Filtering outlier from results [{0}]' -f $current | Write-Verbose
                }
            }
        }
    }
}

function Publish-FolderToSite{
    [cmdletbinding()]
    param(
        [Parameter(Position=0,Mandatory=$true,ValueFromPipeline=$true)]
        [string]$testName,

        [Parameter(Position=1,Mandatory=$true)]
        [System.IO.DirectoryInfo]$path,

        [Parameter(Position=2,Mandatory=$true)]
        [hashtable]$publishProperties
    )
    process{
        [string]$msdeployUrl = $publishProperties.MSDeployServiceUrl
        [string]$iisAppPath = $publishProperties.DeployIisAppPath

        [string]$username = $publishProperties.Username

        [string]$publishPassword = $publishProperties.Password

        [System.Diagnostics.Stopwatch]$stopwatch = $null
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        
        # publish the site to the remote dest using Publish-AspNet
        Publish-Aspnet -packOutput ($path.FullName) -publishProperties @{
            WebPublishMethod = 'MSDeploy'
            MSDeployServiceURL = $msdeployUrl
            DeployIisAppPath = $iisAppPath
            Username = $username
            Password = $publishPassword
        } | Write-Verbose

        $stopwatch.Stop() | Out-Null

        # return the results
        $result = New-Object -TypeName psobject -Property @{
            TestName = [string]$testName
            ElapsedTime = ($stopwatch.ElapsedMilliseconds)
            NumFiles = ((Get-ChildItem $path -Recurse -File).Length)
            SizeKB =  (((Get-ChildItem $path -Recurse | Measure-Object -property length -sum).Sum)/1KB)
        }

        # return the result
        $result
    }
}

$pubxmltemplate = @'
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="4.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup>
    <MSDeployServiceURL>{0}</MSDeployServiceURL>
    <DeployIisAppPath>{1}</DeployIisAppPath>
    <UserName>{2}</UserName>
	<WebPublishMethod>MSDeploy</WebPublishMethod>
	<SkipExtraFilesOnServer>True</SkipExtraFilesOnServer>
    <MSDeployPublishMethod>WMSVC</MSDeployPublishMethod>
  </PropertyGroup>
</Project>
'@
function Publish-WapProject{
    [cmdletbinding()]
    param(
        [Parameter(Position=0,Mandatory=$true)]
        [ValidateNotNull()]
        [System.IO.FileInfo]$projectPath,

        [Parameter(Position=0,Mandatory=$true)]
        [hashtable]$publishProperties
    )
    process{
        [string]$sitename = $publishProperties['Sitename']
        'Publishing WAP project at [{0}] to [{1}]' -f $projectPath.FullName, $sitename | Write-Verbose

        try{
            Push-Location | Out-Null
            Set-Location ($projectPath.Directory.FullName) | Out-Null
            'Restoring nuget packages for sln root [{0}]' -f ($projectPath.Directory.FullName) | Write-Verbose
            [System.IO.DirectoryInfo]$pkgsdir = (Join-Path ($projectPath.Directory.FullName) '..\packages')
            if(-not (Test-Path $pkgsdir)){
                New-Item -ItemType Directory -Path $pkgsdir | out-null
            }
            Invoke-CommandString -command (Get-Nuget) -commandArgs @('restore','-PackagesDirectory',($pkgsdir.FullName)) | Out-Null
        }
        finally{
            Pop-Location | Out-Null
        }

        # create a .pubxml file for the site and then call msbuild.exe to build & publish
        [string]$username = $publishProperties['Username']
        [string]$pubpwd = $publishProperties['Password']
        [string]$msdeployurl = $publishProperties['MSDeployServiceURL']
        InternalAssert-NotEmpty -name username -value $username | Out-Null
        InternalAssert-NotEmpty -name password -value $pubpwd | Out-Null
        InternalAssert-NotEmpty -name msdeployurl -value $msdeployurl | Out-Null

        [System.IO.FileInfo]$temppubxmlpath = [System.IO.Path]::GetTempFileName()
        $pubxmltemplate -f $msdeployurl,$sitename,$username | Out-File -FilePath ($temppubxmlpath.FullName) -Encoding ascii | Out-Null

        [System.Diagnostics.Stopwatch]$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Invoke-MSBuild -projectsToBuild ($projectPath.FullName) -visualStudioVersion 14.0 -deployOnBuild $true -publishProfile ($temppubxmlpath.FullName) -password $pubpwd -noLogFiles -nologo | Write-Verbose

        $stopwatch.Stop() | Out-Null

        [System.IO.DirectoryInfo]$puboutputpath = (Join-Path $projectPath.Directory.FullName '..\publish-output')

        # return the results
        $result = New-Object -TypeName psobject -Property @{
            TestName = [string]$testName
            ElapsedTime = ($stopwatch.ElapsedMilliseconds)
            NumFiles = ((Get-ChildItem $puboutputpath -Recurse -File).Length)
            SizeKB =  (((Get-ChildItem $puboutputpath -Recurse | Measure-Object -property length -sum).Sum)/1KB)
        }

        # return the result
        $result
    }
}

