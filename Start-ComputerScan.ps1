Function Start-ComputerScan {
    Param (
        $Servers = "UCFO-WDS01",
        [Bool]$PortScan = $True,
        [Bool]$ResolveHostname = $True,
        [Bool]$PingScan = $True
    )

    $CommonTCPPorts = "20","21","22","23","25","53","80","110","161","162","443","1723","3389","5000","5060","8080","8081"
    $CommonUDPPorts = "53","111","123","137","161","500"
    
    #Variable used to store all variables 
    $PortCheck = [System.Collections.ArrayList]::new()
    $Results   = [System.Collections.ArrayList]::new()
    #Add specified TCP ports to list of ports to get checked.
    ForEach ($Port in $CommonTCPPorts) {
        [Void]$PortCheck.Add([PSCustomObject]@{'Type'="TCP";'Port'="$Port"})
    }

    #Add specified UDP ports to list of ports to get checked.
    ForEach ($Port in $CommonUDPPorts) {
        [Void]$PortCheck.Add([PSCustomObject]@{'Type'="UDP";'Port'="$Port"})
    }

    $pool = [RunspaceFactory]::CreateRunspacePool(1, ([int]$env:NUMBER_OF_PROCESSORS + 1)*4)
    $pool.ApartmentState = "MTA"
    $pool.Open()
    $runspaces = @()

    $TestPorts = {
        Param (
            [Parameter(Mandatory=$True,Position=0)]
            [String]$ID,
            [Parameter(Mandatory=$True,Position=1)]
            [String]$IPAddress,
            [Parameter(Position=2)][ValidateSet("TCP","UDP")]
            [string]$Type,
            [Parameter(Position=3)]
            [int]$Port,
            [Parameter(Position=4)]
            [int]$Timeout="10000"
        )
        Switch ($Type) {
            'TCP' { $Socket = [System.Net.Sockets.Socket]::New([System.Net.Sockets.AddressFamily]::InterNetwork,[System.Net.Sockets.SocketType]::Stream,[System.Net.Sockets.ProtocolType]::TCP) }
            'UDP' { $Socket = [System.Net.Sockets.Socket]::New([System.Net.Sockets.AddressFamily]::InterNetwork,[System.Net.Sockets.SocketType]::Stream,[System.Net.Sockets.ProtocolType]::UDP)  }
            Default { Write-Error "How did you get here." }
        }
        [Void]$socket.BeginConnect($IPAddress,$Port,$null,$Null).AsyncWaitHandle.WaitOne($Timeout)
        Return [PSCustomObject]@{
            ID = $ID
            TCPUDP = $Type
            Open = $Socket.Connected
            Port = $Port
        }
        $socket.Close()
    }
    $PingTest = {
        Param (
            [Parameter(Mandatory=$True,Position=0)]
            [String]$ID,
            [Parameter(Mandatory=$True,Position=1)]
            [String]$IPAddress,
            [Parameter(Position=2)]
            [int]$Timeout="2500",
            [Parameter(Position=3)]
            [byte]$Buffer="104",
            [Parameter(Position=4)]
            [int]$TTL="175",
            [Parameter(Position=5)][ValidateSet("True","False")]
            [Bool]$Fragment=$False
        )
        $Return = [System.Collections.ArrayList]::New()
        $Ping = [System.Net.NetworkInformation.Ping]::new()
        $PingOptions = [System.Net.NetworkInformation.PingOptions]::new($TTL,$False)
        Try {
            $PingResult = $Ping.Send($IPAddress,$Timeout,$Buffer,$PingOptions)
        } Catch {}

        [Void]$Return.Add([PSCustomObject]@{
            ID = $ID
            HostName = $Hostname
            IPAddress = $IPAddress
            Pingable = $PingResult.Status -eq "Success"
        })
        Return $Return
    }
    $ResolveHost = {
        Param (
                [Parameter(Mandatory=$True,Position=0)]
                [String]$ID,
                [Parameter(Mandatory=$True,Position=1)]
                [String]$IPAddress
            )
            Try {
                $Resolvable = $True
                $Hostname = (Resolve-DnsName -Name $IPAddress -DnsOnly -Type A_AAAA -ErrorAction Stop -QuickTimeout).namehost
            } Catch {
                $Hostname = "Unresolvable"
                $Resolvable = $False
            }
            Return [PSCustomObject]@{ID=$ID;HostName = $Hostname;Resolvable=$True}
    }

    ForEach ($Server in $Servers) {
        #Attempt to get IPAddress & Hostname
        IF ($Server -AS [IPAddress]) {
            $IPAddress = $Server
        } Else {
            Try {
                $IPAddress = [System.Net.Dns]::GetHostAddresses($Server) |Select-Object -First 1 -ExpandProperty IPAddressToString
            } Catch {
                Write-Error -Message "Unable to get IP address of system."
                continue
            }
        }

        #Create Entry for each server in results.
        [Void]$Results.Add(@{
            $Server = [PSCustomObject]@{
                Hostname = $Null
                Pingable = $Null
                IPAddress = $IPAddress
                OpenTCPPorts = [System.Collections.ArrayList]::New()
                OpenUDPPorts = [System.Collections.ArrayList]::New()
            }
        })

        IF ($PortScan) {
            For ($I=0; $I -lt $PortCheck.Count; $I++) {
                $runspace = [PowerShell]::Create()
                [Void]$runspace.AddScript($TestPorts)
                [Void]$runspace.AddArgument($Server)
                [Void]$runspace.AddArgument($IPAddress)
                [Void]$runspace.AddArgument($PortCheck[$I].Type)
                [Void]$runspace.AddArgument($PortCheck[$I].Port)
                $runspace.RunspacePool = $pool
                $runspaces += [PSCustomObject]@{ Pipe = $runspace; Status = $runspace.BeginInvoke() }
            }
        }

        IF ($ResolveHostname) {
            $runspace = [PowerShell]::Create()
            [Void]$runspace.AddScript($ResolveHost)
            [Void]$runspace.AddArgument($Server)
            [Void]$runspace.AddArgument($IPAddress)
            $runspace.RunspacePool = $pool
            $runspaces += [PSCustomObject]@{ Pipe = $runspace; Status = $runspace.BeginInvoke() }
        }

        IF ($PingScan) {
            #Perform ping test.
            $runspace = [PowerShell]::Create()
            [Void]$runspace.AddScript($PingTest)
            [Void]$runspace.AddArgument($Server)
            [Void]$runspace.AddArgument($IPAddress)
            $runspace.RunspacePool = $pool
            $runspaces += [PSCustomObject]@{ Pipe = $runspace; Status = $runspace.BeginInvoke() }
        }
    }

    #output right to pipeline / console
    $WPTotal = $Runspaces.count
    $WPCount = [int]0
    while ($runspaces.Status -ne $null){
        $completed = $runspaces | Where-Object { $_.Status.IsCompleted -eq $true }
        Write-Progress -PercentComplete (($WPCount/$WPTotal)*100) -Activity "RunSpace Jobs (Total: $WPTotal)" -Status "$([Math]::Round((($WPCount/$WPTotal)*100),2))% Complete"
        foreach ($runspace in $completed) {
            $WPCount++
            Write-Output "$([Math]::Round((($WPCount/$WPTotal)*100),2))% Complete"
            Switch ($runspace.Pipe.EndInvoke($runspace.Status)) {
                {$_.PSobject.Properties.Name -contains "Pingable"} {
                    $Results."$($_.ID)".Pingable = $_.Pingable
                }
                {$_.PSobject.Properties.Name -contains "TCPUDP"} {
                    IF ($_.Open) {
                        [Void]$Results."$($_.ID)"."Open$($_.TCPUDP)Ports".Add($_.Port)
                    }
                }
                {$_.PSobject.Properties.Name -contains "Resolvable"} {
                    $Results."$($_.ID)".Hostname = $_.HostName
                }
                Default {}
        
            } #Gets Runspace output
            $runspace.Status = $null
        }
    }

    $pool.Close()
    $pool.Dispose()

    $Results.GetEnumerator() |Select -ExpandProperty Values
}
<#
$TargetComputers = [System.Collections.ArrayList]::New()
For ($I=4;$I -le 254;$I++) {
    [Void]$TargetComputers.Add("10.1.32.$I")
}
Start-PerformanceTest -ScriptBlock {
    Start-ComputerScan -Servers $TargetComputers |ft
} -Iterations 25 -Measurement Seconds
#>
Start-ComputerScan -Servers "UCFO-WDS01"