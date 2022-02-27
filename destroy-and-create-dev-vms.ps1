# Shutdown VMs, then create new ones

$windows_dev_desktops = 'devwindows10', 'devwindows11'
$ubuntu_dev_desktops = 'devubuntu1', 'devubuntu2'
$cluster = 'homecluster'
$folder = 'Desktops'
$windows10template = 'template-devwindows10'
$windows11template = 'template-devwindows11'
$ubuntutemplate = 'template-ubuntudesktop'
$windowsdatastore = 'rack-physical-nvme'
$ubuntudatastore = 'rack-physical-ssd0'

$credential = Import-Clixml -Path C:\Credential\a-wiselan.cred
$linux_creds = Import-Clixml -Path C:\Credential\linux.cred
#Set-PowerCLIConfiguration -InvalidCertificateAction ignore
Connect-VIServer -Server 192.168.20.2 -Credential $credential

function Stop-DeveloperVMs {
    param(
        $DeveloperVMs
    )
    # Try to gracefully stop the vms
    foreach ($vm in $DeveloperVMs){
        Shutdown-VMGuest -VM $vm -Confirm:$False 
    }
    # force them to turn off
    foreach ($vm in $DeveloperVMs){
        Stop-VM -VM $vm -Confirm:$False 
    }
}

function Remove-DeveloperVMs {
    param(
        $DeveloperVMs
    )
    # Try to gracefully stop the vms
    foreach ($VM in $DeveloperVMs){
        Remove-VM -VM $vm -DeletePermanently -Confirm:$False 
    }
}

function New-DeveloperVM {
    param($Hostname, $DataStore, $Template, $Cluster, $Folder, $AddNetwork)

    New-VM -Name $Hostname -Datastore $DataStore -Template $Template  -ResourcePool $Cluster -Location $Folder 
    if($AddNetwork) {
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

    # update GPOs
    Invoke-Command -ComputerName $VM -ScriptBlock {gpupdate /force /boot}

    # install choco
    Set-ExecutionPolicy Bypass -Scope Process -Force; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
    choco feature enable -n allowGlobalConfirmation

    # install vmware tools
    choco install vmware-tools

    # install Puppet
    choco install puppet-agent --force

    Restart-VM -VM $VM -Confirm:$False

}

function Intialize-DeveloperVMsLinux {
  param($VM)

  $s = New-PSSession -HostName $VM -Credential $linux_creds

  Invoke-SudoCommand -Session $s -Command "wget https://apt.puppet.com/puppet7-release-focal.deb -P /tmp"
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

function Invoke-SudoCommand {
<#
.SYNOPSIS
Invokes sudo command in a remote session to Linux
#>
    param (
        [Parameter(Mandatory=$true)]
        [PSSession]
        $Session,

        [Parameter(Mandatory=$true)]
        [String]
        $Command
    )
    Invoke-Command -Session $Session {
        $errFile = "/tmp/$($(New-Guid).Guid).err"
        Invoke-Expression "sudo ${using:Command} 2>${errFile}" -ErrorAction Stop
        $err = Get-Content $errFile -ErrorAction SilentlyContinue
        Remove-Item $errFile -ErrorAction SilentlyContinue
        If (-Not $null -eq $err)
        {
            throw $err
        }
    }
}

$DeveloperVMs = 'devwindows10', 'devwindows11', 'devubuntu'

Stop-DeveloperVMs -DeveloperVMs $DeveloperVMs
Remove-DeveloperVMs -DeveloperVMs $DeveloperVMs
# TODO: Add Cert Clean from Puppet
foreach ($vm in $DeveloperVMs) {
    New-DeveloperVM -Hostname $vm -DataStore $windowsdatastore -Template "template-${vm}" -Cluster $cluster -Folder $folder -AddNetwork true
}
Start-DeveloperVMs -DeveloperVMs $DeveloperVMs
Initialize-DeveloperVMs -DeveloperVMs $DeveloperVMs
