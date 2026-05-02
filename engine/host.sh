#!/bin/bash

VBoxManage startvm Dirty-2
running=$( VBoxManage showvminfo Dirty-2 | grep -c "running (since" )
echo "running Dirty"
while [ "$running" = "1" ]
do
	sleep 30
	running=$( VBoxManage showvminfo Dirty-2 | grep -c "running (since" )
done

VBoxManage startvm Clean-2
echo "running Clean"
running=$( VBoxManage showvminfo Clean-2 | grep -c "running (since" )
while [ "$running" = "1" ]
do
	sleep 30
	running=$( VBoxManage showvminfo Clean-2 | grep -c "running (since" )
done

echo "Replacing Dirty with Clean..."
VBoxManage storageattach Dirty-2 --storagectl SATA --port 0 --medium none
VBoxManage closemedium disk ~/VirtualBox\ VMs/Dirty-2/Dirty-2.vhd --delete
VBoxManage clonemedium ~/VirtualBox\ VMs/Clean-2/Clean-2.vhd ~/VirtualBox\ VMs/Dirty-2/Dirty-2.vhd --format VHD
VBoxManage storageattach Dirty-2 --storagectl SATA --port 0 --type HDD --medium ~/VirtualBox\ VMs/Dirty-2/Dirty-2.vhd

rm -rf ~/dest/*
