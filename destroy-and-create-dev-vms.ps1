# Shutdown VMs, then create new ones


function Stop-DeveloperVMs {
    param(
        $DeveloperVMs
    )
    # Not concerned with hard shutdowns because it will get rebuilt
    foreach ($vm in $DeveloperVMs){
      $powerstate = (Get-VM -Name $vm).ExtensionData.guest.guestState
      if ($powerstate -like 'off') {
        Write-Host $vm + ' is off. moving on...'
      } else {
        Stop-VM -VM $vm -Confirm:$False
      }     
    }
}

function Remove-DeveloperVMs {
    param(
        $DeveloperVMs
    )
    # Delete the VMs
    foreach ($VM in $DeveloperVMs){
      # Extra check for powerstate
      $powerstate = (Get-VM -Name $vm).ExtensionData.guest.guestState
      if ($powerstate -like 'on') {
        Stop-VM -VM $vm -Confirm:$False
      } 
      
      Remove-VM -VM $vm -DeletePermanently -Confirm:$False 
    }
}

function Invoke-SudoVMScript {
  param($VM, $ScriptText, $GuestCredential)
  $sudo_password = $GuestCredential.GetNetworkCredential().password
  $st = 'sudo -S <<< "' + $sudo_password + '" sudo ' + $ScriptText
  Invoke-VMScript -VM $VM -ScriptText $st -GuestCredential $GuestCredential
}

# The Certs Need cleaned and the nodes removed from PuppetDB, so they can
# be re-created
function Clear-PuppetCerts {
    param($DeveloperVMs)
    $sudo_password = $linux_creds.GetNetworkCredential().password
    foreach ($vm in $DeveloperVMs) {
        $puppet_cert_clean = 'puppetserver ca clean --certname ' + $vm + ' ' + $vm + '.thewisemans.io ' + $vm +'.'
        $puppet_db_remove  = 'puppet node deactivate ' + $vm + ' ' + $vm + '.thewisemans.io ' + $vm +'.'
        
        Invoke-SudoVMScript -VM 'puppetserver' -ScriptText $puppet_cert_clean -GuestCredential $linux_creds
        Invoke-SudoVMScript -VM 'puppetserver' -ScriptText $puppet_db_remove -GuestCredential $linux_creds
    }
}



function New-DeveloperVM {
    param($Hostname, $DataStore, $Template, $Cluster, $Folder, $AddNetwork)

    New-VM -Name $Hostname -Datastore $DataStore -Template $Template  -ResourcePool $Cluster -Location $Folder 
    if($AddNetwork) {
        Start-Sleep -Seconds 125
        Get-VM $Hostname | New-NetworkAdapter -NetworkName "VM Network" -WakeOnLan -StartConnected -Type Vmxnet3
    }

}

function Start-DeveloperVMs {
    param(
        $DeveloperVMs
    )
   
    foreach ($VM in $DeveloperVMs){
        Start-VM -VM $vm -Confirm:$False 
    }
}

function Initialize-DeveloperVMs {
    param(
        $DeveloperVMs,
        $PuppetScriptFile
    )
    
    foreach ($vm in $DeveloperVMs){        
        $GuestType = (Get-VM $vm).ExtensionData.Config.GuestFullName
        Write-Host $GuestType

        switch -regex ($GuestType) {
            ".*Windows.*" {
                Initialize-DeveloperVMsWindows -VM $vm -PuppetScriptFile $PuppetScriptFile
             }
            ".*Linux.* "{
              Initialize-DeveloperVMsLinux -VM $vm -PuppetScriptFile $PuppetScriptFile
            }
        } 
  }  
    
}

function Initialize-DeveloperVMsWindows {
    param(
      $VM,
      $PuppetScriptFile
      ) 
    $windows_creds  = Import-Clixml -Path C:\Credential\windows.cred
    Copy-VMGuestFile -Source $PuppetScriptFile -Destination C:\temp\ `
            -VM $VM -LocalToGuest -HostCredential $windows_creds `
            -GuestCredential $windows_creds
    $run_script = 'C:\temp\' + $PuppetScriptFile
    Invoke-VMScript -VM $VM -ScriptText $run_script -GuestCredential $windows_creds
}

function Initialize-DeveloperVMsLinux {
  param(
    $VM,
    $PuppetScriptFile
    )
  
  $linux_creds = Import-Clixml -Path C:\Credential\linux.cred
  $windows_creds  = Import-Clixml -Path C:\Credential\windows.cred
  Copy-VMGuestFile -Source $PuppetScriptFile -Destination /tmp/ `
            -VM $VM -LocalToGuest -HostCredential $windows_creds `
            -GuestCredential $linux_creds
  $chmod_script = 'chmod +x /tmp/' + $PuppetScriptFile
  $run_script   = '/tmp/' + $PuppetScriptFile
  
  Invoke-SudoVMScript -VM $VM -ScriptText $chmod_script -GuestCredential $linux_creds
  Invoke-SudoVMScript -VM $VM -ScriptText $run_script -GuestCredential $linux_creds

}


$credential = Import-Clixml -Path C:\Credential\a-wiselan.cred
$linux_creds = Import-Clixml -Path C:\Credential\linux.cred
$install_script_url = Get-Content -Path C:\Credential\gist-url.txt
$windows_creds = Import-Clixml -Path C:\Credential\windows.cred

#Set-PowerCLIConfiguration -InvalidCertificateAction ignore
Connect-VIServer -Server 192.168.20.2 -Credential $credential

$devVMsJson = Get-Content .\developer-vms.json -Raw | ConvertFrom-Json 

foreach ($devVM in $devVMsJson) {
  Stop-DeveloperVMs -DeveloperVMs $devVM.vmname
  Remove-DeveloperVMs -DeveloperVMs $devVM.vmname
  Clear-PuppetCerts -DeveloperVMs $devVM.vmname
  New-DeveloperVM -Hostname $devVM.vmname -DataStore $devVM.datastore `
                  -Template $devVM.template -Cluster $devVM.cluster `
                  -Folder $devVM.folder -AddNetwork true
  Start-Sleep -Seconds 20
  Start-DeveloperVMs -DeveloperVMs $devVM.vmname
  Initialize-DeveloperVMs -DeveloperVMs $devVM.vmname -PuppetScriptFile $devVM.puppet_script
}

