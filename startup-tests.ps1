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
    [Cmdletbinding()]
    param
    (
        [parameter(Mandatory=$True,
        ValueFromPipeline=$True,
        Position=0)]
        [String[]]$AddedFolder
    )

    # Get the current search path from the environment keys in the registry.

    $OldPath=$ENV:PATH
    if (!$AddedFolder){ Return ‘No Folder Supplied. $ENV:PATH Unchanged’}
    if (!(TEST-PATH $AddedFolder)){ Return ‘Folder Does not Exist, Cannot be added to $ENV:PATH’ }
    if ($ENV:PATH | Select-String -SimpleMatch $AddedFolder){ Return ‘Folder already within $ENV:PATH' }

    $newpath = $OldPath
    # Set the New Path
    foreach($path in $AddedFolder){
        $NewPath=$NewPath+’;’+$path
    }

    $ENV:PATH = $NewPath
    [Environment]::SetEnvironmentVariable('path',$NewPath,[EnvironmentVariableTarget]::Process)
    return $NewPath
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
        [bool]$dnxpublishsource = $true

    )
    process{
        $siteobj = New-Object -TypeName psobject -Property @{
            Name = $name
            ProjectPath = $projectpath
            ProjectType = $projectType
            DnxVersion = $dnxversion
            DnxBitness = $null
            DnxRuntime = $null

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
                $dnxstring = ('{0}' -f $dnxversion)

                # command: dnvm install 1.0.0-beta4 -arch x86 -runtime clr
                $cmdargs = @('install',$siteobj.DnxVersion,'-arch',$siteobj.DnxBitness,'-runtime',$siteobj.DnxRuntime)
                'Installing dnvm for site [{0}]' -f $siteobj.Name | Write-Verbose
                Invoke-CommandString -command ($dnvmpath.FullName) -commandArgs $cmdargs

                # set this as active dnvm
                $cmdargs = @('use',$siteobj.DnxVersion,'-arch',$siteobj.DnxBitness,'-runtime',$siteobj.DnxRuntime)
                Invoke-CommandString -command ($dnvmpath.FullName) -commandArgs $cmdargs

                # add dnx bin to the path C:\Users\sayedha\.dnx\runtimes\dnx-clr-win-x64.1.0.0-beta4\bin
                $dnxbin = (Join-Path $env:USERPROFILE ('.dnx\runtimes\dnx-{0}-win-{1}.{2}\bin' -f $siteobj.DnxRuntime,$siteobj.DnxBitness,$dnxstring))
                if(-not (Test-Path $dnxbin)){
                    throw ('dnx bin not found at [{0}]' -f $dnxbin)
                }

                Add-Path $dnxbin

                # call publish to a temp folder
                $tempfolder = (Join-Path ([System.IO.Path]::GetTempPath()) ('{0}-{1}' -f $siteobj.Name,[Guid]::NewGuid()) )
                if(Test-Path $tempfolder){
                    Remove-Item $tempfolder -Recurse
                }

                New-Item -ItemType Directory -Path $tempfolder

                Push-Location
                try{
                    Set-Location $projpath.Directory.FullName
                    & dnu restore
                    & dnu.cmd publish -o $tempfolder
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

function Publish-WapSite{
    [cmdletbinding()]
    param(
        [object[]]$site
    )
    process{
        foreach($siteobj in $site){
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
            Stop-AzureWebsite ($azuresite.Name)

            # delete the files in the remote

            # msdeploy.exe -verb:delete -dest:contentPath=sayed03/,ComputerName='https://sayed03.scm.azurewebsites.net/msdeploy.axd',UserName='$sayed03',Password='%pubpwd%',IncludeAcls='False',AuthType='Basic' -whatif
            # todo: finish here

            $username = ($azuresite.SiteProperties.Properties|%{ if($_.Name -eq 'PublishingUsername'){$_.Value} })
            $pubpwd = ($azuresite.SiteProperties.Properties|%{ if($_.Name -eq 'PublishingPassword'){$_.Value} })
            $msdeployurl = ('{0}/msdeploy.axd' -f ($azuresite.SiteProperties.Properties|%{ if($_.Name -eq 'RepositoryUri'){$_.Value} }) )
            $destarg = ('contentPath={0}/,ComputerName=''{1}'',UserName=''{2}'',Password=''{3}'',IncludeAcls=''False'',AuthType=''Basic'' -whatif' -f $azuresite.Name, $msdeployurl, $username,$pubpwd )
            $msdeployargs = @('-verb:delete',('-dest:{0}' -f $destarg),'-whatif')
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
        [System.IO.FileInfo]$nodeexe = "${env:ProgramFiles(x86)}\Microsoft Visual Studio 14.0\Common7\IDE\Extensions\Microsoft\Web Tools\External\node\node.exe"
        if(Test-Path $nodeexe){
            # Set-Alias node $nodeexe

            Add-Path -AddedFolder ($nodeexe.Directory.FullName)
        }
        else{
            throw ('Unable to find node.exe at [{0}]' -f $nodeexe)
        }

        $externalfolder = "${env:ProgramFiles(x86)}\Microsoft Visual Studio 14.0\Common7\IDE\Extensions\Microsoft\Web Tools\External"
        if(Test-Path $externalfolder){
            Add-Path -AddedFolder $externalfolder
        }
        else{
            'Unable to find external folder at expected location [{0}]' -f $externalfolder | Write-Warning
        }

        $npmpath = "$env:AppDatad\npm;"
        if(Test-Path $externalfolder){
            Add-Path -AddedFolder $npmpath
        }
        else{
            'Unable to find npm at expected location [{0}]' -f $npmpath | Write-Warning
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

        $sites | Ensure-SiteExists
        $sites | Populate-AzureWebSiteObjects

        $sites | Delete-RemoteSiteContent
    }
}

# begin script

[System.IO.FileInfo]$samplewapproj = (Join-Path $scriptDir 'samples\src\WapMvc46\WapMvc46.csproj')
[System.IO.FileInfo]$samplednxproj = (Join-Path $scriptDir 'samples\src\DnxWebApp\DnxWebApp.xproj')

$sites = @(
    # New-SiteObject -name publishtestwap -projectpath $samplewapproj -projectType WAP
    New-SiteObject -name publishtestdnx-clr-withsource -projectpath $samplednxproj -projectType DNX -dnxbitness x86 -dnxruntime clr -dnxpublishsource $true
    New-SiteObject -name publishtestdnx-coreclr-withsource -projectpath $samplednxproj -projectType DNX -dnxbitness x86 -dnxruntime coreclr -dnxpublishsource $true
    New-SiteObject -name publishtestdnx-clr-nosource -projectpath $samplednxproj -projectType DNX -dnxbitness x86 -dnxruntime clr -dnxpublishsource $false
    New-SiteObject -name publishtestdnx-coreclr-nosource -projectpath $samplednxproj -projectType DNX -dnxbitness x86 -dnxruntime coreclr -dnxpublishsource $false
)


try{
    #Initalize
    #$testsite = New-SiteObject -name publishtestdnx-clr-withsource -projectpath $samplednxproj -projectType DNX -dnxbitness x86 -dnxruntime clr -dnxpublishsource $true
    #$testsite | Populate-AzureWebSiteObjects
    #$testsite | Publish-Site

    #Push-Location
    #try{
    #    Set-Location (join-path $scriptDir Samples\src\DnxWebApp )
    #    & dnu publish -o C:\temp\publish\01\
    #}
    #finally{
    #    Pop-Location
    #}

}
catch{
    $msg = $_.Exception.ToString()
    $msg | Write-Error
}

<#

Push-Location
try{
    
    Set-Location C:\Data\mycode\publishtests\Samples\src\DnxWebApp 
    & dnu publish -o C:\temp\publish\01\
}
finally{
    Pop-Location
}


#>