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
        $DeveloperVMs
    )
    
    foreach ($vm in $DeveloperVMs){
        $mac_address = Get-VM $vm | Get-NetworkAdapter | select -ExpandProperty MacAddress 
        Invoke-WakeOnLan -MacAddress $mac_address
        
        $GuestType = (Get-VM $vm).ExtensionData.Config.GuestFullName
        Write-Host $GuestType

        switch -regex ($GuestType) {
            ".*Windows.*" {
                Initialize-DeveloperVMsWindows -VM $vm
             }
            ".*Linux.* "{
              Initialize-DeveloperVMsLinux -VM $vm
            }
        } 
  }  
    
}

function Initialize-DeveloperVMsWindows {
    param($VM) 
    $windows_creds = Import-Clixml -Path C:\Credential\windows.cred
    # update GPOs
    $update_gpos = "gpupdate /force /boot"
    $choco_install = "Set-ExecutionPolicy Bypass -Scope Process -Force; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))"
    $choco_puppet = "choco install puppet-agent --force"
    $run_puppet = "puppet agent"
    Invoke-VMScript -VM $VM -ScriptText $update_gpos -GuestCredential $windows_creds
    Invoke-VMScript -VM $VM -ScriptText $choco_install -GuestCredential $windows_creds
    Invoke-VMScript -VM $VM -ScriptText $choco_puppet -GuestCredential $windows_creds
    Invoke-VMScript -VM $VM -ScriptText $run_puppet -GuestCredential $windows_creds

}

function Initialize-DeveloperVMsLinux {
  param($VM)
  # TODO: make this more than just DEBIAN
  # TODO: change this from a wget to just a VM upload
  $linux_creds = Import-Clixml -Path C:\Credential\linux.cred
  $sudo_password = $linux_creds.GetNetworkCredential().password
  $delete_script = 'rm -rf /tmp/install-puppet.sh'
  $set_host_name = 'hostnamectl set-hostname ' + $VM
  $puppet_script_dl = "wget " + $install_script_url + " -P /tmp"
  $puppet_bash = 'chmod +x /tmp/install-puppet.sh'
  $puppet_script_run = '/tmp/install-puppet.sh'
  Invoke-SudoVMScript -VM $VM -ScriptText $delete_script -GuestCredential $linux_creds
  Invoke-SudoVMScript -VM $VM -ScriptText $set_host_name -GuestCredential $linux_creds
  Invoke-SudoVMScript -VM $VM -ScriptText $puppet_script_dl -GuestCredential $linux_creds
  Invoke-SudoVMScript -VM $VM -ScriptText $puppet_bash -GuestCredential $linux_creds
  Invoke-SudoVMScript -VM $VM -ScriptText $puppet_script_run -GuestCredential $linux_creds

}


function Invoke-WakeOnLan
{
  param
  (
    # one or more MACAddresses
    [Parameter(Mandatory,ValueFromPipeline,ValueFromPipelineByPropertyName)]
    # mac address must be a following this regex pattern:
    [ValidatePattern('^([0-9A-F]{2}[:-]){5}([0-9A-F]{2})$')]
    [string[]]
    $MacAddress 
  )
 
  begin
  {
    # instantiate a UDP client:
    $UDPclient = [System.Net.Sockets.UdpClient]::new()
  }
  process
  {
    foreach($_ in $MacAddress)
    {
      try {
        $currentMacAddress = $_
        
        # get byte array from mac address:
        $mac = $currentMacAddress -split '[:-]' |
          # convert the hex number into byte:
          ForEach-Object {
            [System.Convert]::ToByte($_, 16)
          }
 
        #region compose the "magic packet"
        
        # create a byte array with 102 bytes initialized to 255 each:
        $packet = [byte[]](,0xFF * 102)
        
        # leave the first 6 bytes untouched, and
        # repeat the target mac address bytes in bytes 7 through 102:
        6..101 | Foreach-Object { 
          # $_ is indexing in the byte array,
          # $_ % 6 produces repeating indices between 0 and 5
          # (modulo operator)
          $packet[$_] = $mac[($_ % 6)]
        }
        
        #endregion
        
        # connect to port 400 on broadcast address:
        $UDPclient.Connect(([System.Net.IPAddress]::Broadcast),4000)
        
        # send the magic packet to the broadcast address:
        $null = $UDPclient.Send($packet, $packet.Length)
        Write-Verbose "sent magic packet to $currentMacAddress..."
      }
      catch 
      {
        Write-Warning "Unable to send ${mac}: $_"
      }
    }
  }
  end
  {
    # release the UDF client and free its memory:
    $UDPclient.Close()
    $UDPclient.Dispose()
  }
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
  New-DeveloperVM -Hostname $devVM.vmname -DataStore $devVM.datastore 
                  -Template $devVM.template -Cluster $devVM.cluster 
                  -Folder $devVM.folder -AddNetwork true
  Start-Sleep -Seconds 20
  Start-DeveloperVMs -DeveloperVMs $devVM.vmname
  Initialize-DeveloperVMs -DeveloperVMs $devVM.vmname
}

