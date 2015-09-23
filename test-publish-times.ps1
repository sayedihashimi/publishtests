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
    NumIterations = 1
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

task default -dependsOn stop-all-sites,test-publish-default,test-publish-no-runtime-no-pkgs,test-publish-no-extra-client-files,test-publish-no-extra-client-files-no-runtime-no-pkgs,test-publish-no-source-no-extra-client-files-no-runtime-no-pkgs

task init {
    requires -nameorurl publish-module -version 1.0.2-beta1 -noprefix
}

task stop-all-sites {
    # stop all remote sites here
    Stop-Site -sitename ($global:publishsettings.AzureSiteName)
}

task test-publish-default {

    [System.IO.DirectoryInfo]$path = (Join-Path ($global:publishsettings.PubSamplesRoot) '01-default')
    $pubProps = InternalGet-PublishProperties -sitename ($global:publishsettings.AzureSiteName)
    Delete-RemoteSiteContent -publishProperties $pubProps
    Publish-FolderToSite -path ($path.FullName) -publishProperties $pubProps

} -dependsOn stop-all-sites

task test-publish-no-runtime-no-pkgs{
} -dependsOn stop-all-sites

task test-publish-no-extra-client-files{
} -dependsOn stop-all-sites

task test-publish-no-extra-client-files-no-runtime-no-pkgs{
} -dependsOn stop-all-sites

task test-publish-no-source-no-extra-client-files-no-runtime-no-pkgs{
} -dependsOn stop-all-sites

function Stop-Site{
    [cmdletbinding()]
    param(
        [Parameter(Position=0,Mandatory=$true,ValueFromPipeline=$true)]
        $sitename
    )
    process{
        # stop the site here
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

function Delete-RemoteSiteContent{
    [cmdletbinding()]
    param(
        [Parameter(Position=0,ValueFromPipeline=$true)]
        [hashtable[]]$publishProperties
    )
    process{
        foreach($props in $publishProperties){
            'Deleting remote content for site [{0}]' -f ($props.DeployIisAppPath) | Write-Verbose
            $sitename = $props.DeployIisAppPath
            # msdeploy.exe -verb:delete -dest:contentPath=sayed03/,ComputerName='https://sayed03.scm.azurewebsites.net/msdeploy.axd',UserName='$sayed03',Password='%pubpwd%',IncludeAcls='False',AuthType='Basic' -whatif
            $username = $props.Username
            $pubpwd = $props.Password
            $msdeployurl = $props.MSDeployServiceURL
            $destarg = ('contentPath={0}/,ComputerName=''{1}'',UserName=''{2}'',Password=''{3}'',IncludeAcls=''False'',AuthType=''Basic''' -f $sitename, $msdeployurl, $username,$pubpwd )
            $msdeployargs = @('-verb:delete',('-dest:{0}' -f $destarg),'-retryAttempts:3')
            Invoke-CommandString -command (Get-MSDeploy) -commandArgs $msdeployargs
        }
    }
}

[hashtable]$script:pubProps = $null
function InternalGet-PublishProperties{
    [cmdletbinding()]
    param(
        [Parameter(Position=0,Mandatory=$true,ValueFromPipeline=$true)]
        $sitename
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
            }

            $script:pubProps = $props
        }

        # return the publish properties
        $script:pubProps
    }
}

function Publish-FolderToSite{
    [cmdletbinding()]
    param(
        [Parameter(Position=0,Mandatory=$true,ValueFromPipeline=$true)]
        [System.IO.DirectoryInfo]$path,

        [Paramter(Position=1,Mandatory=$true)]
        $publishProperties
    )
    process{    
        [string]$msdeployUrl = $null
        [string]$iisAppPath = $null
        [string]$username = $null
        [string]$publishPassword = $null
        # publish the site to the remote dest using Publish-AspNet
        Publish-Aspnet -packOutput $path -publishProperties @{
            WebPublishMethod = 'MSDeploy'
            MSDeployServiceURL = $msdeployUrl
            DeployIisAppPath = $iisAppPath
            Username = $username
            Password = $publishPassword
        }
    }
}