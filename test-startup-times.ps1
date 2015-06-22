[cmdletbinding()]
param()

Set-StrictMode -Version Latest

function InternalGet-ScriptDirectory{
    split-path (((Get-Variable MyInvocation -Scope 1).Value).MyCommand.Path)
}
$scriptDir = ((InternalGet-ScriptDirectory) + "\")

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
        [string]$SolutionRoot
    )
    process{
        $siteobj = New-Object -TypeName psobject -Property @{
            Name = $name
            ProjectPath = $projectpath
            ProjectType = $projectType

            DnxVersion = $dnxversion
            DnxBitness = $null
            DnxRuntime = $null

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
        [object[]]$site
    )
    process{
        foreach($siteobj in $site){
            'Ensure-SiteExists [{0}]' -f $siteobj.Name | Write-Verbose
            # try and get the website if it doesn't return a value then create it
            if((Get-AzureWebsite -Name $siteobj.Name) -eq $null){
                'Creating site [{0}]' -f $siteobj.Name | Write-Verbose
                New-AzureWebsite -Name $siteobj.Name | Out-Null
            }
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
                # need to set dnx for the project


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

                New-Item -ItemType Directory -Path $tempfolder

                Push-Location
                try{
                    Set-Location $projpath.Directory.FullName
                    & dnu restore
                    # call dnu.cmd to publish the site to a folder
                    $dnxstring = ('dnx-{0}-win-{1}.{2}' -f $siteobj.DnxRuntime,$siteobj.DnxBitness,$dnxversion)
                    $pubargs = ('publish','-o',$tempfolder.FullName,'--configuration','Release','--wwwroot-out','wwwroot','--runtime',$dnxstring)
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
                    Set-Location (join-path $siteobj.projectpath.Directory.Fullname $siteobj.SolutionRoot)
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

        <#
        $npmexe = "$env:ProgramFiles\nodejs\npm.cmd"
        if(Test-Path $npmexe){
            Set-Alias node $npmexe
        }
        else{
            throw ('Unable to find npm.exe at [{0}]' -f $npmexe)
        }
        #>
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
        [Parameter(Mandatory=$true)]
        [string]$url,

        [Parameter(Mandatory=$true)]
        [string]$name,

        [int]$numRetries = 10
    )
    process{
        $count = 0
        $measure = $null
        $response = $null

        # TODO: Check the num bytes received to ensure its over 1 before counting it as a valid response even if status code is OK.

        do{
            if($count -gt 0){
                # last request was an error try starting and then sleeping for a better chance on next request
                'Ensuring the site [{0}] is started' -f $name | Write-Verbose
                Ensure-AzureWebsiteStopped -Name $name -ErrorAction Ignore
                Ensure-AzureWebsiteStarted -Name $name -ErrorAction Ignore
                Start-Sleep 5
            }

            try{
                $measure = Measure-Command { $response = Invoke-WebRequest $url }
            }
            catch{
                # ignore and try again
                "2: $_.Exception" | Write-Warning
            }
            if(-not $? -or ($response -eq $null) -or ($response.StatusCode -ne 200)){
                $statuscode = '(null)'
                if($response -ne $null -and ($response.StatusCode -ne $null)){
                    $statuscode = $response.StatusCode
                }
                'Unable to complete web request, status code: [{0}]' -f $statuscode | Write-Verbose
                
            }
        }while(
                ( ($response -eq $null) -or ($response.StatusCode -ne 200)) -and
                ($count++ -le $numRetries))

        try{
            if( ($response -eq $null) -or ($response.StatusCode -ne 200)){
                $statusCodeStr = "(null)"
                if($response -ne $null){
                    $statusCodeStr = $response.StatusCode
                }
                throw ("`r`nReceived an unexpected http status code [{0}] for url [{1}]`r`nIterations:{2}`r`nTotals:{3}`r`nSecond Request:{4}" -f $statusCodeStr,$url,$currentIteration,($totalMilli|Out-String),($totalMilliSecondReq|Out-String))
            }
        }
        catch{
            "3: $_.Exception" | Write-Warning
        }
        $measure
    }
}

# TODO: Needs some cleanup
function Measure-SiteResponseTimesForAll-Old{
    [cmdletbinding()]
    param(
        [Parameter(Mandatory=$true,Position=0)]
        [object[]]$sites,

        [Parameter(Position=2)]
        [int]$numIterations = 10,

        [Parameter(Position=3)]
        [int]$maxnumretries = 10
    )
    process{
        [hashtable]$totalMilli = @{}
        [hashtable]$totalMilliSecondReq = @{}

        $sites | % {
            $totalMilli[$_] = 0
            $totalMilliSecondReq[$_]=0
        }

        $currentIteration = 0
        try{
            1..$numIterations | % {
                $currentIteration++
                foreach($site in $sites){
                    # stop the site
                    $siteobj = $site.AzureSiteObj
                    Ensure-AzureWebsiteStopped -Name ($siteobj.Name)
                    # start the site
                    Ensure-AzureWebsiteStarted -Name ($siteobj.Name)
                    # give it a second to settle before making a request to avoid 502 errors
                    Start-Sleep -Seconds 2
                    # make a webrequest and time it
                    $url = ('http://{0}' -f $siteobj.EnabledHostNames[0])

                    $measure = Measure-Request -url $url -numRetries $maxnumretries -name $siteobj.Name
                    $totalMilli[$site]+= $measure.TotalMilliseconds

                    $measureSecondReq = Measure-Request -url $url -numRetries $maxnumretries -name $siteobj.Name
                    $totalMilliSecondReq[$site]+= $measureSecondReq.TotalMilliseconds

                    "{0}`t{1} milliseconds, second request {2}" -f $url, $measure.TotalMilliseconds,$measureSecondReq.TotalMilliseconds | Write-Verbose
                }
            }
            
            foreach($site in $sites){
                # return the object with the data to the stream
                New-Object -TypeName psobject -Property @{
                    Site = $_                    
                    NumIterations = $numIterations
                    TotalMillisecondsFirstRequest = $totalMilli
                    AverageMillisecondsFirstRequest = ($totalMilli[$_]/$numIterations)
                    TotalMillisecondsSecondRequest = ($totalMilliSecondReq / $numIterations)
                    AverageMillisecondsSecondRequest = ($totalMilliSecondReq[$_]/$numIterations)
                }
            }
        }
        catch{
            'An unepected error occurred while processing [{0}] Error:{1}' -f $site.Name, $_.Exception
        }
    }
}

function Measure-SiteResponseTimesForAll{
    [cmdletbinding()]
    param(
        [Parameter(Mandatory=$true,Position=0)]
        [object[]]$sites,

        [Parameter(Position=2)]
        [int]$numIterations = 10,

        [Parameter(Position=3)]
        [int]$maxnumretries = 5
    )
    process{
        [string[]]$sitestotest = $sites.Name
        
        $totalMilliTimeWap = 0
        $totalMilliTimeV5 = 0
        #$numIterations = 1
        [hashtable]$totalMilli = @{}
        [hashtable]$totalMilliSecondReq = @{}
        [hashtable]$azWebsites = @{}
        $sitestotest | % {
            $totalMilli[$_] = 0
            $totalMilliSecondReq[$_]=0
            $azWebsites[$_] = (Get-AzureWebsite -Name $_)
        }
        #$maxnumretries = 5
        $currentIteration = 0
        try{
            1..$numIterations | % {
                $currentIteration++
                foreach($site in $sitestotest){
                    # stop the site
                    $siteobj = ($azWebsites[$site])
                    $siteobj | Stop-AzureWebsite
                    # start the site
                    $siteobj | Start-AzureWebsite
                    # give it a second to settle before making a request to avoid 502 errors
                    Start-Sleep -Seconds 2
                    # make a webrequest and time it
                    $url = ('http://{0}' -f $siteobj.EnabledHostNames[0])
                    $url | Write-Host -NoNewline
            
                    $measure = Measure-Request -url $url -numRetries $maxnumretries -name $siteobj.Name
                    $totalMilli[$site]+= $measure.TotalMilliseconds

                    $measureSecondReq = Measure-Request -url $url -numRetries $maxnumretries -name $siteobj.Name
                    $totalMilliSecondReq[$site]+= $measureSecondReq.TotalMilliseconds

                    "`t{0} milliseconds, second request {1}" -f $measure.TotalMilliseconds,$measureSecondReq.TotalMilliseconds | Write-Host
                }
            }

            'Average response time for [{0}] iterations' -f $numIterations | Write-Host
            $sitestotest | %{
                $avgmilli = $totalMilli[$_]/$numIterations
                $avgMilliSecondReq = $totalMilliSecondReq[$_]/$numIterations
                '{0}: {1} milliseconds, second request {2} milliseconds' -f $_,$avgmilli,$avgMilliSecondReq | Write-Host
            }
        }
        catch{
            'An unepected error occurred {0}' -f $_.Exception
        }
    }
}



# begin script

[System.IO.FileInfo]$samplewapproj = (Join-Path $scriptDir 'samples\src\WapMvc46\WapMvc46.csproj')
[System.IO.FileInfo]$samplednxproj = (Join-Path $scriptDir 'samples\src\DnxWebApp\DnxWebApp.xproj')

$sites = @(
    New-SiteObject -name publishtestwap -projectpath $samplewapproj -projectType WAP
    New-SiteObject -name publishtestdnx-clr-withsource -projectpath $samplednxproj -projectType DNX -dnxbitness x86 -dnxruntime clr -dnxpublishsource $true
    New-SiteObject -name publishtestdnx-coreclr-withsource -projectpath $samplednxproj -projectType DNX -dnxbitness x86 -dnxruntime coreclr -dnxpublishsource $true
    New-SiteObject -name publishtestdnx-clr-nosource -projectpath $samplednxproj -projectType DNX -dnxbitness x86 -dnxruntime clr -dnxpublishsource $false
    New-SiteObject -name publishtestdnx-coreclr-nosource -projectpath $samplednxproj -projectType DNX -dnxbitness x86 -dnxruntime coreclr -dnxpublishsource $false
)

try{
    Initalize

    # $sites | Ensure-SiteExists
    $sites | Populate-AzureWebSiteObjects

    #$sites | Delete-RemoteSiteContent
    #$sites | Publish-Site

    $result = Measure-SiteResponseTimesForAll -sites $sites

    $global:testresult = $result

    # display the result at the end
    $result
}
catch{
    $msg = $_.Exception.ToString()
    $msg | Write-Error
}