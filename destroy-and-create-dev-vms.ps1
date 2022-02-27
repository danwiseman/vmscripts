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

# shutdown linux
foreach ($vm in $ubuntu_dev_desktops){
    Shutdown-VMGuest -VM $vm -Confirm:$False 
}

#shutdown windows
foreach ($vm in $windows_dev_desktops){
    Shutdown-VMGuest -VM $vm -Confirm:$False 
}

Start-Sleep -Seconds 60

# shutdown linux
foreach ($vm in $ubuntu_dev_desktops){
    Stop-VM -VM $vm -Confirm:$False 
}

#shutdown windows
foreach ($vm in $windows_dev_desktops){
    Stop-VM -VM $vm -Confirm:$False 
}

Start-Sleep -Seconds 60

# delete
# shutdown linux
foreach ($vm in $ubuntu_dev_desktops){
    Remove-VM -VM $vm -DeletePermanently -Confirm:$False 
}

#shutdown windows
foreach ($vm in $windows_dev_desktops){
    Remove-VM -VM $vm -DeletePermanently -Confirm:$False 
}

# create vms
# shutdown linux
foreach ($vm in $ubuntu_dev_desktops){
    Write-Warning "Creating $($vm) in $($cluster)"
    New-VM -Name $vm -Datastore $ubuntudatastore -Template $ubuntutemplate  -ResourcePool $cluster -Location $folder -OSCustomizationSpec 'ubuntu'
}

New-VM -Name 'devwindows10' -Datastore $windowsdatastore -Template $windows10template  -ResourcePool $cluster -Location $folder 
New-VM -Name 'devwindows11' -Datastore $windowsdatastore -Template $windows11template  -ResourcePool $cluster -Location $folder
foreach ($vm in $windows_dev_desktops){
    Get-VM $vm | New-NetworkAdapter -NetworkName "VM Network" -WakeOnLan -StartConnected -Type Vmxnet3 
}

foreach ($vm in $ubuntu_dev_desktops){
    Get-VM $vm | New-NetworkAdapter -NetworkName "VM Network" -WakeOnLan -StartConnected -Type Vmxnet3 
}

# turn on linux
foreach ($vm in $ubuntu_dev_desktops){
    Start-VM -VM $vm -Confirm:$False 
}

#turn on windows
foreach ($vm in $windows_dev_desktops){
    Start-VM -VM $vm -Confirm:$False 
}

Start-Sleep -Seconds 300

## Install everything on windows ##
foreach ($vm in $windows_dev_desktops){
    Invoke-Command -ComputerName $vm -ScriptBlock {gpupdate /force /boot} 
}

foreach ($vm in $windows_dev_desktops){
    Restart-VM -VM $vm -Confirm:$False
    }

Start-Sleep -Seconds 30

Invoke-Command -ComputerName $windows_dev_desktops -ScriptBlock {
    Set-ExecutionPolicy Bypass -Scope Process -Force; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
    choco feature enable -n allowGlobalConfirmation
    }

    

Invoke-Command -ComputerName $windows_dev_desktops -ScriptBlock {
    choco install vmware-tools
    
    }
foreach ($vm in $windows_dev_desktops){
    Restart-VM -VM $vm -Confirm:$False
    }

    Start-Sleep -Seconds 130

    Invoke-Command -ComputerName $windows_dev_desktops -ScriptBlock {
        choco install puppet-agent --force
        set PATH=%PATH%;"C:\Program Files\Puppet Labs\Puppet\bin"
        puppet agent -t
    
    }
