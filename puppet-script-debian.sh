#!/bin/bash

rm -rf /tmp/puppet7-release-focal.deb
wget https://apt.puppet.com/puppet7-release-focal.deb -P /tmp
dpkg -i /tmp/puppet7-release-focal.deb
apt-get update -y
echo "192.168.20.25  puppet.thewisemans.io puppet" >> /etc/hosts
apt-get install -y puppet-agent
/opt/puppetlabs/bin/puppet agent --waitforcert 140 