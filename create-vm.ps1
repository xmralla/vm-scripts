
Set-PSDebug -Trace 2
Set-PSDebug -off
# Get-BitsTransfer | Remove-BitsTransfer
<# 
$hash = Get-FileHash $img
$grep = Get-Content $sum | Select-String -Pattern $img
$h1 = $hash.Hash.ToLower()
$h2 = $grep.ToString().Split(" ")[0].ToLower()
Write-Host "Comparing..."
Write-Host "  $h1"
Write-Host "  $h2"
if ( $h1 -eq $h2 ) {
    Write-Host "same"
} else {
    Write-Host "different"
    Download-Img
}

#>

# Define the switch name
$Switch = "Default Switch"

# Define the VM name suffix
$nodes    = "Master", "Node1", "Node2", "Node3", "Node4"
$cpuCount = 2,        1,       1,       1,       1
$ramSize  = 4GB

# Linux Image version
$version = "bionic"
$imgName = "$version-server-cloudimg-amd64"

# Tools
$qemuImgExe = "C:\qemu-img\qemu-img.exe"
$oscdImgExe = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"

# Image files
$img  = "$imgName.img"
$initImg = "$imgName.vhd"

# Cloud init path
$cloudInit = "cloud-init"

function Write-Duration {
    param($StartDate, $name)
    $EndDate = (GET-DATE)
    $spent = NEW-TIMESPAN -Start $StartDate -End $EndDate
    Write-Host "StartDate : '$StartDate'"
    Write-Host "EndDate   : '$EndDate'"
    Write-Host "$name : '$spent'"

}

function Linux-Name {
    param($name)

    if ($name -eq "bionic") { return "Ubuntu-18.04"}
    return "Linux"
}

function Download-Cloud-Img {
    $StartDate = (GET-DATE)
    $url = "https://cloud-images.ubuntu.com/$version/current/$img"
    $isReachable = Test-Connection -ComputerName $url -Quiet
    if (-not($isReachable)) {
        Write-Error "$url is not a valid URL"
        exit 1
    }
    $download = Start-BitsTransfer -Source $url -Destination $img -Asynchronous
    while ($download.JobState -ne "Transferred") { 
        [int] $dlProgress = ($download.BytesTransferred / $download.BytesTotal) * 100;
        Write-Progress -Activity "Downloading File: $url" -Status "$dlProgress% Complete:" -PercentComplete $dlProgress; 
    }
    Complete-BitsTransfer $download.JobId;
    Write-Duration  $StartDate "Download-Cloud-Img"
}

function Remove-Nodes {
    $StartDate = (GET-DATE)
    # Define the VM name prefix
    $VM = Linux-Name $version

    foreach ($node in $nodes) {
        # Define the VM name
        $name =  $VM + "-" + $node
        # Define the VM path
        $VMPath = "$PSScriptRoot\$name"

        try {
            # Delete VM
            $inst = Get-VM -Name $name -ErrorAction SilentlyContinue
            if ( $inst.Name -eq $name ) {
                Write-Host "Removing $inst"
                if ( $inst.State -eq "Running" ) {
                    Stop-VM -Passthru -Force -Name $name
                }
                if ( $inst.State -eq "Off" ) {
                    Remove-VM -Force -Name $name
                    if (Test-Path -Path $VMPath) {
                        Remove-Item -Recurse -Force $VMPath
                    }
                }
            }
        } catch {}
    }
    Write-Duration  $StartDate "Remove-Nodes"
}
function Update-File {
    param($file, $old, $new)
    ( Get-Content -Path $file ) |
        ForEach-Object {$_ -Replace $old, $new} |
            Set-Content -Path $file
}

function Create-Nodes {
    $StartDate = (GET-DATE)
    # Define the VM name prefix
    $VM = Linux-Name $version
    $i = 0
    foreach ($node in $nodes) {
        # Define the VM name
        $name =  $VM + "-" + $node
        # Define the VM path
        $vmPath = $PSScriptRoot

        # Creating a new VM
        Write-Host "Creating $name"
        New-VM -Name $name -MemoryStartupBytes $ramSize -Path $vmPath -Generation 2 -SwitchName $Switch
        $inst = Get-VM -Name $name
        $vmPath = $inst.Path
        $vhdxPath = "$vmPath\$name.vhd"
        $cidataPath = "$vmPath\$name-cidata.iso"
        $cloudInitPath = "$vmPath\cloud-init"
        Copy-Item -Recurse $cloudInit $cloudInitPath
        $hostname = $name.ToLower().Replace(".", "-")
        Update-File "$cloudInitPath\meta-data" "{hostname}" $hostname
        Update-File "$cloudInitPath\user-data" "{hostname}" $hostname

        Write-Host -ForegroundColor Green "Copying init disk from $initImg to $vhdxPath"
        Copy-Item $initImg $vhdxPath
        Add-VMHardDiskDrive -VMName $name -Path $vhdxPath

        Write-Host -ForegroundColor Green "Creating cloud init iso at $cidataPath"
        & $oscdImgExe -j2 -lcidata "$cloudInitPath" "$cidataPath"
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Unable to create cloud init disk"
            exit 1
        }
        
        Add-VMDvdDrive -VMName $name -Path $cidataPath

        # Configuring the boot order to DVD, VHD
        Set-VMFirmware -VMName $name -BootOrder $(Get-VMDvdDrive -VMName $name),$(Get-VMHardDiskDrive -VMName $name)
        Set-VMFirmware -VMName $name -EnableSecureBoot Off
        Set-VMMemory -VMName $name -DynamicMemoryEnabled $false
        Set-VMProcessor -VMName $name -Count $cpuCount[$i]
        $num = "{0:d2}" -f [int32]$i
        Set-VMNetworkAdapter -VMName $name -StaticMacAddress "00155d5810$num"
        Set-VM -Name $name -AutomaticCheckpointsEnabled $false
        $i = $i + 1
    }
    Write-Duration  $StartDate "Create-Nodes"
}

function Get-Nodes-IPs {
    # Define the VM name prefix
    $VM = Linux-Name $version
    $nodeIPs = @{}
    foreach ($node in $nodes) {
        # Define the VM name
        $name =  $VM + "-" + $node
        $IPs = Get-VM -VMName $name | Select-Object -ExpandProperty Networkadapters | Select-Object -Property IPAddresses
#        Write-Host $name " - " $IPs.IPAddresses[0]
        $ip = @{}
        $ip["ipv4"] = $IPs.IPAddresses[0]
        $nodeIPs[$name] = $ip
    }
    return  $nodeIPs
}

function Start-Nodes {
    $StartDate = (GET-DATE)
    # Define the VM name prefix
    $VM = Linux-Name $version
    foreach ($node in $nodes) {
        # Define the VM name
        $name =  $VM + "-" + $node
        Start-VM -VMName $name -Passthru
    }
    $do_break = $false
    while (-not($do_break)) {
        $do_break = $true
        foreach ($node in $nodes) {
            # Define the VM name
            $name =  $VM + "-" + $node
            $inst = Get-VM -VMName $name
            Write-Host $name " - "  $inst.state
            if ( -not($inst.State -eq "Running") ) {
                $do_break = $false
            }
            Start-Sleep -Milliseconds 500
        }           
    }
    Write-Duration  $StartDate "Start-Nodes"
}

function Wait-Network {
    $StartDate = (GET-DATE)
    $wait4ip = $true
    while($wait4ip) {
        $wait4ip = $false
        $addresses = Get-Nodes-IPs
        $addresses = [System.Collections.SortedList] $addresses
        foreach ($node in $addresses.Keys) {
            $count = $addresses[$node]["ipv4"].Count 
            Write-Host $node" IPv4 count="$count
            if ( $count -eq 1 ) {
                Write-Host $node $addresses[$node]["ipv4"]
            } else {
                $wait4ip = $true
            }
        }
        Start-Sleep -Milliseconds 1000
    }    
    Write-Duration  $StartDate "Wait-Network"
}

function Config-Masters {
    $StartDate = (GET-DATE)
    Write-Information "Configuring Masters"
    # Define the VM name prefix
    $VM = Linux-Name $version
    $i = 0
    $master_ip = ''
    $init = ''
    foreach ($node in $nodes) {
        if ( $node.contains("Master") ) {
            # Define the VM name
            $name =  $VM + "-" + $node
            $IPs = Get-VM -VMName $name | Select-Object -ExpandProperty Networkadapters | Select-Object -Property IPAddresses
            $ip = $IPs.IPAddresses[0]
            Write-Host "Master: "$name" - "$ip
            $res = ssh-keygen -R $ip
            $res = ssh -o StrictHostKeyChecking=accept-new  alx@$ip 'hostname'
            Write-Host "Master: '$res'"
            # Fisrt master node
            if ( $i -eq 0 ) {
                # Wait for control plane is up
                do {
                    $res = ssh alx@$ip '((tail -2 /kubeadm.log 2>/dev/null | grep \"^kubeadm join \" ) && (echo Done)) | grep Done'
                    Write-Host "kubeadm init: '$res'"
                }
                while( $res -ne 'Done' )
                
                do {
                    $res = ssh alx@$ip 'test -f /etc/kubernetes/admin.conf && echo Done'
                    Write-Host "kubernetes/admin.conf: '$res'"
                }
                while( $res -ne 'Done' )
                
                do {
                    Start-Sleep -Milliseconds 500
                    $res = Test-NetConnection -ComputerName $ip -Port 22
                } while ( -not $res.TcpTestSucceeded )
                    
                $res = ssh alx@$ip 'mkdir $HOME/.kube'
                Write-Host "mkdir .kube: '$res'"
                
                $res = ssh alx@$ip 'ls -la $HOME/.kube'
                Write-Host "ls .kube: '$res'"

                $res = ssh alx@$ip 'sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config'
                Write-Host "copy .kube/config: '$res'"

                $res = ssh alx@$ip 'ls -la $HOME/.kube'
                Write-Host "ls .kube: '$res'"

                $res = ssh alx@$ip 'sudo chown $(id -u):$(id -g) .kube/config'
                Write-Host "chown .kube/config: '$res'"

                $res = ssh alx@$ip 'ls -la $HOME/.kube'
                Write-Host "ls .kube: '$res'"

                do {
                    $res = ssh alx@$ip '((kubectl cluster-info | grep \"control plane.* is running at .*:6443\") && (echo Done)) | grep Done'
                    Write-Host "kubeadm cluster-info: $res"
                } while( $res -ne "Done")


                #Apply Calico CNI
                $res = ssh alx@$ip 'sudo kubectl apply -f /calico.yaml'
                Write-Host "apply calico.yaml: '$res'"

                $init = ssh alx@$ip 'tail -2 /kubeadm.log'
                Write-Host "Master join: '$init'"
                $init  = "sudo " + $init.Replace(" \", "") -replace ("\s+", " ")
                Write-Host "Master join: '$init'"
                $master_ip = $ip
            }
        }
    }
    Write-Duration  $StartDate "Config-Masters"
    
    return $master_ip, $init
}

function Config-Nodes {
    param($master_ip, $init)

    $StartDate = (GET-DATE)
    Write-Host "Configuring Nodes: join master - '$master_ip'"
    # Define the VM name prefix
    $VM = Linux-Name $version
    foreach ($node in $nodes) {
        if ( $node.contains("Node") ) {
            # Define the VM name
            $name =  $VM + "-" + $node
            $IPs = Get-VM -VMName $name | Select-Object -ExpandProperty Networkadapters | Select-Object -Property IPAddresses
            $ip = $IPs.IPAddresses[0]
            Write-Host "Node: "$name" - "$ip
            $res = ssh-keygen -R $ip
            $res = ssh -o StrictHostKeyChecking=accept-new  alx@$ip 'hostname'
            Write-Host "Node: '$res'"
            $res = ssh alx@$ip "$init"
            Write-Host "Node: '$res'"
        }
    }
    ssh alx@$master_ip 'kubectl get nodes'
    Write-Duration  $StartDate "Config-Nodes"
}

###############################################################################
# main
###############################################################################

# Check access rights
#S-1-5-32-544 is the well known sid for administrators,
#S-1-5-32-578 is the well known sid for hyper-v administrators
if ((-not (([System.Security.Principal.WindowsIdentity]::GetCurrent()).groups -match "S-1-5-32-544")) `
    -and (-not (([System.Security.Principal.WindowsIdentity]::GetCurrent()).groups -match "S-1-5-32-578"))) {
    Write-Error "This script must be ran as an administrator"
}

# Check qemu-img.exe 
if (-not(Test-Path -Path $qemuImgExe -PathType Leaf)) {
    Write-Error "$qemuImgExe is not a valid"
    exit 1
}

# Check oscdimg.exe
if (-not(Test-Path -Path $oscdImgExe -PathType Leaf)) {
    Write-Error "$oscdImgExe is not a valid"
    exit 1
}

# Download cloud QEMU image and make init VHDX file
if (-not(Test-Path -Path $initImg -PathType Leaf)) {
    if (-not(Test-Path -Path $img -PathType Leaf)) {
        Download-Cloud-Img
    }
    & $qemuImgExe convert -f qcow2 $img -O vpc -o subformat=dynamic $initImg
    Resize-VHD -Path $initImg -SizeBytes 16GB
}

# Check init VHDX file
$vhdx = Get-VHD -Path $initImg -ErrorAction SilentlyContinue
if (-not($vhdx)) {
    Write-Error "$initImg is not a valid VHDX"
    exit 1
}
Write-Host "$initImg is $vhdx"

Remove-Nodes
Create-Nodes
Start-Nodes
Wait-Network
($master_ip, $init) = Config-Masters


ssh $master_ip ifconfig
ssh $master_ip kubectl get nodes -o wide
ssh $master_ip kubectl get pods -A -o wide
Config-Nodes $master_ip $init
