$Logfile = "./$(hostname).log"

#Function to write to log file
Function LogWrite
{
Param ([string]$logstring, [string] $echoToConsole=$false)
    if ($echoToConsole -eq $true) {
        Write-Host $logstring
    }
    Add-content $Logfile -value $logstring
}

#===============================================
# Scriptblock Util functions
#===============================================

$ScriptBlockEnableToolPermissions = {
    param ($remoteToolPath)
    chmod 777 $remoteToolPath
} # $ScriptBlockEnableToolPermissions()

$ScriptBlockCleanupFirewallRules = {
    param($port, $creds)
    Write-Output $creds.GetNetworkCredential().Password | sudo -S ufw delete allow $port | Out-Null
} # $ScriptBlockCleanupFirewallRules()

$ScriptBlockEnableFirewallRules = {
    param ($port, $creds)
    Write-Output $creds.GetNetworkCredential().Password | sudo -S ufw allow $port | Out-Null
} # $ScriptBlockEnableFirewallRules()

$ScriptBlockTaskKill = {
    param ($taskname)
    $taskStatus = pidof $taskname
    if (![string]::IsNullOrEmpty($taskStatus)) {
        killall $taskname | Out-Null
    }
} # $ScriptBlockTaskKill()

# Set up a directory on the remote machines for results gathering.
$ScriptBlockCreateDirForResults = {
    param ($Cmddir)
    $Exists = Test-Path $Cmddir | Out-Null
    if (!$Exists) {
        New-Item -ItemType Directory -Force -Path "$Cmddir" | Out-Null
    }
    return $Exists
} # $ScriptBlockCreateDirForResults()


# Delete file/folder on the remote machines 
$ScriptBlockRemoveFileFolder = {
    param ($Arg)
    Remove-Item -Force -Path "$Arg" -Recurse -ErrorAction SilentlyContinue
} # $ScriptBlockRemoveFileFolder()


# Delete the entire folder (if empty) on the remote machines
$ScriptBlockRemoveFolderTree = {
    param ($Arg)

    $parentfolder = (Get-Item $Arg).Parent.FullName

    # First do as instructed. Remove-Item $arg.
    Remove-Item -Force -Path "$Arg" -Recurse -ErrorAction SilentlyContinue

    # We dont know how many levels of parent folders were created so we will keep navigating upward till we find a non empty parent directory and then stop
    $folderCount = $parentfolder.Split('/').count 

    for ($i=1; $i -le $folderCount; $i++) {

        $folderToDelete = $parentfolder

        #Extract parent info before nuking the folder
        $parentfolder = (Get-Item $folderToDelete).Parent.FullName

           
        #check if the folder is empty and if so, delete it
        if ((dir -Directory $folderToDelete | Measure-Object).Count -eq 0) {
            Remove-Item -Force -Path "$folderToDelete" -Recurse -ErrorAction SilentlyContinue
        }
        else
        { 
            #Folder/subfolder wasnt found empty. so we stop here and exit
            break
        }

    }

} # $ScriptBlockRemoveFolderTree ()

$ScriptBlockCreateZip = {
    Param(
        [String] $Src,
        [String] $Out
    )

    if (Test-path $Out) {
        Remove-item $Out 
    }

    zip -r $Out $Src | Out-Null
} # $ScriptBlockCreateZip()

$ScriptBlockRemoveAuthorizedHost = {
    head -n -1 ".ssh/authorized_keys" | Out-Null
} # $ScriptBlockRemoveAuthorizedHost

$ScriptBlockRemoveBinaries = {
    param($remoteToolPath)
    Remove-Item -Path $remoteToolPath -Force -ErrorAction SilentlyContinue
} # $ScriptBlockRemoveBinaries

<#
.SYNOPSIS
    This function reads an input file of commands and orchestrates the execution of these commands on remote machines.

.PARAMETER DestIp
    Required Parameter. The IpAddr of the destination machine that's going to receive data for the duration of the throughput tests

.PARAMETER SrcIp
    Required Parameter. The IpAddr of the source machine that's going to be sending data for the duration of the throughput tests

.PARAMETER DestIpUserName
    Required Parameter. Gets domain\username needed to connect to DestIp Machine

.PARAMETER DestIpPassword
    Required Parameter. Gets password needed to connect to DestIp Machine. 
    Password will be stored as Secure String and chars will not be displayed on the console.

.PARAMETER SrcIpUserName
    Required Parameter. Gets domain\username needed to connect to SrcIp Machine

.PARAMETER SrcIpPassword
    Required Parameter. Gets password needed to connect to SrcIp Machine. 
    Password will be stored as Secure String and chars will not be displayed on the console

.PARAMETER CommandsDir
    Required Parameter that specifies the location of the folder with the auto generated commands to run.

.PARAMETER BCleanup
    Optional parameter that will clean up the source and destination folders, after the test run, if set to true.
    If false, the folders that were created to store the results will be left untouched on both machines
    Default value: $True

.PARAMETER ZipResults
    Optional parameter that will compress the results folders before copying it over to the machine that's triggering the run.
    If false, the result folders from both Source and Destination machines will be copied over as is.
    Default value: $True

.PARAMETER TimeoutValueInSeconds
    Optional parameter to configure the amount of wait time (in seconds) to allow each command pair to gracefully exit 
    before cleaning up and moving to the next set of commands
    Default value: 90 seconds

.DESCRIPTION
    Please run SetupTearDown.ps1 -Setup on the DestIp and SrcIp machines independently to help with PSRemoting setup
    This function is dependent on the output of PERFTEST.PS1 function
    for example, PERFTEST.PS1 is invoked with DestIp, SrcIp and OutDir.
    to invoke the commands that were generated above, we pass the same parameters to ProcessCommands function
    Note that we expect the directory to be pointing to the folder that was generated by perftest.ps1 under the outpurDir path supplied by the user
    Ex: ProcessCommands -DestIp "$DestIp" -SrcIp "$SrcIp" -CommandsDir "temp\msdbg.Machine1.perftest" -DestIpUserName "domain\username" -SrcIpUserName "domain\username"
    You may chose to run SetupTearDown.ps1 -Cleanup if you wish to clean up any config changes from the Setup step
#>
Function ProcessCommands{
    param(
    [Parameter(Mandatory=$True)]  [string]$DestIp,
    [Parameter(Mandatory=$True)] [string]$SrcIp,
    [Parameter(Mandatory=$True)]  [string]$CommandsDir,
    [Parameter(Mandatory=$True, Position=0, HelpMessage="Dest Machine Username?")]
    [string] $DestIpUserName,
    [Parameter(Mandatory=$True, Position=0, HelpMessage="Dest Machine Password?")]
    [SecureString]$DestIpPassword,
    [Parameter(Mandatory=$True, Position=0, HelpMessage="Src Machine Username?")]
    [string] $SrcIpUserName,
    [Parameter(Mandatory=$True, Position=0, HelpMessage="Src Machine Password?")]
    [SecureString]$SrcIpPassword,
    [Parameter(Mandatory=$False)] [string]$Bcleanup=$True,
    [Parameter(Mandatory=$False)]$ZipResults=$True,
    [Parameter(Mandatory=$False)]$TimeoutValueInSeconds=90
    )

    $recvComputerName = $DestIp
    $sendComputerName = $SrcIp

    [PSCredential] $sendIPCreds = New-Object System.Management.Automation.PSCredential($SrcIpUserName, $SrcIpPassword)

    [PSCredential] $recvIPCreds = New-Object System.Management.Automation.PSCredential($DestIpUserName, $DestIpPassword)

    LogWrite "Processing ntttcp commands for Linux" $true
    ProcessToolCommands -Toolname "ntttcp" -RecvComputerName $recvComputerName -RecvComputerCreds $recvIPCreds -SendComputerName $sendComputerName -SendComputerCreds $sendIPCreds -CommandsDir $CommandsDir -Bcleanup $Bcleanup -BZip $ZipResults -TimeoutValueBetweenCommandPairs $TimeoutValueInSeconds

    LogWrite "Processing lagscope commands for Linux" $true
    ProcessToolCommands -Toolname "lagscope" -RecvComputerName $recvComputerName -RecvComputerCreds $recvIPCreds -SendComputerName $sendComputerName -SendComputerCreds $sendIPCreds -CommandsDir $CommandsDir -Bcleanup $Bcleanup -BZip $ZipResults -TimeoutValueBetweenCommandPairs $TimeoutValueInSeconds

    LogWrite "ProcessCommands Done!" $true
    Move-Item -Path $Logfile -Destination "$CommandsDir" -ErrorAction Ignore

} # ProcessCommands()


#===============================================
# Internal Functions
#===============================================

<#
.SYNOPSIS
    This function reads an input file of commands and orchestrates the execution of these commands on remote machines.

.PARAMETER RecvComputerName
    The IpAddr of the destination machine that's going to play the Receiver role and wait to receive data for the duration of the throughput tests

.PARAMETER SendComputerName
    The IpAddr of the sender machine that's going to send data for the duration of the throughput tests

.PARAMETER CommandsDir
    The location of the folder that's going to have the auto generated commands for the tool.

.PARAMETER Toolname
    Default value: ntttcp. The function parses the Send and Recv files for the tool specified here
    and reads the commands and executes them on the SrcIp and DestIp machines

.PARAMETER bCleanup
    Required parameter. The function creates folders and subfolders on remote machines to house the result files of the individual commands. bCleanup param decides 
    if the folders should be left as is, or if they should be cleaned up

.PARAMETER SendComputerCreds
    Optional PSCredentials to connect to the Sender machine

.PARAMETER RecvComputerCreds
    Optional PSCredentials to connect to the Receiver machine

.PARAMETER BZip
    Required parameter. The function creates folders and subfolders on remote machines to house the result files of the individual commands. BZip param decides 
    if the folders should be compressed or left uncompressed before copying over.

.PARAMETER TimeoutValueBetweenCommandPairs
    Optional parameter to configure the amount of time the tool waits (in seconds) between command pairs before moving to the next set of commands

#>
Function ProcessToolCommands{
    param(
        [Parameter(Mandatory=$True)] [string]$RecvComputerName,
        [Parameter(Mandatory=$True)] [string]$SendComputerName,
        [Parameter(Mandatory=$True)] [string]$CommandsDir,
        [Parameter(Mandatory=$True)] [string]$Bcleanup, 
        [Parameter(Mandatory=$False)] [string]$Toolname = "ntttcp", 
        [Parameter(Mandatory=$False)] [PSCredential] $SendComputerCreds = [System.Management.Automation.PSCredential]::Empty,
        [Parameter(Mandatory=$False)] [PSCredential] $RecvComputerCreds = [System.Management.Automation.PSCredential]::Empty,
        [Parameter(Mandatory=$True)] [bool]$BZip,
        [Parameter(Mandatory=$False)] [int] $TimeoutValueBetweenCommandPairs = 60
        )
        [bool] $gracefulCleanup = $False
    
        [System.IO.TextReader] $recvCommands = $null
        [System.IO.TextReader] $sendCommands = $null
    
        $toolpath = "./{0}" -f $Toolname
    
        $homePath = $HOME
        $keyFilePath = "$homePath/.ssh/netperf_rsa"
        $pubKeyFilePath = "$homePath/.ssh/netperf_rsa.pub"

        LogWrite "Adding receiver and sender computer to known hosts"
        # add receiver and sender computer to known host of current computer
        ssh-keyscan -H -p 5985 $RecvComputerName >> "$homePath/.ssh/known_hosts"
        ssh-keyscan -H -p 5985 $SendComputerName >> "$homePath/.ssh/known_hosts"
        $sshCommandFilePath =  "$CommandsDir/sshCommand.txt"
        if ((Test-Path $keyFilePath) -eq $False) {
            LogWrite "Creating RSA public/private key pair"
            # generate public and private key for ssh specific for NetPerfTest
            if ((Test-Path "$homePath/.ssh") -eq $False) {
                New-Item -Path "$homePath/.ssh" -ItemType Directory
            }
            Write-Output $keyFilePath | ssh-keygen --% -q -t rsa -N ""
            chmod 600 $keyFilePath
        }
        # create command to copy public key to receiver and sender computer
        if ((Test-Path $sshCommandFilePath) -eq $True) {
            Remove-Item -Path $sshCommandFilePath -ErrorAction SilentlyContinue -Force
        }
        Add-Content -Path $sshCommandFilePath -Value ("umask 077; test -d .ssh || mkdir .ssh ; echo `"" + (Get-Content $pubKeyFilePath) + "`" >> .ssh/authorized_keys")
        chmod -R 777 $sshCommandFilePath 
        try {
            # Establish the Remote PS session with Receiver
            Write-Output "n" | plink -P 5985 $RecvComputerName -l $RecvComputerCreds.GetNetworkCredential().UserName -pw $RecvComputerCreds.GetNetworkCredential().Password -m $sshCommandFilePath | Out-Null
            # sleep for credentials to propagate 
            start-sleep -seconds 2
            $recvPSSession = New-PSSession -Port 5985 -HostName $RecvComputerName -UserName ($RecvComputerCreds.GetNetworkCredential().UserName) -KeyFilePath $keyFilePath
    
            if($recvPSsession -eq $null) {
                LogWrite "Error connecting to Host: $($RecvComputerName)"
                return 
            }
    
            # Establish the Remote PS session with Sender
            Write-Output "n" | plink -P 5985 $SendComputerName -l $SendComputerCreds.GetNetworkCredential().UserName -pw $SendComputerCreds.GetNetworkCredential().Password $sshCommandFilePath | Out-Null
            # sleep for credentials to propagate 
            start-sleep -seconds 2
            $sendPSSession = New-PSSession -Port 5985 -HostName $SendComputerName -UserName $SendComputerCreds.GetNetworkCredential().UserName -KeyFilePath $keyFilePath
        
            if($sendPSsession -eq $null) {
                LogWrite "Error connecting to Host: $($SendComputerName)"
                return
            }
    
            # Construct the input file to read for commands.
            $ToolnameUpper = $Toolname.ToUpper()
            $sendCmdFile = Join-Path -Path $CommandsDir -ChildPath "/$Toolname/$ToolnameUpper.Commands.Send.txt"
            $recvCmdFile = Join-Path -Path $CommandsDir -ChildPath "/$Toolname/$ToolnameUpper.Commands.Recv.txt"
    
            # Ensure that remote machines have the directory created for results gathering. 
            $recvFolderExists = Invoke-Command -Session $recvPSSession -ScriptBlock $ScriptBlockCreateDirForResults -ArgumentList ($CommandsDir)
            $sendFolderExists = Invoke-Command -Session $sendPSSession -ScriptBlock $ScriptBlockCreateDirForResults -ArgumentList ($CommandsDir)
    
            # Clean up the Receiver/Sender folders on remote machines, if they exist so that we dont capture any stale logs
            Invoke-Command -Session $recvPSSession -ScriptBlock $ScriptBlockRemoveFileFolder -ArgumentList "$CommandsDir/Receiver"
            Invoke-Command -Session $sendPSSession -ScriptBlock $ScriptBlockRemoveFileFolder -ArgumentList "$CommandsDir/Sender"
    
            #Create dirs and subdirs for each of the supported tools
            Invoke-Command -Session $recvPSSession -ScriptBlock $ScriptBlockCreateDirForResults -ArgumentList ($CommandsDir+"/Receiver/$Toolname/tcp")
            Invoke-Command -Session $sendPSSession -ScriptBlock $ScriptBlockCreateDirForResults -ArgumentList ($CommandsDir+"/Sender/$Toolname/tcp")
            Invoke-Command -Session $recvPSSession -ScriptBlock $ScriptBlockCreateDirForResults -ArgumentList ($CommandsDir+"/Receiver/$Toolname/udp")
            Invoke-Command -Session $sendPSSession -ScriptBlock $ScriptBlockCreateDirForResults -ArgumentList ($CommandsDir+"/Sender/$Toolname/udp")
    
            # Copy the tool binaries to the remote machines
            Copy-Item -Path "$toolpath/$Toolname" -Destination "$CommandsDir/Receiver/$Toolname" -ToSession $recvPSSession
            Copy-Item -Path "$toolpath/$Toolname" -Destination "$CommandsDir/Sender/$Toolname" -ToSession $sendPSSession
    
            # Enable execution of tool binaries 
            Invoke-Command -Session $recvPSSession -ScriptBlock $ScriptBlockEnableToolPermissions -ArgumentList "$CommandsDir/Receiver/$Toolname/$Toolname"
            Invoke-Command -Session $sendPSSession -ScriptBlock $ScriptBlockEnableToolPermissions -ArgumentList "$CommandsDir/Sender/$Toolname/$Toolname"
            
            # allow multiple ports in firewall
            Invoke-Command -Session $recvPSSession -ScriptBlock $ScriptBlockEnableFirewallRules -ArgumentList ("50000:50512/tcp", $RecvComputerCreds)
            Invoke-Command -Session $sendPSSession -ScriptBlock $ScriptBlockEnableFirewallRules -ArgumentList ("50000:50512/tcp", $SendComputerCreds)
            Invoke-Command -Session $recvPSSession -ScriptBlock $ScriptBlockEnableFirewallRules -ArgumentList ("50000:50512/udp", $RecvComputerCreds)
            Invoke-Command -Session $sendPSSession -ScriptBlock $ScriptBlockEnableFirewallRules -ArgumentList ("50000:50512/udp", $SendComputerCreds)
            
            # Kill any background processes related to tool in case previous run is still running
            Invoke-Command -Session $recvPSSession -ScriptBlock $ScriptBlockTaskKill -ArgumentList $Toolname
            Invoke-Command -Session $sendPSSession -ScriptBlock $ScriptBlockTaskKill -ArgumentList $Toolname

            $recvCommands = [System.IO.File]::OpenText($recvCmdFile)
            $sendCommands = [System.IO.File]::OpenText($sendCmdFile)
    
            while(($null -ne ($recvCmd = $recvCommands.ReadLine())) -and ($null -ne ($sendCmd = $sendCommands.ReadLine()))) {
    
                #change the command to add path to tool
                $recvCmd =  $recvCmd -ireplace [regex]::Escape("./$Toolname"), "$CommandsDir/$Toolname/$Toolname"
                $sendCmd =  $sendCmd -ireplace [regex]::Escape("./$Toolname"), "$CommandsDir/$Toolname/$Toolname"
    
                # Work here to invoke recv commands
                # Since we want the files to get generated under a subfolder, we replace the path to include the subfolder
                $recvCmd =  $recvCmd -ireplace [regex]::Escape($CommandsDir), "$CommandsDir/Receiver"
                LogWrite "Invoking Cmd - Machine: $recvComputerName Command: $recvCmd" 
                $recvJob = Invoke-Command -Session $recvPSSession -ScriptBlock ([Scriptblock]::Create($recvCmd)) -AsJob 
    
                # Work here to invoke send commands
                # Since we want the files to get generated under a subfolder, we replace the path to include the subfolder
                $sendCmd =  $sendCmd -ireplace [regex]::Escape($CommandsDir), "$CommandsDir/Sender"
                LogWrite "Invoking Cmd - Machine: $sendComputerName Command: $sendCmd" 
                $sendJob = Invoke-Command -Session $sendPSSession -ScriptBlock ([Scriptblock]::Create($sendCmd)) -AsJob 
                # non blocking loop to check if the process made a clean exit
                LogWrite "Waiting for $TimeoutValueBetweenCommandPairs seconds ..."
                $timeout = new-timespan -Seconds $TimeoutValueBetweenCommandPairs
                $sw = [diagnostics.stopwatch]::StartNew()
                while ($sw.elapsed -lt $timeout){
                    if ($recvJob.State -eq "Completed" -and $sendJob.State -eq "Completed") {         
                        LogWrite "$Toolname exited on both Src and Dest machines"
                        break
                    }
                    start-sleep -seconds 5
                }
    
                if ($recvJob.State -ne "Completed") {
                    LogWrite " ++ $Toolname on Receiver did not exit cleanly with state " $recvJob.State
                } 
                if ($sendJob.State -ne "Completed") {
                    LogWrite " ++ $Toolname on Sender did not exit cleanly with state " $sendJob.State
                } 
    
                # Since time is up, stop job process so that new commands can be issued
                Stop-Job $recvJob
                Stop-Job $sendJob
    
                # Clean up completed or failed job list
                Remove-Job *
    
                # Add sleep between before running the next command pair
                start-sleep -seconds 5
    
            }
    
            $recvCommands.close()
            $sendCommands.close()
    
            LogWrite "Test runs completed. Collecting results..."

            Invoke-Command -Session $recvPSSession -ScriptBlock $ScriptBlockRemoveBinaries -ArgumentList "$CommandsDir/Receiver/$Toolname/$Toolname" 
            Invoke-Command -Session $sendPSSession -ScriptBlock $ScriptBlockRemoveBinaries -ArgumentList "$CommandsDir/Sender/$Toolname/$Toolname"
    
            if ($BZip -eq $true) {
                #Zip the files on remote machines
                LogWrite "Zipping up results..."
                Invoke-Command -Session $recvPSSession -ScriptBlock $ScriptBlockCreateZip -ArgumentList ("$CommandsDir/Receiver/$Toolname", "$CommandsDir/Recv.zip")
                Invoke-Command -Session $sendPSSession -ScriptBlock $ScriptBlockCreateZip -ArgumentList ("$CommandsDir/Sender/$Toolname", "$CommandsDir/Send.zip")
     
                Remove-Item -Force -Path ("{0}/{1}_Receiver.zip" -f $CommandsDir, $Toolname) -Recurse -ErrorAction SilentlyContinue
                Remove-Item -Force -Path ("{0}/{1}_Sender.zip" -f $CommandsDir, $Toolname) -Recurse -ErrorAction SilentlyContinue
    
                #copy the zip files from remote machines to the current (orchestrator) machines
                Copy-Item -Path "$CommandsDir/Recv.zip" -Destination ("{0}/{1}_Receiver.zip" -f $CommandsDir, $Toolname) -FromSession $recvPSSession -Force
                Copy-Item -Path "$CommandsDir/Send.zip" -Destination ("{0}/{1}_Sender.zip" -f $CommandsDir, $Toolname) -FromSession $sendPSSession -Force
    
                Invoke-Command -Session $recvPSSession -ScriptBlock $ScriptBlockRemoveFileFolder -ArgumentList "$CommandsDir/Recv.zip"
                Invoke-Command -Session $sendPSSession -ScriptBlock $ScriptBlockRemoveFileFolder -ArgumentList "$CommandsDir/Send.zip"
            } else {
                LogWrite "Copying directories..."
                Remove-Item -Force -Path ("{0}/{1}_Receiver" -f $CommandsDir, $Toolname) -Recurse -ErrorAction SilentlyContinue
                Remove-Item -Force -Path ("{0}/{1}_Sender" -f $CommandsDir, $Toolname) -Recurse -ErrorAction SilentlyContinue
    
                #copy just the entire results folder from remote machines to the current (orchestrator) machine
                Copy-Item -Path "$CommandsDir/Receiver/$Toolname/" -Recurse -Destination ("{0}/{1}_Receiver" -f $CommandsDir, $Toolname) -FromSession $recvPSSession -Force
                Copy-Item -Path "$CommandsDir/Sender/$Toolname/" -Recurse -Destination ("{0}/{1}_Sender" -f $CommandsDir, $Toolname) -FromSession $sendPSSession -Force
            }
    
            if ($Bcleanup -eq $True) { 
                LogWrite "Cleaning up folders on Machine: $recvComputerName"
    
                #clean up the folders and files we created
                if($recvFolderExists -eq $false) {
                     # The folder never existed in the first place. we need to clean up the directories we created
                     Invoke-Command -Session $recvPSSession -ScriptBlock $ScriptBlockRemoveFolderTree -ArgumentList "$CommandsDir"
                } else {
                    # this folder existed earlier on the machine. Leave the directory alone
                    # Remove just the child directories and the files we created. 
                    Invoke-Command -Session $recvPSSession -ScriptBlock $ScriptBlockRemoveFileFolder -ArgumentList "$CommandsDir/Receiver"
                }
    
                LogWrite "Cleaning up folders on Machine: $sendComputerName"
    
                if($sendFolderExists -eq $false) {
                     Invoke-Command -Session $sendPSSession -ScriptBlock $ScriptBlockRemoveFolderTree -ArgumentList "$CommandsDir"
                } else {
                    # this folder existed earlier on the machine. Leave the directory alone
                    # Remove just the child directories and the files we created. Leave the directory alone
                    Invoke-Command -Session $sendPSSession -ScriptBlock $ScriptBlockRemoveFileFolder -ArgumentList "$CommandsDir/Sender"
                }
            } # if ($Bcleanup -eq $true)
            $gracefulCleanup = $True
        } # end try
        catch {
           LogWrite "Exception $($_.Exception.Message) in $($MyInvocation.MyCommand.Name)"
        }
        finally {
            if($gracefulCleanup -eq $False)
            {
                if ($recvCommands -ne $null) {$recvCommands.close()}
                if ($sendCommands -ne $null) {$sendCommands.close()}

                Stop-Job *
                Remove-Job *
                
                Invoke-Command -Session $recvPSSession -ScriptBlock $ScriptBlockTaskKill -ArgumentList $Toolname
                Invoke-Command -Session $sendPSSession -ScriptBlock $ScriptBlockTaskKill -ArgumentList $Toolname
            
            }
    
            LogWrite "Cleaning up the firewall rules that were created as part of script run..."
            # Clean up the firewall rules that this script created
            Invoke-Command -Session $recvPSSession -ScriptBlock $ScriptBlockCleanupFirewallRules -ArgumentList ("50000:50512/tcp", $RecvComputerCreds)
            Invoke-Command -Session $sendPSSession -ScriptBlock $ScriptBlockCleanupFirewallRules -ArgumentList ("50000:50512/tcp", $SendComputerCreds)
            Invoke-Command -Session $recvPSSession -ScriptBlock $ScriptBlockCleanupFirewallRules -ArgumentList ("50000:50512/udp", $RecvComputerCreds)
            Invoke-Command -Session $sendPSSession -ScriptBlock $ScriptBlockCleanupFirewallRules -ArgumentList ("50000:50512/udp", $SendComputerCreds)
            
            LogWrite "Cleaning up public private key and known hosts that were created as part of script run"
            # Delete public and private key, as well as known host and authorized key
            Invoke-Command -Session $recvPSSession -ScriptBlock $ScriptBlockRemoveAuthorizedHost 
            Invoke-Command -Session $sendPSSession -ScriptBlock $ScriptBlockRemoveAuthorizedHost 

            Remove-Item -Path $keyFilePath -ErrorAction SilentlyContinue -Force
            Remove-Item -Path $pubKeyFilePath -ErrorAction SilentlyContinue -Force
            Remove-Item -Path $sshCommandFilePath -ErrorAction SilentlyContinue -Force

            head -n -6 "$homePath/.ssh/known_hosts" | Out-Null

            LogWrite "Cleaning up Remote PS Sessions"
            # Clean up the PS Sessions
            Remove-PSSession $sendPSSession  -ErrorAction Ignore
            Remove-PSSession $recvPSSession  -ErrorAction Ignore
    
        } #finally
    } # ProcessToolCommands()