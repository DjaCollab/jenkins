$ip    = '172.30.4.21'
$ports = 1815, 445, 3389, 5985, 22, 80, 443

Write-Host "Running on $env:COMPUTERNAME as $(whoami)"
Write-Host "Target: $ip`n"

if (Test-Connection -ComputerName $ip -Count 4 -Quiet) {
    Write-Host "PING      : reply"
} else {
    # Not conclusive - plenty of firewalls drop ICMP but permit TCP.
    Write-Host "PING      : no reply"
}

$open = @()
foreach ($port in $ports) {
    $r = Test-NetConnection -ComputerName $ip -Port $port -WarningAction SilentlyContinue
    if ($r.TcpTestSucceeded) {
        # Source address is what a firewall rule gets written against.
        Write-Host ("TCP {0,-5} : OPEN   (source {1})" -f $port, $r.SourceAddress.IPAddress)
        $open += $port
    } else {
        Write-Host ("TCP {0,-5} : closed" -f $port)
    }
}

Write-Host ""
if ($open.Count -gt 0) {
    Write-Host "RESULT: reachable on $($open -join ', ')"
    exit 0
}

Write-Host "RESULT: no TCP port reachable"
exit 1
