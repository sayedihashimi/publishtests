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

$global:publishsettings = New-Object -TypeName psobject -Property @{
    MinGeoffreyModuleVersion = '0.0.10.1'
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
            # check the module to ensure we have the correct version
            $currentversion = (Get-Module -Name geoffrey).Version
            if( ($currentversion -ne $null) -and ($currentversion.CompareTo([version]::Parse($minGeoffreyModuleVersion)) -ge 0 )){
                $geoffreyloaded = $true
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

task init {
    requires -nameorurl publish-module -version 1.0.2-beta1 -noprefix
}

task test-publish-default{
}

task test-publish-no-runtime-no-pkgs{
}

task test-publish-no-extra-client-files{
}

task test-publish-no-extra-client-files-no-runtime-no-pkgs{
}

task test-publish-no-source-no-extra-client-files-no-runtime-no-pkgs{
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