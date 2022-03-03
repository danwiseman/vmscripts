# Developer VM Creation Scripts

This is a simple PowerCLI implementation to destroy and rebuild developer virtual 
machines. It will eventually be automated as a scheduled task to complete this on
Sunday nights.

VM Details are inside the json file. Puppet Scripts will be transfered over to the VM
after creation, and run to generate the required configuration.

Example JSON:

```json
  [{
    "vmname": "devwindows10",
    "datastore": "rack-physical-nvme",
    "network": "VM Network",
    "template": "template-devwindows10",
    "folder": "Desktops",
    "cluster": "homecluster",
    "puppet_script":"puppet-script-win10.ps1"
  }]
```

