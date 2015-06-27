[cmdletbinding()]
param(
    [Parameter(Position=0)]
    [System.IO.FileInfo]$reportfilepath,

    [Parameter(Position=1)]
    [string]$testsessionid = [DateTime]::Now.Ticks,

    [Parameter(Position=2)]
    [string]$hostingPlanName = 'teststartuptimeshostingplan',

    [Parameter(Position=3)]
    [string]$location='East US',

    [Parameter(Position=4)]
    [string]$websiteSku = 'Basic',

    [Parameter(Position=5)]
    [string]$azurepsapiversion = '2014-04-01-preview',

    [Parameter(Position=6)]
    $numIterations = 25,

    [Parameter(Position=6)]
    [bool]$deletelogfiles = $false
)

Set-StrictMode -Version Latest

function InternalGet-ScriptDirectory{
    split-path (((Get-Variable MyInvocation -Scope 1).Value).MyCommand.Path)
}
$scriptDir = ((InternalGet-ScriptDirectory) + "\")

if($reportfilepath -eq $null){
    $reportfilepath = (Join-Path $scriptDir 'startuptimes.json')
}

[System.IO.FileInfo]$dnvmpath = (Join-Path $env:USERPROFILE '.dnx\bin\dnvm.cmd')
$dnxversion = '1.0.0-beta4'
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
        return
    }
    elseif (!(test-path $pathToAdd)){
        ‘Folder Does not Exist, Cannot be added to $env:path’ | Write-Verbose
    }
    elseif ($env:path | Select-String -SimpleMatch $pathToAdd){
        Return ‘Folder already within $env:path'
    }
    else{
        'Adding [{0}] to the path' -f $pathToAdd | Write-Verbose
        $newpath = $oldpath
        # set the new path
        foreach($path in $pathToAdd){
            $newPath=$newPath+’;’+$path
        }

        $env:path = $newPath
        [Environment]::SetEnvironmentVariable('path',$newPath,[EnvironmentVariableTarget]::Process)
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
        [string]$dnxversion = $script:dnxversion,

        [Parameter(Position=4)]
        [ValidateSet('x86','x64')]
        [string]$dnxbitness = 'x86',

        [Parameter(Position=5)]
        [ValidateSet('clr','coreclr')]
        [string]$dnxruntime='clr',

        [Parameter(Position=6)]
        [bool]$dnxpublishsource = $true,

        [Parameter(Position=7)]
        [string]$dnxfeed,

        [Parameter(Position=8)]
        [System.IO.DirectoryInfo]$SolutionRoot
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
            SolutionRoot = $SolutionRoot

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

function Create-Site{
    param(
        [Parameter(Mandatory=$true,Position=0,ValueFromPipeline=$true)]
        [ValidateNotNull()]
        [object[]]$sitenames,

        [Parameter(Position=1)]
        [string]$hostingPlanName = 'teststartuptimeshostingplan',

        [Parameter(Position=2)]
        [string]$location='East US',

        [Parameter(Position=3)]
        [string]$websiteSku = 'Basic',

        [Parameter(Position=4)]
        [string]$azurepsapiversion = '2014-04-01-preview'
    )
    process{
        $hostingplan = $null
        # make sure that the hosting plan exists, if not create it
        try{
            Switch-AzureMode AzureResourceManager
            $hostingplan = Get-AzureResource -ResourceName $hostingPlanName -OutputObjectFormat New -ApiVersion $azurepsapiversion
            if(-not $hostingplan){
                try{
                    'Creating hosting plan named [{0}]' -f $hostingPlanName | Write-Verbose
                    $resourceGroupName = ('Default-Web-{0}' -f $location.Replace(' ',''))
                    $hostingplanprops=@{'name'= $hostingPlanName;'sku'= $websiteSku;'workerSize'= '0';'numberOfWorkers'= 1}
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
                    # New-AzureResource -name $name -ResourceType 'Microsoft.Web/sites' -ResourceGroupName $resourceGroupName -Location $location  -PropertyObject @{'serverFarmId'=$hostingplan.ResourceId} -ApiVersion $azurepsapiversion
                    New-AzureResource -name $name -ResourceType 'Microsoft.Web/sites' -ResourceGroupName $resourceGroupName -Location $location  -PropertyObject @{'serverFarm'=$hostingplan.ResourceName} -OutputObjectFormat New -ApiVersion $azurepsapiversion -Force
                }
                catch{
                    throw ('Unable to create hosting plan [{0}]. Exception: {1}' -f $name, $_.Exception)
                }
            }
        }
        finally{
            Switch-AzureMode AzureServiceManagement
        }

        foreach($name in $sitenames){
            # configure http logging
            # TODO: How to do this with AzureResoruceManager?
            Set-AzureWebsite -Name $name -HttpLoggingEnabled $true
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
            if($siteobj.ProjectType -eq 'DNX'){
                Publish-DnxSite -site $siteobj
            }
            elseif($siteobj.ProjectType -eq 'WAP'){
                Publish-WapSite -site $siteobj
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

            [System.IO.FileInfo]$projpath = $siteobj.ProjectPath
            if($siteobj.ProjectType -eq 'DNX'){
                'Publishing DNX project at [{0}] to [{1}]' -f $siteobj.projectpath,$siteobj.Name | Write-Verbose
                try{
                    $olddnxfeed = $env:DNX_FEED
                    if(-not [string]::IsNullOrWhiteSpace($siteobj.DnxFeed)){
                        $env:DNX_FEED = $siteobj.DnxFeed
                    }

                    # command: dnvm install 1.0.0-beta4 -arch x86 -runtime clr
                    $cmdargs = @('install',$siteobj.DnxVersion,'-arch',$siteobj.DnxBitness,'-runtime',$siteobj.DnxRuntime)
                    'Installing dnvm for site [{0}]' -f $siteobj.Name | Write-Verbose
                    Invoke-CommandString -command ($dnvmpath.FullName) -commandArgs $cmdargs

                    # set this as active dnvm
                    $cmdargs = @('use',$siteobj.DnxVersion,'-arch',$siteobj.DnxBitness,'-runtime',$siteobj.DnxRuntime)
                    Invoke-CommandString -command ($dnvmpath.FullName) -commandArgs $cmdargs

                    # add dnx bin to the path C:\Users\sayedha\.dnx\runtimes\dnx-clr-win-x64.1.0.0-beta4\bin
                    $dnxbin = (Join-Path $env:USERPROFILE ('.dnx\runtimes\dnx-{0}-win-{1}.{2}\bin' -f $siteobj.DnxRuntime,$siteobj.DnxBitness,$dnxversion))
                    if(-not (Test-Path $dnxbin)){
                        throw ('dnx bin not found at [{0}]' -f $dnxbin)
                    }

                    Add-Path $dnxbin | Out-Null

                    # call publish to a temp folder
                    [System.IO.FileInfo]$tempfolder = (Join-Path ([System.IO.Path]::GetTempPath()) ('{0}' -f $siteobj.Name) )
                    if(Test-Path $tempfolder){
                        Remove-Item $tempfolder -Recurse
                    }

                    New-Item -ItemType Directory -Path $tempfolder | Out-Null

                    Push-Location
                    try{
                        Set-Location $projpath.Directory.FullName
                        $restoreargs = @('restore','--quiet')
                        if(-not [string]::IsNullOrWhiteSpace($siteobj.DnxFeed)){
                            $restoreargs += '-f'
                            $restoreargs += 'https://nuget.org/api/v2/'
                        }

                        # & dnu restore $restoreargs
                        Invoke-CommandString -command (join-path $dnxbin 'dnu.cmd') -commandArgs $restoreargs

                        # call dnu.cmd to publish the site to a folder
                        $dnxstring = ('dnx-{0}-win-{1}.{2}' -f $siteobj.DnxRuntime,$siteobj.DnxBitness,$dnxversion)
                        $pubargs = ('publish','-o',$tempfolder.FullName,'--configuration','Release','--wwwroot-out','wwwroot','--runtime',$dnxstring,'--quiet')
                        Invoke-CommandString -command (Join-Path $dnxbin 'dnu.cmd') -commandArgs $pubargs
                        # now publish from that folder to the remote azure site

                        [string]$username = ($siteobj.AzureSiteObj.SiteProperties.Properties|%{ if($_.Name -eq 'PublishingUsername'){$_.Value} })
                        [string]$pubpwd = ($siteobj.AzureSiteObj.SiteProperties.Properties|%{ if($_.Name -eq 'PublishingPassword'){$_.Value} })
                        [string]$msdeployurl = ('{0}:443' -f ($siteobj.AzureSiteObj.SiteProperties.Properties|%{ if($_.Name -eq 'RepositoryUri'){$_.Value} }) )
                        $pubproperties = @{'WebPublishMethod'='MSDeploy';'MSDeployServiceUrl'=$msdeployurl;'DeployIisAppPath'=$siteobj.Name;'Username'=$username;'Password'=$pubpwd;'WebRoot'='wwwroot'}

                        Publish-AspNet -packOutput ($tempfolder.FullName) -publishProperties $pubproperties
                    }
                    finally{
                        Pop-Location
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
                    Push-Location
                    Set-Location $siteobj.SolutionRoot
                    'Restoring nuget packages for sln root [{0}]' -f $siteobj.SolutionRoot | Write-Verbose
                    Invoke-CommandString -command (Get-Nuget) -commandArgs @('restore')
                }
                finally{
                    Pop-Location
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

        [int]$numretries = 3
    )
    process{
        'Starting site [{0}]' -f $name | Write-Verbose
        $retries = 0
        $startedsite = $false
        while($retries -le $numretries){
            if( (Start-AzureWebsite -Name $name -PassThru) -eq $true){
                $startedsite = $true
                break;   
            }
            Start-Sleep -Seconds 1
            $retries++
        }

        if(-not $startedsite){
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
            Start-Sleep -Seconds 4
            # delete the files in the remote

            # msdeploy.exe -verb:delete -dest:contentPath=sayed03/,ComputerName='https://sayed03.scm.azurewebsites.net/msdeploy.axd',UserName='$sayed03',Password='%pubpwd%',IncludeAcls='False',AuthType='Basic' -whatif

            $username = ($azuresite.SiteProperties.Properties|%{ if($_.Name -eq 'PublishingUsername'){$_.Value} })
            $pubpwd = ($azuresite.SiteProperties.Properties|%{ if($_.Name -eq 'PublishingPassword'){$_.Value} })
            $msdeployurl = ('{0}/msdeploy.axd' -f ($azuresite.SiteProperties.Properties|%{ if($_.Name -eq 'RepositoryUri'){$_.Value} }) )
            $destarg = ('contentPath={0}/,ComputerName=''{1}'',UserName=''{2}'',Password=''{3}'',IncludeAcls=''False'',AuthType=''Basic''' -f $azuresite.Name, $msdeployurl, $username,$pubpwd )
            $msdeployargs = @('-verb:delete',('-dest:{0}' -f $destarg),'-retryAttempts:3')
            Invoke-CommandString -command (Get-MSDeploy) -commandArgs $msdeployargs
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

        import-module (join-path (Get-NuGetPackage -name publish-module -version $version -binpath) 'publish-module.psm1') -DisableNameChecking
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
        # (Join-Path $env:USERPROFILE '.dnx\bin\dnvm.ps1')
        if(-not (Test-Path $dnvmpath)){
            throw ('Unable to find dnvm at [{0}]' -f $dnvmpath.FullName)
        }
    }
}

function Ensure-ClientToolsInstalled{
    [cmdletbinding()]
    param()
    process{
        [System.IO.DirectoryInfo]$externaltools = "${env:ProgramFiles(x86)}\Microsoft Visual Studio 14.0\Common7\IDE\Extensions\Microsoft\Web Tools\External\"
        if(Test-Path $externaltools){
            Add-Path ($externaltools.FullName)
        }
        else{
            throw ('Unable to find external tools folder at [{0}]' -f $externaltools)
        }

        # do this so that bower.cmd can be resolved as bower when post scripts are executed
        Get-ChildItem $externaltools *.cmd | % {
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
        [int]$numRetries = 10
    )
    process{
        $count = 0
        $measure = $null
        $resp = $null
        $statusCodeStr = "(null)"
        [System.Diagnostics.Stopwatch]$stopwatch = $null

        # http://publishtestdnx-beta5-clr-nosource.azurewebsites.net/?testsessionid=12345&testrequest=first
        [string]$fullurl = ('{0}?testsessionid={1}&testrequest={2}' -f $url,$testsessionid,$whichrequest)

        do{
            try{
                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $resp = Invoke-WebRequest $fullurl
                $stopwatch.Stop()
                [System.TimeSpan]$resptime = $stopwatch.Elapsed
            }
            catch{
                # ignore and try again
                Write-Verbose $_
            }
            if(-not $? -or ($resp -eq $null) -or ($resp.StatusCode -ne 200)){
                if($resp -ne $null){
                    $statusCodeStr = $resp.StatusCode
                }

                'Unable to complete web request, status code: [{0}]' -f $statusCodeStr | Write-Verbose
                Stop-AzureWebsite -Name $name
                Start-AzureWebsite -Name $name
                Start-Sleep ($count+1)
            }
        }while(
                ( ($resp -eq $null) -or ($resp.StatusCode -ne 200)) -and 
                ($count++ -le $numRetries))

        if( ($resp -eq $null) -or ($resp.StatusCode -ne 200)){
            
            if($resp -ne $null){
                $statusCodeStr = $resp.StatusCode
            }
            throw ("`r`nReceived an unexpected http status code [{0}] for url [{1}]`r`nIterations:{2}`r`nTotals:{3}`r`nSecond Request:{4}" -f $statusCodeStr,$fullurl,$currentIteration,($totalMilli|Out-String),($totalMilliSecondReq|Out-String))
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
        }
    }
}

function Get-ServerResponseTimesFromLog{
    [cmdletbinding()]
    param(
        [Parameter(Mandatory=$true,Position=0,ValueFromPipeline=$true)]
        [string[]]$sitename,

        [Parameter(Position=1)]
        $testsessionid = $script:testsessionid,

        [Parameter(Position=2)]
        $numIterations = $script:numIterations
    )
    begin{
        Add-Type -assembly "system.io.compression.filesystem"
    }
    process{
        foreach($name in $sitename){
            try{
                # download the log files to a temp folder            
                [System.IO.FileInfo]$tempfolder = (Join-Path ([System.IO.Path]::GetTempPath()) ('{0}-{1}-logs' -f $name,$testsessionid) )
                New-Item -ItemType Directory -Path $tempfolder.FullName | Out-Null
                [System.IO.FileInfo]$tempfile = (Join-Path $tempfolder.FullName 'logs.zip')
                Save-AzureWebsiteLog -Name $name -Output $tempfile.FullName | Out-Null

                # extract the log files to a temp folder
                [io.compression.zipfile]::ExtractToDirectory($tempfile.FullName, $tempfolder.FullName) | Out-Null

                [System.IO.DirectoryInfo]$httplogfolder = (Join-Path $tempfolder.FullName 'LogFiles\http\RawLogs')
                $firstreqpattern = ('{0}.*testsessionid={1}&testrequest=first.*\s200\s\d+\s\d+\s\d+\s\d+\s\d+' -f [regex]::Escape($name.ToUpper()), $testsessionid)
                $secondreqpattern = ('{0}.*testsessionid={1}&testrequest=second.*\s200\s\d+\s\d+\s\d+\s\d+\s\d+' -f [regex]::Escape($name.ToUpper()), $testsessionid)

                $firstreqresponsetimes = (Get-ChildItem $httplogfolder *.log | Get-Content | Where-Object { $_ -match $firstreqpattern} | % { [int]($_.Substring($_.LastIndexOf(' ')+1)) }  | Measure-Object -Sum -Average)
                $secondreqresponsetimes = (Get-ChildItem $httplogfolder *.log | Get-Content | Where-Object { $_ -match $secondreqpattern} | % { [int]($_.Substring($_.LastIndexOf(' ')+1)) }  | Measure-Object -Sum -Average)

                '{0}:firstreqresponsetimes: [{1}]' -f $name, ($firstreqresponsetimes | Out-String) | Write-Verbose
                '{0}:secondreqresponsetimes: [{1}]' -f $name, ($secondreqresponsetimes | Out-String) | Write-Verbose

                if($firstreqresponsetimes -eq $null -or ($secondreqresponsetimes -eq $null)){
                    'Log results null' | Write-Warning
                }
                elseif($firstreqresponsetimes.Count -ne $numIterations -or ($secondreqresponsetimes.Count -ne $numIterations)){
                    'Expected [{0}] requests but only found [{0}] and [{1}]' -f $firstreqresponsetimes.Count,$secondreqresponsetimes.Count | Write-Warning
                }

                # return the result
                New-Object -TypeName psobject -Property @{
                    Name = $name
                    AverageFirstRequestResponseTime = $firstreqresponsetimes.Average
                    AverageSecondRequestResponseTime = $secondreqresponsetimes.Average
                }
            }
            finally{
                # delete the temp folder
                if($deletelogfiles -and (Test-Path $tempfolder)){
                    #Remove-Item $tempfolder.FullName -Recurse | Out-Null
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
            1..$numIterations | % {
                $currentIteration++
                foreach($site in $sites){
                    # stop the site
                    $siteobj = ($site.AzureSiteObj)
                    Stop-AzureWebsite -Name ($site.Name)
                    # start the site
                    Start-AzureWebsite -Name ($site.Name)
                    # give it a second to settle before making a request to avoid 502 errors
                    Start-Sleep -Seconds 2

                    $url = ('http://{0}' -f $siteobj.EnabledHostNames[0])
                    $measure = Measure-Request -url $url -numRetries $maxnumretries -name $siteobj.Name -testsessionid $script:testsessionid -whichrequest first
                    $measureSecondReq = Measure-Request -url $url -numRetries $maxnumretries -name $siteobj.Name -testsessionid $script:testsessionid -whichrequest second

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
            # wait 20 sec for iis logs to be written
            Start-Sleep 20
            # create a summary object for each site
            foreach($sitename in $sitestotest){
                $avgmillifirst = (($results[$sitename].FirstRequest.ResponseTime|Measure-Object -Sum).Sum)/$numIterations
                $avgmillisecond = (($results[$sitename].SecondRequest.ResponseTime|Measure-Object -Sum).Sum)/$numIterations
                $totalattemptsfirstreq = (($results[$sitename].FirstRequest.NumAttempts|Measure-Object -Sum).Sum)
                $totalattemptssecondreq = (($results[$sitename].SecondRequest.NumAttempts|Measure-Object -Sum).Sum)
                
                # download the http log files for the site and get time-spent for this request on first and second request

                $servertimes = Get-ServerResponseTimesFromLog -sitename $sitename -numIterations $numIterations

                # return the object
                New-Object -TypeName psobject -Property @{
                    Name = $sitename
                    AverageFirstRequestResponseTime = ($servertimes.AverageFirstRequestResponseTime)
                    AverageSecondRequestResponseTime = ($servertimes.AverageSecondRequestResponseTime)
                    ClientAverageFirstRequestResponseTime = $avgmillifirst
                    ClientAverageSecondRequestResponseTime = $avgmillisecond
                    TotalNumAttemptsFirstResponse = $totalattemptsfirstreq
                    TotalNumAttemptsSecondResponse = $totalattemptssecondreq
                    RawResults = ($results[$sitename])
                }
            }
        }
        catch{
            "An unepected error occurred {0}`r`n{1}" -f $_.Exception,(Get-PSCallStack|Out-String)
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
        [System.IO.FileInfo]$reportpath
    )
    process{
        $testresult | ConvertTo-Json -Depth 100 |% {$_.Replace('  ',' ')} | Out-File $reportpath -Force
    }
}

# begin script

[System.IO.FileInfo]$samplewapproj = (Join-Path $scriptDir 'samples\src\WapMvc46\WapMvc46.csproj')
[System.IO.FileInfo]$samplednxproj = (Join-Path $scriptDir 'samples\src\DnxWebApp\DnxWebApp.xproj')
[System.IO.FileInfo]$samplebeta5xproj = (Join-Path $scriptDir 'samples\src\DnxWebBeta5\DnxWebBeta5.xproj')

$sites = @(
    New-SiteObject -name publishtestwap -projectpath $samplewapproj -projectType WAP -SolutionRoot ($samplewapproj.Directory.Parent.Parent.FullName)

    New-SiteObject -name publishtestdnx-beta5-clr-withsource -projectpath $samplebeta5xproj -projectType DNX -dnxbitness x86 -dnxruntime clr -dnxpublishsource $true -dnxversion 1.0.0-beta5 -dnxfeed 'https://www.myget.org/F/aspnetbeta5/api/v2'
    New-SiteObject -name publishtestdnx-beta5-coreclr-withsource -projectpath $samplebeta5xproj -projectType DNX -dnxbitness x86 -dnxruntime coreclr -dnxpublishsource $true -dnxversion 1.0.0-beta5 -dnxfeed 'https://www.myget.org/F/aspnetbeta5/api/v2'
    New-SiteObject -name publishtestdnx-beta5-clr-nosource -projectpath $samplebeta5xproj -projectType DNX -dnxbitness x86 -dnxruntime clr -dnxpublishsource $false -dnxversion 1.0.0-beta5 -dnxfeed 'https://www.myget.org/F/aspnetbeta5/api/v2'
    New-SiteObject -name publishtestdnx-beta5-coreclr-nosource -projectpath $samplebeta5xproj -projectType DNX -dnxbitness x86 -dnxruntime clr -dnxpublishsource $false -dnxversion 1.0.0-beta5 -dnxfeed 'https://www.myget.org/F/aspnetbeta5/api/v2'

    New-SiteObject -name publishtestdnx-beta4-clr-withsource -projectpath $samplednxproj -projectType DNX -dnxbitness x86 -dnxruntime clr -dnxpublishsource $true
    New-SiteObject -name publishtestdnx-beta4-coreclr-withsource -projectpath $samplednxproj -projectType DNX -dnxbitness x86 -dnxruntime coreclr -dnxpublishsource $true
    New-SiteObject -name publishtestdnx-beta4-clr-nosource -projectpath $samplednxproj -projectType DNX -dnxbitness x86 -dnxruntime clr -dnxpublishsource $false
    New-SiteObject -name publishtestdnx-beta4-coreclr-nosource -projectpath $samplednxproj -projectType DNX -dnxbitness x86 -dnxruntime coreclr -dnxpublishsource $false
)

try{    
    $starttime = Get-Date
    'Start time: [{0}]. testsessionid: [{0}]' -f ($starttime.ToString('hh:mm:ss tt')),$testsessionid | Write-Verbose
    Initalize

    #$sites | Ensure-SiteExists
    $sites | Populate-AzureWebSiteObjects

    #$sites | Delete-RemoteSiteContent
    #$sites | Publish-Site

    $result = Measure-SiteResponseTimesForAll -sites $sites

    $global:testresult = $result

    # return the result to the caller
    $result

    # write out a summary at the end
    $result | Select-Object Name,AverageFirstRequestResponseTime,AverageSecondRequestResponseTime, ClientAverageFirstRequestResponseTime,ClientAverageSecondRequestResponseTime | Format-Table | Out-String | Write-Host -ForegroundColor Green

    $endtime = Get-Date
    'End time: [{0}]. Time spent [{1}] seconds' -f $endtime.ToString('hh:mm:ss tt'),($endtime - $starttime).TotalSeconds | Write-Verbose
}
catch{
    $msg = $_.Exception.ToString()
    $msg | Write-Error
}