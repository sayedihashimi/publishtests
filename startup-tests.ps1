[cmdletbinding()]
param()

Set-StrictMode -Version Latest

function InternalGet-ScriptDirectory{
    split-path (((Get-Variable MyInvocation -Scope 1).Value).MyCommand.Path)
}
$scriptDir = ((InternalGet-ScriptDirectory) + "\")

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
        [ValidateSet('x86','x64')]
        [string]$dnxbitness = 'x86',

        [Parameter(Position=4)]
        [ValidateSet('clr','coreclr')]
        [string]$dnxruntime='clr',

        [Parameter(Position=5)]
        [bool]$dnxpublishsource = $true

    )
    process{
        $siteobj = New-Object -TypeName psobject -Property @{
            Name = $name
            ProjectPath = $projectpath
            ProjectType = $projectType
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

function Delete-RemoteSiteContent{
    [cmdletbinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$true)]
        [object[]]$site
    )
    process{
        foreach($siteobj in $site){
            # $siteobj.AzureSiteObj
            
            $azuresite = $siteobj.AzureSiteObj
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

function Initialize{
    [cmdletbinding()]
    param()
    process{
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
    New-SiteObject -name publishtestwap -projectpath $samplewapproj -projectType WAP
    New-SiteObject -name publishtestdnx-clr-withsource -projectpath $samplednxproj -projectType DNX -dnxbitness x86 -dnxruntime clr -dnxpublishsource $true
    New-SiteObject -name publishtestdnx-coreclr-withsource -projectpath $samplednxproj -projectType DNX -dnxbitness x86 -dnxruntime coreclr -dnxpublishsource $true
    New-SiteObject -name publishtestdnx-clr-nosource -projectpath $samplednxproj -projectType DNX -dnxbitness x86 -dnxruntime clr -dnxpublishsource $false
    New-SiteObject -name publishtestdnx-coreclr-nosource -projectpath $samplednxproj -projectType DNX -dnxbitness x86 -dnxruntime coreclr -dnxpublishsource $false
)


try{
    Initialize
}
catch{
    $msg = $_.Exception.ToString()
    $msg | Write-Error
}

