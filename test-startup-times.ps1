[cmdletbinding(DefaultParameterSetName='default')]
param(
    [Parameter(ParameterSetName='default',Position=1)]
    [string]$testsessionid = [DateTime]::Now.Ticks,

    [Parameter(ParameterSetName='default',Position=2)]
    [string]$hostingPlanName = 'testhostingplanstandard3',

    [Parameter(ParameterSetName='default',Position=3)]
    [string]$location='North Central US',

    [Parameter(ParameterSetName='default',Position=4)]
    [string]$websiteSku = 'Standard',

    [Parameter(ParameterSetName='default',Position=5)]
    [string]$azurepsapiversion = '2014-04-01-preview',

    [Parameter(ParameterSetName='default',Position=6)]
    $numIterations = 10,

    [Parameter(ParameterSetName='default',Position=7)]
    [System.IO.DirectoryInfo]$logFolder,

    [Parameter(ParameterSetName='default',Position=8)]
    [System.IO.FileInfo]$reportfilepath,

    [Parameter(ParameterSetName='default',Position=9)]
    [switch]$skipPublish,

    # stop parameters
    [Parameter(ParameterSetName='stop',Position=1)]
    [switch]$stopSites,

    # delete parameters
    [Parameter(ParameterSetName='delete',Position=1)]
    [switch]$deleteSites
)

Set-StrictMode -Version Latest

function InternalGet-ScriptDirectory{
    split-path (((Get-Variable MyInvocation -Scope 1).Value).MyCommand.Path)
}
$scriptDir = ((InternalGet-ScriptDirectory) + "\")

if($logFolder -eq $null){
    $logFolder = (Join-Path $scriptDir "logs\$testsessionid")
}

if($reportfilepath -eq $null){
    $reportfilepath = (Join-Path $logFolder 'startuptimes.json')
}

[System.IO.FileInfo]$dnvmpath = (Join-Path $env:USERPROFILE '.dnx\bin\dnvm.cmd')
$originalpath = $env:Path

# http://blogs.technet.com/b/heyscriptingguy/archive/2011/07/23/use-powershell-to-modify-your-environmental-path.aspx
function Add-Path{
    [cmdletbinding()]
    param(
        [Parameter(Mandatory=$True,ValueFromPipeline=$True,Position=0)]
        [string[]]$pathToAdd
    )

    # Get the current search path from the environment keys in the registry.
    $oldpath=$env:path
    if (!$pathToAdd){
        ‘No Folder Supplied. $env:path Unchanged’ | Write-Verbose
    }
    elseif (!(test-path $pathToAdd)){
        ‘Folder [{0}] does not exist, Cannot be added to $env:path’ -f $pathToAdd | Write-Verbose
    }
    elseif ($env:path | Select-String -SimpleMatch $pathToAdd){
        Return ‘Folder already within $env:path' | Write-Verbose
    }
    else{
        'Adding [{0}] to the path' -f $pathToAdd | Write-Verbose
        $newpath = $oldpath
        # set the new path
        foreach($path in $pathToAdd){
            $newPath += ";$path"
        }

        $env:path = $newPath
        [Environment]::SetEnvironmentVariable('path',$newPath,[EnvironmentVariableTarget]::Process) | Out-Null
    }
}

function Ensure-AzurePowerShellImported{
    [cmdletbinding()]
    param()
    process{        
        # try to import the Azure module and then verify it was loaded
        Import-Module Azure -ErrorAction SilentlyContinue | out-null

        if(-not (Get-Module Azure)){
            throw ('Unable to import-module Azure, check that Azure PowerShell is installed')
        }
    }
}

# TODO: This doesn't work, it needs to be updated
function Ensure-AzureUserSignedIn{
    [cmdletbinding()]
    param()
    process{
        # ensure the account is logged in
        if(-not (Get-AzureAccount)){
            throw ('You must be signed in to Azure PowerShell. Use Add-AzureAccount')
        }
    }
}

function New-SiteObject{
    [cmdletbinding()]
    param(
        [Parameter(Mandatory=$true,Position=0)]
        [string]$name,

        [Parameter(Position=1)]
        [System.IO.FileInfo]$projectpath,

        [Parameter(Position=2)]
        [ValidateSet('DNX','WAP')]
        [string]$projectType = 'DNX',

        [Parameter(Position=3)]
        [string]$dnxversion='',

        [Parameter(Position=4)]
        [ValidateSet('x86','x64')]
        [string]$dnxbitness = 'x86',

        [Parameter(Position=5)]
        [ValidateSet('clr','coreclr')]
        [string]$dnxruntime='clr',

        [Parameter(Position=6)]
        [bool]$dnxpublishsource = $true,

        [Parameter(Position=7)]
        [string]$dnxfeed = '',

        [Parameter(Position=8)]
        [System.IO.DirectoryInfo]$solutionRoot
    )
    process{
        $siteobj = New-Object -TypeName psobject -Property @{
            Name = $name
            ProjectPath = $projectpath
            ProjectType = $projectType

            DnxVersion = $dnxversion
            DnxBitness = $null
            DnxRuntime = $null
            DnxFeed = $dnxfeed
            # only needed for WAP project so that nuget restore can be called
            SolutionRoot = $solutionRoot

            # will be populated when the script is started
            AzureSiteObj = $null
        }

        if($projectType -eq 'DNX'){
            $siteobj.DnxBitness = $dnxbitness
            $siteobj.DnxRuntime = $dnxruntime
        }

        $siteobj
    }
}

function Populate-AzureWebSiteObjects{
    [cmdletbinding()]
    param(
        [Parameter(Mandatory=$true,Position=0,ValueFromPipeline=$true)]
        [ValidateNotNull()]
        [object[]]$site
    )
    process{
        foreach($siteobj in $site){
            'Getting azure website info for [{0}]' -f $siteobj.Name | Write-Verbose
            $siteobj.AzureSiteObj = (Get-AzureWebsite -Name $siteobj.Name)
        }
    }
}

function Ensure-SiteExists{
    [cmdletbinding()]
    param(
        [Parameter(Mandatory=$true,Position=0,ValueFromPipeline=$true)]
        [ValidateNotNull()]
        [object[]]$site,

        [Parameter(Position=1)]
        [string]$location = $script:location
    )
    process{
        foreach($siteobj in $site){
            'Ensure-SiteExists [{0}]' -f $siteobj.Name | Write-Verbose
            # try and get the website if it doesn't return a value then create it
            if((Get-AzureWebsite -Name $siteobj.Name) -eq $null){
                'Creating site [{0}]' -f $siteobj.Name | Write-Verbose
                Create-Site -sitenames $siteobj.Name -location $location
            }
        }
    }
}

# TODO: If the hosting plan exists and settings are not what's passed in then update it
function Create-Site{
    param(
        [Parameter(Mandatory=$true,Position=0,ValueFromPipeline=$true)]
        [ValidateNotNull()]
        [object[]]$sitenames,

        [Parameter(Position=1)]
        [string]$hostingPlanName = $script:hostingPlanName,

        [Parameter(Position=2)]
        [string]$location='North Central US',

        [Parameter(Position=3)]
        [string]$websiteSku = 'Standard',

        [Parameter(Position=4)]
        [int]$workerSize = 2,

        [Parameter(Position=5)]
        [string]$azurepsapiversion = '2014-04-01-preview'
    )
    process{
        $hostingplan = $null
        # make sure that the hosting plan exists, if not create it
        try{
            Switch-AzureMode AzureResourceManager | Out-Null
            $hostingplan = Get-AzureResource -ResourceName $hostingPlanName -OutputObjectFormat New -ApiVersion $azurepsapiversion
            if(-not $hostingplan){
                try{
                    'Creating hosting plan named [{0}]' -f $hostingPlanName | Write-Verbose
                    $resourceGroupName = ('Default-Web-{0}' -f $location.Replace(' ',''))
                    $hostingplanprops=@{'name'= $hostingPlanName;'sku'= $websiteSku;'workerSize'= $workerSize;'numberOfWorkers'= 1}
                    $hostingplan = New-AzureResource -Name $hostingPlanName -ResourceGroupName $resourceGroupName -ResourceType Microsoft.Web/serverFarms -Location $location -PropertyObject $hostingplanprops -OutputObjectFormat New -ApiVersion $azurepsapiversion -Force
                }
                catch{
                    throw ('Unable to create hosting plan [{0}]. Exception: {1}' -f $hostingPlanName, $_.Exception)
                }
            }

            $resourceGroupName = ('Default-Web-{0}' -f $location.Replace(' ',''))
            foreach($name in $sitenames){
                try{
                    'Creating new website [{0}]' -f $name  | Write-Verbose
                    New-AzureResource -name $name -ResourceType 'Microsoft.Web/sites' -ResourceGroupName $resourceGroupName -Location $location  -PropertyObject @{'serverFarm'=$hostingplan.ResourceName} -OutputObjectFormat New -ApiVersion $azurepsapiversion -Force
                }
                catch{
                    throw ('Unable to create hosting plan [{0}]. Exception: {1}' -f $name, $_.Exception)
                }
            }
        }
        finally{
            Switch-AzureMode AzureServiceManagement | Out-Null
        }

        foreach($name in $sitenames){
            # TODO: How to do this with AzureResoruceManager when the site is created?
            'Configuring settings on site [{0}]' -f $name | Write-Verbose
            Set-AzureWebsite -Name $name -HttpLoggingEnabled $true -DetailedErrorLoggingEnabled $true -RequestTracingEnabled $true | Out-Null
        }
    }
}

function Publish-Site{
    [cmdletbinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$true)]
        [object[]]$site
    )
    process{
        # figure out if its dnx or a standard wap
        foreach($siteobj in $site){
            'Preparing to publish [{0}]' -f $siteobj.Name | Write-Verbose
            Ensure-AzureWebsiteStopped -name $siteobj.Name
            switch($siteobj.ProjectType){
                'DNX' {Publish-DnxSite -site $siteobj}
                'WAP' {Publish-WapSite -site $siteobj}
            }
        }
    }
}

function Publish-DnxSite{
    [cmdletbinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$true)]
        [object[]]$site
    )

    process{
        foreach($siteobj in $site){
            # reset path to the original value
            $env:path = $originalpath

            if($siteobj -eq $null){
                continue
            }

            Ensure-AzureWebsiteStarted -name ($siteobj.Name) | Write-Verbose

            [System.IO.FileInfo]$projpath = $siteobj.ProjectPath
            if($siteobj.ProjectType -eq 'DNX'){
                'Publishing DNX project at [{0}] to [{1}]' -f $siteobj.projectpath,$siteobj.Name | Write-Verbose
                try{
                    $olddnxfeed = $env:DNX_FEED
                    if(-not [string]::IsNullOrWhiteSpace($siteobj.DnxFeed)){
                        $env:DNX_FEED = $siteobj.DnxFeed
                    }

                    # dnvm install 1.0.0-beta4 -arch x86 -runtime clr
                    $cmdargs = @('install',$siteobj.DnxVersion,'-arch',$siteobj.DnxBitness,'-runtime',$siteobj.DnxRuntime)
                    'Installing dnvm for site [{0}]' -f $siteobj.Name | Write-Verbose
                    Invoke-CommandString -command ($dnvmpath.FullName) -commandArgs $cmdargs

                    # set this as active dnvm
                    $cmdargs = @('use',$siteobj.DnxVersion,'-arch',$siteobj.DnxBitness,'-runtime',$siteobj.DnxRuntime)
                    Invoke-CommandString -command ($dnvmpath.FullName) -commandArgs $cmdargs

                    # add dnx bin to the path C:\Users\sayedha\.dnx\runtimes\dnx-clr-win-x64.1.0.0-beta4\bin
                    $dnxbin = (Join-Path $env:USERPROFILE ('.dnx\runtimes\dnx-{0}-win-{1}.{2}\bin' -f $siteobj.DnxRuntime,$siteobj.DnxBitness,$siteobj.DnxVersion))
                    if(-not (Test-Path $dnxbin)){
                        throw ('dnx bin not found at [{0}]' -f $dnxbin)
                    }

                    Add-Path $dnxbin | Out-Null

                    # call publish to a temp folder
                    [System.IO.FileInfo]$tempfolder = (Join-Path ([System.IO.Path]::GetTempPath()) ('{0}' -f $siteobj.Name) )
                    if(Test-Path $tempfolder){ Remove-Item $tempfolder -Recurse -Force }

                    New-Item -ItemType Directory -Path $tempfolder | Out-Null

                    Push-Location |  Out-Null
                    try{
                        Set-Location $projpath.Directory.FullName | Out-Null
                        # C:\Users\sayedha\.dnx\runtimes\dnx-clr-win-x86.1.0.0-beta5\bin\dnx.exe "C:\Users\sayedha\.dnx\runtimes\dnx-clr-win-x86.1.0.0-beta5\bin\lib\Microsoft.Framework.PackageManager\Microsoft.Framework.PackageManager.dll" restore "<proj-folder-path>"
                        $dnxexe = (Join-Path $dnxbin 'dnx.exe')
                        #[System.IO.FileInfo]$pkgmgrdll = (Join-Path $dnxbin 'lib\Microsoft.Framework.PackageManager\Microsoft.Framework.PackageManager.dll')
                        [System.IO.FileInfo]$pkgmgrdll = (Join-Path $dnxbin 'lib\Microsoft.Dnx.Tooling\Microsoft.Dnx.Tooling.dll')
                        #Microsoft.Dnx.Tooling\Microsoft.Dnx.Tooling.dll

                        $restoreargs = @($pkgmgrdll.FullName,'restore',$projpath.Directory.FullName,'-f','"C:\Program Files (x86)\Microsoft Web Tools\DNU"')
                        if(-not [string]::IsNullOrWhiteSpace($siteobj.DnxFeed)){
                            $restoreargs += '-f'
                            $restoreargs += 'https://nuget.org/api/v2/'
                        }

                        Invoke-CommandString -command $dnxexe -commandArgs $restoreargs

                        # call dnu.cmd to publish the site to a folder
                        $dnxstring = ('dnx-{0}-win-{1}.{2}' -f $siteobj.DnxRuntime,$siteobj.DnxBitness,$siteobj.DnxVersion)
                        $pubargs = ('publish',('"{0}"' -f $projpath.FullName),'--out', ('"{0}"' -f $tempfolder.FullName), '--configuration','Release','--runtime',$dnxstring,'--wwwroot-out','"wwwroot"' )                        
                        Invoke-CommandString -command (Join-Path $dnxbin 'dnu.cmd') -commandArgs $pubargs
                        
                        'Publishing to site [{0}] from folder [{1}]' -f $siteobj.Name,$tempfolder.FullName | Write-Verbose
                        # now publish from that folder to the remote azure site
                        [string]$username = ($siteobj.AzureSiteObj.SiteProperties.Properties|%{ if($_.Name -eq 'PublishingUsername'){$_.Value} })
                        [string]$pubpwd = ($siteobj.AzureSiteObj.SiteProperties.Properties|%{ if($_.Name -eq 'PublishingPassword'){$_.Value} })
                        [string]$msdeployurl = ('{0}:443/msdeploy.axd' -f ($siteobj.AzureSiteObj.SiteProperties.Properties|%{ if($_.Name -eq 'RepositoryUri'){$_.Value} }) )
                        $pubproperties = @{'WebPublishMethod'='MSDeploy';'MSDeployServiceUrl'=$msdeployurl;'DeployIisAppPath'=$siteobj.Name;'Username'=$username;'Password'=$pubpwd;'WebRoot'='wwwroot';'SkipExtraFilesOnServer'=$false}

                        Publish-AspNet -packOutput ($tempfolder.FullName) -publishProperties $pubproperties
                    }
                    catch{
                        throw ( 'Unable to publish the project' -f $_.Exception,(Get-PSCallStack|Out-String) )
                    }
                    finally{
                        Pop-Location | Out-Null
                    }
                }
                finally{
                    if(Test-Path env:DNX_FEED){
                        $env:DNX_FEED = $olddnxfeed
                    }
                }
            }
            else{
                throw ('Unable to publish site with project type [{0}], expected ''DNX''' -f $siteobj.ProjectType)
            }
        }
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
function Publish-WapSite{
    [cmdletbinding()]
    param(
        [object[]]$site
    )
    process{
        foreach($siteobj in $site){
            'Publishing WAP project at [{0}] to [{1}]' -f $siteobj.projectpath,$siteobj.Name | Write-Verbose
            'Restoring nuget packages' | Write-Verbose

            if(-not [string]::IsNullOrEmpty($siteobj.SolutionRoot)){
                try{
                    Push-Location | Out-Null
                    Set-Location $siteobj.SolutionRoot | Out-Null
                    'Restoring nuget packages for sln root [{0}]' -f $siteobj.SolutionRoot | Write-Verbose
                    Invoke-CommandString -command (Get-Nuget) -commandArgs @('restore')
                }
                finally{
                    Pop-Location | Out-Null
                }
            }
            else{
                'Skipping nuget restore because SolutionRoot was not defined on [{0}]' -f $siteobj.Name | Write-Verbose
            }
            # create a .pubxml file for the site and then call msbuild.exe to build & publish
            [string]$username = ($siteobj.AzureSiteObj.SiteProperties.Properties|%{ if($_.Name -eq 'PublishingUsername'){$_.Value} })
            [string]$pubpwd = ($siteobj.AzureSiteObj.SiteProperties.Properties|%{ if($_.Name -eq 'PublishingPassword'){$_.Value} })
            [string]$msdeployurl = ('{0}:443' -f ($siteobj.AzureSiteObj.SiteProperties.Properties|%{ if($_.Name -eq 'RepositoryUri'){$_.Value} }) )
            [System.IO.FileInfo]$temppubxmlpath = [System.IO.Path]::GetTempFileName()
            $pubxmltemplate -f $msdeployurl,$siteobj.Name,$username | Out-File -FilePath ($temppubxmlpath.FullName) -Encoding ascii

            Invoke-MSBuild -projectsToBuild $siteobj.ProjectPath -visualStudioVersion 14.0 -deployOnBuild $true -publishProfile ($temppubxmlpath.FullName) -password $pubpwd
        }
    }
}

function Ensure-AzureWebsiteStopped{
    param(
        [Parameter(Mandatory=$true,Position=0)]
        [ValidateNotNullOrEmpty()]
        [string]$name,

        [int]$numretries = 3
    )
    process{
        'Stopping site [{0}]' -f $name | Write-Verbose
        $retries = 0
        $stoppedsite = $false
        while($retries -le $numretries){
            if( (Stop-AzureWebsite -Name $name -PassThru) -eq $true){
                $stoppedsite = $true
                break;
            }
            Start-Sleep -Seconds 1
            $retries++
        }

        if(-not $stoppedsite){
            throw ('Unable to stop site [{0}] after [{1}] retries' -f $name, $numretries)
        }
    }
}

function Ensure-AzureWebsiteStarted{
    param(
        [Parameter(Mandatory=$true,Position=0)]
        [ValidateNotNullOrEmpty()]
        [string]$name,

        [int]$numretries = 5
    )
    process{
        'Ensuring site is started [{0}]' -f $name | Write-Verbose        
        $startedsite = $false
        $siteobj = Get-AzureWebsite -Name $name

        if([string]::Compare('Running',$siteobj.State,[StringComparison]::OrdinalIgnoreCase) -ne 0){
            $retries = 0
            while($retries -le $numretries){
                if( (Start-AzureWebsite -Name $name -PassThru) -eq $true){
                    $startedsite = $true
                    break;   
                }
                Start-Sleep -Seconds 1
                $retries++
            }        
        }
        else{
            $startedsite = $true
            'Site [{0}] is already running, not starting' -f $name | Write-Verbose
        }

        $throwerror = $true

        if(-not $startedsite -and $throwerror){
            throw ('Unable to start site [{0}] after [{1}] retries' -f $name, $numretries)
        }
    }
}

function Delete-RemoteSiteContent{
    [cmdletbinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$true)]
        [object[]]$site
    )
    process{
        foreach($siteobj in $site){
            $azuresite = $siteobj.AzureSiteObj
            'Deleting files for site [{0}]' -f $azuresite.Name | Write-Verbose
            
            # first stop the site            
            Ensure-AzureWebsiteStopped -Name ($azuresite.Name)
            '1######'|Write-Host -ForegroundColor Red
            if($siteobj.ProjectType -eq 'WAP'){
                '2######'|Write-Host -ForegroundColor Red
                # msdeploy.exe -verb:delete -dest:contentPath=sayed03/,ComputerName='https://sayed03.scm.azurewebsites.net/msdeploy.axd',UserName='$sayed03',Password='%pubpwd%',IncludeAcls='False',AuthType='Basic' -whatif
                $username = ($azuresite.SiteProperties.Properties|%{ if($_.Name -eq 'PublishingUsername'){$_.Value} })
                $pubpwd = ($azuresite.SiteProperties.Properties|%{ if($_.Name -eq 'PublishingPassword'){$_.Value} })
                $msdeployurl = ('{0}/msdeploy.axd' -f ($azuresite.SiteProperties.Properties|%{ if($_.Name -eq 'RepositoryUri'){$_.Value} }) )
                $destarg = ('contentPath={0}/,ComputerName=''{1}'',UserName=''{2}'',Password=''{3}'',IncludeAcls=''False'',AuthType=''Basic''' -f $azuresite.Name, $msdeployurl, $username,$pubpwd )
                $msdeployargs = @('-verb:delete',('-dest:{0}' -f $destarg),'-retryAttempts:3')
                Invoke-CommandString -command (Get-MSDeploy) -commandArgs $msdeployargs
            }
            else{
                '*********************'|Write-Host -ForegroundColor Red
                Ensure-AzureWebsiteStarted -Name ($azuresite.Name)
                'Deleting remote content for site [{0}]' -f ($azuresite.Name) | Write-Verbose
                [System.IO.DirectoryInfo]$emptyprojpath = (Join-Path $scriptDir 'publish-samples\0x-empty')
                [hashtable]$props = @{
                    WebPublishMethod = 'MSDeploy'
                    WebRoot = 'wwwroot'
                    SkipExtraFilesOnServer = $false
                    MSDeployServiceURL = ('{0}:443/msdeploy.axd' -f ($azuresite.SiteProperties.Properties|%{ if($_.Name -eq 'RepositoryUri'){$_.Value} }) )
                    DeployIisAppPath = ($azuresite.Name)
                    Username = ($azuresite.SiteProperties.Properties|%{ if($_.Name -eq 'PublishingUsername'){$_.Value} })
                    Password = ($azuresite.SiteProperties.Properties|%{ if($_.Name -eq 'PublishingPassword'){$_.Value} })
                }
                Publish-AspNet -packOutput ($emptyprojpath.FullName) -publishProperties $props
            }
        }
    }
}

function Load-PublishModule{
    [cmdletbinding()]
    param(
        [Parameter(Position=0)]
        [string]$version = '1.0.2-beta1'
    )
    process{
        # if it's loaded remove and reload
        if(Get-Module publish-module -ErrorAction SilentlyContinue){
            Remove-Module publish-module | Out-Null
        }

        Import-Module (join-path (Get-NuGetPackage -name publish-module -version $version -binpath) 'publish-module.psm1') -DisableNameChecking
    }
}

function Ensure-NuGetPowerShellIsLoaded{
    [cmdletbinding()]
    param(
        $nugetPsMinModVersion = '0.2.3.1'
    )
    process{
        # see if nuget-powershell is available and load if not
        $nugetpsloaded = $false
        if((get-command Get-NuGetPackage -ErrorAction SilentlyContinue)){
            # check the module to ensure we have the correct version
            $currentversion = (Get-Module -Name nuget-powershell).Version
            if( ($currentversion -ne $null) -and ($currentversion.CompareTo([version]::Parse($nugetPsMinModVersion)) -ge 0 )){
                $nugetpsloaded = $true
            }
        }

        if(!$nugetpsloaded){
            (new-object Net.WebClient).DownloadString("https://raw.githubusercontent.com/ligershark/nuget-powershell/master/get-nugetps.ps1") | iex
        }

        # verify it was loaded
        if(-not (get-command Get-NuGetPackage -ErrorAction SilentlyContinue)){
            throw ('Unable to load nuget-powershell, unknown error')
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

function Ensure-DnvmInstalled{
    [cmdletbinding()]
    param()
    process{
        if(-not (Test-Path $dnvmpath)){
            throw ('Unable to find dnvm at [{0}]' -f $dnvmpath.FullName)
        }
    }
}

function Ensure-ClientToolsInstalled{
    [cmdletbinding()]
    param(
        [System.IO.DirectoryInfo]$externaltoolspath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio 14.0\Common7\IDE\Extensions\Microsoft\Web Tools\External\"
    )
    process{
        if(Test-Path $externaltoolspath){
            Add-Path ($externaltoolspath.FullName)
        }
        else{
            throw ('Unable to find external tools folder at [{0}]' -f $externaltoolspath)
        }

        # do this so that bower.cmd can be resolved as bower when post scripts are executed
        Get-ChildItem $externaltoolspath *.cmd | % {
            Set-Alias ($_.BaseName) $_.FullName
        }

        $npmpath = "$env:AppData\npm"
        if(Test-Path $npmpath){
            Add-Path -pathToAdd $npmpath | Out-Null
        }
        else{
            '1: Unable to find npm at expected location [{0}]' -f $npmpath | Write-Warning
        }

        if(-not (Test-Path env:NODE_PATH)){
            $nodepath = "$env:APPDATA\npm\node_modules\"
            if(Test-Path $nodepath){
                $env:NODE_PATH = $nodepath
            }
            else{
                throw ('Unable to find node path at [{0}]' -f $nodepath)
            }
        }
    }
}

function Initalize{
    [cmdletbinding()]
    param()
    process{
        Ensure-ClientToolsInstalled
        Ensure-DnvmInstalled
        Ensure-AzurePowerShellImported
        Ensure-AzureUserSignedIn
        Ensure-NuGetPowerShellIsLoaded
        Load-PublishModule
    }
}

function Measure-Request{
    [cmdletbinding()]    
    param(
        [Parameter(Mandatory=$true,Position=0)]
        [string]$url,

        [Parameter(Mandatory=$true,Position=1)]
        [string]$name,

        [Parameter(Position=2)]
        [string]$testsessionid = $script:testsessionid,

        [Parameter(Position=3)]
        [ValidateSet('first','second')]
        [string]$whichrequest,

        [Parameter(Position=4)]
        [string]$requestId = '',

        [Parameter(Position=5)]
        [int]$numRetries = 10
    )
    process{
        $count = 0
        $measure = $null
        $resp = $null
        $statusCodeStr = "(null)"
        [System.Diagnostics.Stopwatch]$stopwatch = $null

        # http://publishtestdnx-beta5-clr-nosource.azurewebsites.net/?testsessionid=12345&testrequest=first&requestId=1
        [string]$fullurl = ('{0}?testsessionid={1}&testrequest={2}&requestId={3}&ticks={4}' -f $url,$testsessionid,$whichrequest,$currentIteration,[datetime]::Now.Ticks)

        do{
            if($count -gt 0){
                Ensure-AzureWebsiteStarted -name $name | Out-Null
            }

            try{   
                $count++ | Out-Null

                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $resp = Invoke-WebRequest $fullurl -TimeoutSec (60*2)
                $stopwatch.Stop() | Out-Null
                [System.TimeSpan]$resptime = $stopwatch.Elapsed
            }
            catch{
                # ignore and try again
                $_.Exception | Write-Verbose
            }
            if(-not $? -or ($resp -eq $null) -or ($resp.StatusCode -ne 200)){
                if($resp -ne $null){
                    $statusCodeStr = $resp.StatusCode
                }

                'Unable to complete web request, status code: [{0}]' -f $statusCodeStr | Write-Verbose
                Start-Sleep ($count+1)
            }
        }while(
                ( ($resp -eq $null) -or ($resp.StatusCode -ne 200)) -and 
                ($count -le $numRetries))


        if( ($resp -eq $null) -or ($resp.StatusCode -ne 200)){
            
            if($resp -ne $null){
                $statusCodeStr = $resp.StatusCode
            }
            throw ("`r`nReceived an unexpected http status code [{0}] for url [{1}]`r`nIterations:{2}`r`n" -f $statusCodeStr, $fullurl, $currentIteration)
        }

        # create an object with all the data and return it
        New-Object -TypeName psobject -Property @{
            Name = $name
            Url = $fullurl
            Response = New-Object -TypeName psobject -Property @{
                StatusCode = $resp.StatusCode
                ContentLength = $resp.RawContentLength
            }
            ResponseTime = $stopwatch.Elapsed.TotalMilliseconds
            NumAttempts = ($count+1)
            Iteration=$requestId
            ServerResponseTime = $null
            ServerLogString = $null
        }
    }
}

function Get-ServerResponseTimesFromLogRaw{
    [cmdletbinding()]
    param(
        [Parameter(Mandatory=$true,Position=0,ValueFromPipeline=$true)]
        [string[]]$sitename,

        [Parameter(Position=1)]
        $testsessionid = $script:testsessionid,

        [Parameter(Position=2)]
        $numIterations = $script:numIterations,

        [Parameter(Position=3,Mandatory=$true)]
        [ValidateNotNull()]
        [System.IO.DirectoryInfo]$logFolder

    )
    begin{
        Add-Type -assembly "system.io.compression.filesystem"
    }
    process{
        if(-not (Test-Path $logFolder.FullName)){
            New-Item -ItemType Directory -Path $logFolder.FullName | Out-Null
        }
        foreach($name in $sitename){
            [System.IO.DirectoryInfo]$sitelogfolder = (Join-Path $logFolder "$name-$testsessionid")
            [System.IO.FileInfo]$tempfile = (Join-Path $sitelogfolder.FullName 'logs.zip')
            
            if(-not (Test-Path $tempfile)){
                if(-not (Test-Path $sitelogfolder)){ New-Item -ItemType Directory -Path $sitelogfolder | Out-Null }
                Save-AzureWebsiteLog -Name $name -Output $tempfile.FullName | Out-Null
                # extract the log files
                [io.compression.zipfile]::ExtractToDirectory($tempfile.FullName, $sitelogfolder.FullName) | Out-Null
            }

            [System.IO.DirectoryInfo]$httplogfolder = (Join-Path $sitelogfolder.FullName 'LogFiles\http\RawLogs')
            $pattern = ('(?<logstr>{0}.*testsessionid={1}&testrequest=(?<whichrequest>.[^&]*)&requestId=(?<iteration>\d+).*\s200\s\d+\s\d+\s\d+\s\d+\s(?<time>\d+))' -f [regex]::Escape($sitename.ToUpper()), $testsessionid)

            Get-ChildItem $httplogfolder *.log | Get-Content | % {
                if($_ -match $pattern){
                    New-Object -TypeName psobject -Property @{
                        Iteration = $Matches['iteration']
                        WhichRequest = $Matches['whichrequest']
                        TimeSpent = $Matches['time']
                        ServerLogString = $Matches['logstr']
                    }
                }
            }
        }
    }
}

function Measure-SiteResponseTimesForAll{
    [cmdletbinding()]
    param(
        [Parameter(Mandatory=$true,Position=0)]
        [object[]]$sites,

        [Parameter(Position=1)]
        [string]$testsessionid = $script:testsessionid,

        [Parameter(Position=2)]
        [int]$numIterations = $script:numIterations,

        [Parameter(Position=3)]
        [int]$maxnumretries = 10
    )
    process{
        [string[]]$sitestotest = $sites.Name
        [hashtable]$results = @{}

        $currentIteration = 0
        try{
            for($currentIteration = 1; $currentIteration -le $numIterations; $currentIteration++){
                'Iteration [{0}]' -f $currentIteration | Write-Verbose
                foreach($site in $sites){
                    # stop the site
                    $siteobj = ($site.AzureSiteObj)
                    Stop-AzureWebsite -Name ($site.Name) | Out-Null
                    Start-AzureWebsite -Name ($site.Name) | Out-Null

                    $url = ('http://{0}' -f $siteobj.EnabledHostNames[0])
                    $measure = Measure-Request -url $url -numRetries $maxnumretries -name $siteobj.Name -testsessionid $script:testsessionid -whichrequest first -requestId $currentIteration
                    $measureSecondReq = Measure-Request -url $url -numRetries $maxnumretries -name $siteobj.Name -testsessionid $script:testsessionid -whichrequest second -requestId $currentIteration

                    "{0}: {1} milliseconds, second request {2}" -f $url,$measure.ResponseTime,$measureSecondReq.ResponseTime | Write-Verbose

                    # return an object with the result
                    $result = New-Object -TypeName psobject -Property @{
                        FirstRequest = $measure
                        SecondRequest = $measureSecondReq
                    }

                    if(-not $results.ContainsKey($site.Name)){
                        $results[$site.Name]=@()
                    }
                    $results[$site.Name]+=$result
                    $result | Write-Verbose
                }
            }

            # create a summary object for each site
            foreach($sitename in $sitestotest){
                $avgmillifirst = (($results[$sitename].FirstRequest.ResponseTime|Measure-Object -Sum).Sum)/$numIterations
                $avgmillisecond = (($results[$sitename].SecondRequest.ResponseTime|Measure-Object -Sum).Sum)/$numIterations
                $totalattemptsfirstreq = (($results[$sitename].FirstRequest.NumAttempts|Measure-Object -Sum).Sum)
                $totalattemptssecondreq = (($results[$sitename].SecondRequest.NumAttempts|Measure-Object -Sum).Sum)

                $serveravgfirst = $null
                $serveravgsecond = $null
                try{
                    # download the http log files for the site and get time-spent for this request on first and second request
                    $serverresptimes = Get-ServerResponseTimesFromLogRaw -sitename $sitename -numIterations $numIterations -logFolder $logFolder

                    [string]$serverlogstr = $null
                    foreach($serverresp in $serverresptimes){
                        switch($serverresp.WhichRequest){
                            'first' {
                                $results[$sitename][$serverresp.Iteration-1].FirstRequest.ServerResponseTime = $serverresp.TimeSpent
                                $results[$sitename][$serverresp.Iteration-1].FirstRequest.ServerLogString = $serverresp.ServerLogString
                            }
                            'second' {
                                $results[$sitename][$serverresp.Iteration-1].SecondRequest.ServerResponseTime = $serverresp.TimeSpent
                                $results[$sitename][$serverresp.Iteration-1].SecondRequest.ServerLogString = $serverresp.ServerLogString
                            }
                        }
                    }

                    $serveravgfirst = (($results[$sitename].FirstRequest.ServerResponseTime|Where-Object {$_ -ne $null}|Measure-Object -Average).Average)
                    $serveravgsecond = (($results[$sitename].SecondRequest.ServerResponseTime|Where-Object {$_ -ne $null}|Measure-Object -Average).Average)
                }
                catch{
                    "Unable to download azure http logs. {0} {1}" -f $_.Exception,(Get-PSCallStack|Out-String) | Write-Warning
                }

                # return the object
                New-Object -TypeName psobject -Property @{
                    Name = $sitename
                    AverageFirstRequestResponseTime = $serveravgfirst
                    AverageSecondRequestResponseTime = $serveravgsecond
                    ClientAverageFirstRequestResponseTime = $avgmillifirst
                    ClientAverageSecondRequestResponseTime = $avgmillisecond
                    TotalNumAttemptsFirstResponse = $totalattemptsfirstreq
                    TotalNumAttemptsSecondResponse = $totalattemptssecondreq
                    RawResults = ($results[$sitename])
                }
            }
        }
        catch{
            throw ("An unepected error occurred {0}`r`n{1}" -f $_.Exception,(Get-PSCallStack|Out-String))
        }
    }
}

function CreateReport{
    [cmdletbinding()]
    param(
        [Parameter(Position=0,Mandatory=$true)]
        [ValidateNotNull()]
        $testresult,

        [Parameter(Position=1,Mandatory=$true)]
        [ValidateNotNull()]
        [System.IO.FileInfo]$reportfilepath
    )
    process{
        $testresult | ConvertTo-Json -Depth 100 |% {$_.Replace('  ',' ')} | Out-File $reportfilepath.FullName -Encoding ascii -Force
    }
}

# begin script

[System.IO.FileInfo]$samplewapproj = (Join-Path $scriptDir 'samples\src\WapMvc46\WapMvc46.csproj')
[System.IO.FileInfo]$samplednxproj = (Join-Path $scriptDir 'samples\src\DnxWebApp\DnxWebApp.xproj')
[System.IO.FileInfo]$samplebeta5xproj = (Join-Path $scriptDir 'samples\src\DnxWebBeta5\DnxWebBeta5.xproj')
[System.IO.FileInfo]$samplebeta7xproj = (Join-Path $scriptDir 'samples\src\DnxWebBeta7\DnxWebBeta7.xproj')

$sites = @(
    New-SiteObject -name pub-wap -projectpath $samplewapproj -projectType WAP -SolutionRoot ($samplewapproj.Directory.Parent.Parent.FullName)

    New-SiteObject -name pubdnx-beta7-clr-with-source -projectpath $samplebeta7xproj -projectType DNX -dnxbitness x86 -dnxruntime clr -dnxpublishsource $false -dnxversion 1.0.0-beta7

    #New-SiteObject -name pubdnx-beta4-clr-withsource -projectpath $samplednxproj -projectType DNX -dnxbitness x86 -dnxruntime clr -dnxpublishsource $true  -dnxversion 1.0.0-beta4 -dnxfeed '"C:\Program Files (x86)\Microsoft Web Tools\DNU"'
    #New-SiteObject -name pubdnx-beta4-coreclr-withsource -projectpath $samplednxproj -projectType DNX -dnxbitness x86 -dnxruntime coreclr -dnxpublishsource $true  -dnxversion 1.0.0-beta4  -dnxfeed '"C:\Program Files (x86)\Microsoft Web Tools\DNU"'
    #New-SiteObject -name pubdnx-beta4-clr-nosource -projectpath $samplednxproj -projectType DNX -dnxbitness x86 -dnxruntime clr -dnxpublishsource $false  -dnxversion 1.0.0-beta4  -dnxfeed '"C:\Program Files (x86)\Microsoft Web Tools\DNU"'
    #New-SiteObject -name pubdnx-beta4-coreclr-nosource -projectpath $samplednxproj -projectType DNX -dnxbitness x86 -dnxruntime coreclr -dnxpublishsource $false  -dnxversion 1.0.0-beta4  -dnxfeed '"C:\Program Files (x86)\Microsoft Web Tools\DNU"'
    
    #New-SiteObject -name pubdnx-beta5-clr-withsource -projectpath $samplebeta5xproj -projectType DNX -dnxbitness x86 -dnxruntime clr -dnxpublishsource $true -dnxversion 1.0.0-beta5  -dnxfeed '"C:\Program Files (x86)\Microsoft Web Tools\DNU"'
    #New-SiteObject -name pubdnx-beta5-coreclr-withsource -projectpath $samplebeta5xproj -projectType DNX -dnxbitness x86 -dnxruntime coreclr -dnxpublishsource $true -dnxversion 1.0.0-beta5 -dnxfeed '"C:\Program Files (x86)\Microsoft Web Tools\DNU"'
    #New-SiteObject -name pubdnx-beta5-clr-nosource -projectpath $samplebeta5xproj -projectType DNX -dnxbitness x86 -dnxruntime clr -dnxpublishsource $false -dnxversion 1.0.0-beta5 -dnxfeed '"C:\Program Files (x86)\Microsoft Web Tools\DNU"'
    #New-SiteObject -name pubdnx-beta5-coreclr-nosource -projectpath $samplebeta5xproj -projectType DNX -dnxbitness x86 -dnxruntime clr -dnxpublishsource $false -dnxversion 1.0.0-beta5 -dnxfeed '"C:\Program Files (x86)\Microsoft Web Tools\DNU"'
)

if($stopSites){
    'Stopping websites' | Write-Host
    foreach($site in $sites){
        try{
            Stop-AzureWebsite -Name $site.Name
        }
        catch{
            $_.Exception | Write-Warning
        }
    }
}
elseif($deleteSites){
    'Deleting all websites' | Write-Host
    foreach($site in $sites){
        try{
            Remove-AzureWebsite -Name $site.Name -Force
        }
        catch{
            $_.Exception | Write-Warning
        }
    }
}
else
{
    try{
        $starttime = Get-Date
        'Start time: [{0}]. testsessionid: [{0}]' -f ($starttime.ToString('hh:mm:ss tt')),$testsessionid | Write-Verbose
 
        Initalize

        $sites | Ensure-SiteExists
        $sites | Populate-AzureWebSiteObjects

        if(-not $skipPublish){
            # $sites | Delete-RemoteSiteContent
            $sites | Publish-Site
        }

        $result = Measure-SiteResponseTimesForAll -sites $sites
    
        $global:testresult = $result
        CreateReport -testresult $result -reportfilepath $reportfilepath
        # return the result to the caller
        $result

        # write out a summary at the end
        $result | Select-Object Name,AverageFirstRequestResponseTime,AverageSecondRequestResponseTime, ClientAverageFirstRequestResponseTime,ClientAverageSecondRequestResponseTime | Format-Table | Out-String

        $endtime = Get-Date
        'End time: [{0}]. Time spent [{1}] seconds' -f $endtime.ToString('hh:mm:ss tt'),($endtime - $starttime).TotalSeconds | Write-Verbose
    }
    catch{
        $msg = $_.Exception.ToString()
        $msg | Write-Error
    }
}