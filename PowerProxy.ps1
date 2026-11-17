param(
    # Allow -L to be used as an alias for -ListenPort.
    [Alias("L")]

    # Reject port numbers outside the valid TCP port range.
    [ValidateRange(1, 65535)]

    # The local TCP port on which the SOCKS5 proxy will listen.
    [int]$ListenPort,

    # Basic verbosity: display connection and disconnection events.
    [switch]$V,

    # File-logging verbosity: write full diagnostic information to the log.
    [switch]$VV,

    # Combined verbosity: display connection events and write full diagnostics.
    [switch]$VVV
)

# Display command usage, available options, and examples.
function Show-Help {
    Write-Host ""
    Write-Host "PowerProxy SOCKS5 Proxy"
    Write-Host ""
    Write-Host "Usage:"
    Write-Host "  .\powerproxy.ps1 -L <port> [-V | -VV | -VVV]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -L <port>   Required. Port on which the proxy listens."
    Write-Host "  -V          Display connection and disconnection states."
    Write-Host "  -VV         Write full proxy logs to C:\Temp\proxy.log."
    Write-Host "  -VVV        Display connection states and write full logs."
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  .\powerproxy.ps1 -L 1865"
    Write-Host "  .\powerproxy.ps1 -L 1865 -v"
    Write-Host "  .\powerproxy.ps1 -L 1865 -VV"
    Write-Host "  .\powerproxy.ps1 -L 1865 -vVv"
    Write-Host ""
}

#
# The listening port must be explicitly supplied.
#
# Validate presence through PSBoundParameters rather than relying on the default integer value, because ListenPort is not declared as mandatory.
if (-not $PSBoundParameters.ContainsKey("ListenPort")) {
    Show-Help
    exit 1
}

#
# Only one verbosity option may be used at a time.
#
# Count the number of explicitly selected verbosity switches.
$verbosityCount = 0

if ($V.IsPresent) {
    $verbosityCount++
}

if ($VV.IsPresent) {
    $verbosityCount++
}

if ($VVV.IsPresent) {
    $verbosityCount++
}

# Reject conflicting verbosity selections.
if ($verbosityCount -gt 1) {
    Write-Host ""
    Write-Host "Error: Specify only one of -V, -VV, or -VVV."
    Show-Help
    exit 1
}

# Connection-state messages are displayed for -V and -VVV.
$showConnectionStates =
    $V.IsPresent -or
    $VVV.IsPresent

# Full file logging is enabled for -VV and -VVV.
$enableFullLogging =
    $VV.IsPresent -or
    $VVV.IsPresent

# Use a fixed path for the proxy's full diagnostic log.
$logPath = "C:\Temp\proxy.log"

#
# Create C:\Temp when full logging is enabled.
#
if ($enableFullLogging) {
    try {
        # Extract the parent directory from the configured log path.
        $logDirectory =
            [System.IO.Path]::GetDirectoryName(
                $logPath
            )

        # Create the log directory if it does not already exist.
        if (-not [System.IO.Directory]::Exists($logDirectory)) {
            [System.IO.Directory]::CreateDirectory(
                $logDirectory
            ) | Out-Null
        }

        # Append a startup entry rather than replacing an existing log.
        [System.IO.File]::AppendAllText(
            $logPath,
            (Get-Date).ToString() +
            " : Proxy starting on port " +
            $ListenPort +
            [Environment]::NewLine
        )
    }
    catch {
        # Logging initialization is treated as fatal when logging was requested.
        Write-Host (
            "Unable to initialize proxy log: " +
            $_.Exception.Message
        )

        exit 1
    }
}

# Main-loop termination flag, set when the user presses Q.
$shouldStop = $false

# Shared cancellation source used to cancel asynchronous stream-copy operations.
$cts = [System.Threading.CancellationTokenSource]::new()

# Thread-safe collection containing every accepted connection's state object.
$connections =
    [System.Collections.Concurrent.ConcurrentBag[object]]::new()

# Create a TCP listener bound to all local interfaces on the requested port.
$listener = [System.Net.Sockets.TcpListener]::new(
    [System.Net.IPAddress]::Any,
    $ListenPort
)

# Start accepting TCP connections.
try {
    $listener.Start()
}
catch {
    # Binding can fail because of permissions, an invalid local configuration, or another process already listening on the port.
    Write-Host (
        "Unable to start the proxy listener: " +
        $_.Exception.Message
    )

    exit 1
}

# Display the active proxy configuration.
Write-Host "SOCKS5 proxy listening on port $ListenPort"
Write-Host "Authentication: None"

if ($showConnectionStates) {
    Write-Host "Connection-state display: Enabled"
}

if ($enableFullLogging) {
    Write-Host "Full logging: $logPath"
}

Write-Host "Press Q to stop."

# Enclose the complete listener lifetime in try/finally so cleanup runs regardless of whether the loop exits normally or because of an exception.
try {
    while (-not $shouldStop) {

        #
        # Stop on Q
        #
        # Check for keyboard input without blocking the listener loop.
        if ([Console]::KeyAvailable) {

            # Read the available key without echoing it to the console.
            $key = [Console]::ReadKey($true)

            # Accept either lowercase or uppercase Q as the stop command.
            if (
                $key.KeyChar -eq "q" -or
                $key.KeyChar -eq "Q"
            ) {
                Write-Host ""
                Write-Host "Stopping proxy..."

                # Record an operator-requested shutdown when logging is active.
                if ($enableFullLogging) {
                    [System.IO.File]::AppendAllText(
                        $logPath,
                        (Get-Date).ToString() +
                        " : Stop requested from console" +
                        [Environment]::NewLine
                    )
                }

                $shouldStop = $true
                break
            }
        }

        #
        # Non-blocking listener
        #
        # Pending() prevents AcceptTcpClient() from blocking the main thread.
        if (-not $listener.Pending()) {
            # Briefly yield CPU time before polling again.
            Start-Sleep -Milliseconds 50
            continue
        }

        try {

            # Accept the next queued client connection.
            $client = $listener.AcceptTcpClient()

            # Capture the client's source address and source port for display and logging before the socket is eventually closed.
            $remoteEndpoint =
                $client.Client.RemoteEndPoint.ToString()

            if ($showConnectionStates) {
                Write-Host (
                    "Client connected: " +
                    $remoteEndpoint
                )
            }

            if ($enableFullLogging) {
                [System.IO.File]::AppendAllText(
                    $logPath,
                    (Get-Date).ToString() +
                    " : Client connected: " +
                    $remoteEndpoint +
                    [Environment]::NewLine
                )
            }

            # Store the accepted client, eventual target connection, worker PowerShell instance, and asynchronous invocation handle together.
            $connectionInfo = [PSCustomObject]@{
                Client   = $client
                Target   = $null
                Runspace = $null
                Handle   = $null
            }

            # Retain the connection object so shutdown can close and dispose it.
            $connections.Add($connectionInfo)

            # Define the code executed independently for this client.
            $worker = {

                param(
                    # Shared state object for this accepted connection.
                    $Connection,

                    # Cancellation token used by bidirectional CopyToAsync calls.
                    $Token,

                    # Controls console connection-state messages.
                    [bool]$ShowConnectionStates,

                    # Controls full diagnostic file logging.
                    [bool]$EnableFullLogging,

                    # Destination path for full logging.
                    [string]$LogPath
                )

                # Append a timestamped diagnostic entry when full logging is active.
                function Write-FullLog {

                    param(
                        [string]$Message
                    )

                    # Avoid all file work when full logging is disabled.
                    if (-not $EnableFullLogging) {
                        return
                    }

                    try {
                        [System.IO.File]::AppendAllText(
                            $LogPath,
                            (Get-Date).ToString() +
                            " : " +
                            $Message +
                            [Environment]::NewLine
                        )
                    }
                    catch {
                        # Logging failures are deliberately suppressed so they do not terminate an otherwise functional connection.
                    }
                }

                # Read exactly Count bytes from a stream.
                #
                # NetworkStream.Read() is allowed to return fewer bytes than requested, so a single Read() cannot be assumed to fill the complete SOCKS protocol field.
                function Read-Exact {

                    param(
                        [System.IO.Stream]$Stream,
                        [byte[]]$Buffer,
                        [int]$Count
                    )

                    # Track the number of bytes already placed in the buffer.
                    $offset = 0

                    while ($offset -lt $Count) {

                        # Read only the number of bytes still required.
                        $read = $Stream.Read(
                            $Buffer,
                            $offset,
                            $Count - $offset
                        )

                        # A zero-byte read indicates an orderly remote closure.
                        if ($read -le 0) {
                            throw "Connection closed"
                        }

                        # Advance to the next unwritten position in the buffer.
                        $offset += $read
                    }
                }

                # These references are initialized outside the try block so they remain accessible to catch and finally.
                $target = $null
                $clientStream = $null
                $targetDescription = $null

                try {

                    # Record that the per-connection worker began executing.
                    Write-FullLog (
                        "WORKER STARTED: " +
                        $Connection.Client.Client.RemoteEndPoint
                    )

                    # Obtain the stream used to read and write the SOCKS client.
                    $clientStream =
                        $Connection.Client.GetStream()

                    Write-FullLog "Reading SOCKS header..."

                    #
                    # SOCKS5 greeting
                    #
                    # The greeting starts with VER and NMETHODS.
                    $header = New-Object byte[] 2

                    Read-Exact `
                        $clientStream `
                        $header `
                        2

                    Write-FullLog (
                        "SOCKS Version=" +
                        $header[0] +
                        ", MethodCount=" +
                        $header[1]
                    )

                    # SOCKS5 identifies itself with protocol version 5.
                    if ($header[0] -ne 5) {
                        throw "Not a SOCKS5 client"
                    }

                    # NMETHODS specifies the number of authentication-method bytes.
                    $methodCount = $header[1]

                    # Allocate storage for the complete METHODS field.
                    $methods =
                        New-Object byte[] $methodCount

                    Read-Exact `
                        $clientStream `
                        $methods `
                        $methodCount

                    Write-FullLog (
                        "Methods: " +
                        [BitConverter]::ToString($methods)
                    )

                    #
                    # NO AUTH
                    #
                    # Reply with VER=5 and METHOD=0, selecting "no authentication."
                    $clientStream.Write(
                        [byte[]]@(5, 0),
                        0,
                        2
                    )

                    #
                    # CONNECT request
                    #
                    # Read VER, CMD, RSV, and ATYP.
                    $request =
                        New-Object byte[] 4

                    Read-Exact `
                        $clientStream `
                        $request `
                        4

                    Write-FullLog (
                        "Request=" +
                        [System.BitConverter]::ToString($request)
                    )

                    # SOCKS5 identifies the request protocol version as 5.
                    if ($request[0] -ne 5) {
                        throw "Invalid SOCKS version"
                    }

                    # SOCKS5 requires the reserved byte to be zero.
                    if ($request[2] -ne 0) {
                        throw "Invalid reserved byte"
                    }

                    # CMD determines the requested operation.
                    $command = $request[1]

                    # ATYP determines how the destination address is encoded.
                    $addressType = $request[3]

                    # This proxy implements only CMD=1, the TCP CONNECT command.
                    if ($command -ne 1) {
                        throw (
                            "Unsupported command: " +
                            $command
                        )
                    }

                    # Decode the destination address according to ATYP.
                    switch ($addressType) {

                        # ATYP=1: four-byte IPv4 address.
                        1 {

                            $addrBytes =
                                New-Object byte[] 4

                            Read-Exact `
                                $clientStream `
                                $addrBytes `
                                4

                            $TargetHost =
                                [System.Net.IPAddress]::new(
                                    $addrBytes
                                ).ToString()
                        }

                        # ATYP=3: one-byte length followed by a domain name.
                        3 {

                            $nameLength =
                                $clientStream.ReadByte()

                            $nameBytes =
                                New-Object byte[] $nameLength

                            Read-Exact `
                                $clientStream `
                                $nameBytes `
                                $nameLength

                            $TargetHost =
                                [Text.Encoding]::ASCII.GetString(
                                    $nameBytes
                                )
                        }

                        # ATYP=4: sixteen-byte IPv6 address.
                        4 {

                            $addrBytes =
                                New-Object byte[] 16

                            Read-Exact `
                                $clientStream `
                                $addrBytes `
                                16

                            $TargetHost =
                                [System.Net.IPAddress]::new(
                                    $addrBytes
                                ).ToString()
                        }

                        # Reject address encodings not implemented above.
                        default {
                            throw (
                                "Unsupported address type: " +
                                $addressType
                            )
                        }
                    }

                    # The destination port follows the address as two bytes.
                    $portBytes =
                        New-Object byte[] 2

                    Read-Exact `
                        $clientStream `
                        $portBytes `
                        2

                    Write-FullLog (
                        "PortBytes=" +
                        [System.BitConverter]::ToString($portBytes)
                    )

                    # SOCKS transmits the port in network byte order. Reverse the two bytes before using the little-endian ToUInt16 method.
                    $TargetPort =
                        [System.BitConverter]::ToUInt16(
                            [byte[]]@(
                                $portBytes[1],
                                $portBytes[0]
                            ),
                            0
                        )

                    Write-FullLog (
                        "CalculatedPort=" +
                        $TargetPort
                    )

                    # Produce a reusable human-readable destination description.
                    $targetDescription =
                        "${TargetHost}:${TargetPort}"

                    Write-FullLog (
                        "SOCKS5 request -> " +
                        $targetDescription
                    )

                    Write-FullLog (
                        "Connecting To -> " +
                        $targetDescription
                    )

                    # Create the outbound TCP client used to reach the requested destination.
                    $target =
                        New-Object System.Net.Sockets.TcpClient

                    # Publish it to the shared connection object so the main shutdown routine can close it if necessary.
                    $Connection.Target =
                        $target

                    # Establish the outbound TCP connection.
                    $target.Connect(
                        $TargetHost,
                        $TargetPort
                    )

                    Write-FullLog (
                        "Connected to " +
                        $targetDescription
                    )

                    #
                    # Proper SOCKS5 success response
                    #
                    # Use the outbound socket's local endpoint as BND.ADDR and BND.PORT in the successful SOCKS5 response.
                    $localEndpoint =
                        $target.Client.LocalEndPoint

                    # Convert the bound local address into its raw address bytes.
                    $addr =
                        $localEndpoint.Address.GetAddressBytes()

                    # Store the local port as an unsigned 16-bit value.
                    $port =
                        [UInt16]$localEndpoint.Port

                    # Construct an IPv4 success response when the bound address contains four bytes.
                    if ($addr.Length -eq 4) {

                        # VER=5, REP=0, RSV=0, ATYP=1, IPv4 address, network-order port.
                        $reply = [byte[]]@(
                            5,
                            0,
                            0,
                            1,
                            $addr[0],
                            $addr[1],
                            $addr[2],
                            $addr[3],
                            (($port -shr 8) -band 0xFF),
                            ($port -band 0xFF)
                        )
                    }
                    else {

                        # Otherwise construct an IPv6 response with ATYP=4.
                        $reply =
                            [byte[]]@(5, 0, 0, 4) +
                            $addr +
                            [byte[]]@(
                                (($port -shr 8) -band 0xFF),
                                ($port -band 0xFF)
                            )
                    }

                    # Notify the SOCKS client that the TCP connection succeeded.
                    $clientStream.Write(
                        $reply,
                        0,
                        $reply.Length
                    )

                    Write-FullLog (
                        "Forwarding " +
                        $Connection.Client.Client.RemoteEndPoint +
                        " -> " +
                        $targetDescription
                    )

                    # Obtain the destination's network stream.
                    $targetStream =
                        $target.GetStream()

                    # Start forwarding client data toward the destination.
                    $clientToTarget =
                        $clientStream.CopyToAsync(
                            $targetStream,
                            81920,
                            $Token
                        )

                    # Simultaneously forward destination data back to the client.
                    $targetToClient =
                        $targetStream.CopyToAsync(
                            $clientStream,
                            81920,
                            $Token
                        )

                    # Keep the worker active until either forwarding direction ends because of closure, failure, or cancellation.
                    [System.Threading.Tasks.Task]::WaitAny(
                        @(
                            $clientToTarget,
                            $targetToClient
                        )
                    ) | Out-Null

                    # Close both sockets after either forwarding task completes.
                    try {
                        $Connection.Client.Close()
                    }
                    catch {
                    }

                    try {
                        $target.Close()
                    }
                    catch {
                    }
                }
                catch {

                    # Record the complete exception details when logging is active.
                    Write-FullLog (
                        "ERROR: " +
                        $_.Exception.ToString()
                    )

                    try {

                        # If the client stream exists, send a general SOCKS5 failure response: VER=5, REP=1, RSV=0, ATYP=1, address 0.0.0.0, and port 0.
                        if ($clientStream) {

                            $reply = [byte[]]@(
                                5,
                                1,
                                0,
                                1,
                                0,
                                0,
                                0,
                                0,
                                0,
                                0
                            )

                            $clientStream.Write(
                                $reply,
                                0,
                                $reply.Length
                            )
                        }
                    }
                    catch {
                        # Ignore failures that occur while reporting the original connection failure to an unavailable client.
                    }
                }
                finally {

                    # Ensure the accepted client is closed on every exit path.
                    try {
                        if ($Connection.Client) {
                            $Connection.Client.Close()
                        }
                    }
                    catch {
                    }

                    # Ensure the outbound target is also closed if it was created.
                    try {
                        if ($target) {
                            $target.Close()
                        }
                    }
                    catch {
                    }

                    # Display the disconnect event if console state reporting was selected.
                    if ($ShowConnectionStates) {

                        # Include the target when request parsing reached the point where a target description was available.
                        if ($targetDescription) {
                            Write-Host (
                                "Client disconnected: " +
                                $Connection.Client.Client.RemoteEndPoint +
                                " -> " +
                                $targetDescription
                            )
                        }
                        else {
                            Write-Host (
                                "Client disconnected: " +
                                $Connection.Client.Client.RemoteEndPoint
                            )
                        }
                    }

                    # Record the final connection closure in the full log.
                    Write-FullLog (
                        "Connection closed: " +
                        $Connection.Client.Client.RemoteEndPoint
                    )
                }
            }

            # Create an independent PowerShell execution object for the worker.
            $ps =
                [System.Management.Automation.PowerShell]::Create()

            # Add the worker script block as executable script text.
            $null = $ps.AddScript(
                $worker.ToString()
            )

            # Supply worker parameters positionally in the same order in which they are declared in the worker's param block.
            $null = $ps.AddArgument(
                $connectionInfo
            )

            $null = $ps.AddArgument(
                $cts.Token
            )

            $null = $ps.AddArgument(
                $showConnectionStates
            )

            $null = $ps.AddArgument(
                $enableFullLogging
            )

            $null = $ps.AddArgument(
                $logPath
            )

            # Invoke asynchronously so the main loop can continue accepting additional clients.
            $asyncResult =
                $ps.BeginInvoke()

            # Retain both objects for shutdown waiting and disposal.
            $connectionInfo.Runspace = $ps
            $connectionInfo.Handle = $asyncResult
        }
        catch {

            # Report failures occurring while accepting or dispatching a client.
            Write-Host (
                "Accept error: " +
                $_.Exception.Message
            )

            if ($enableFullLogging) {
                [System.IO.File]::AppendAllText(
                    $logPath,
                    (Get-Date).ToString() +
                    " : Accept error: " +
                    $_.Exception.ToString() +
                    [System.Environment]::NewLine
                )
            }
        }
    }
}
finally {

    # This cleanup block runs after the main loop exits for any reason.
    Write-Host ""
    Write-Host "Stopping listener..."

    if ($enableFullLogging) {
        [System.IO.File]::AppendAllText(
            $logPath,
            (Get-Date).ToString() +
            " : Stopping listener" +
            [System.Environment]::NewLine
        )
    }

    # Signal cancellation to active asynchronous stream-copy operations.
    try {
        $cts.Cancel()
    }
    catch {
    }

    # Stop accepting new TCP clients.
    try {
        $listener.Stop()
    }
    catch {
    }

    # First close all client and target sockets. This helps unblock workers that may still be waiting on network I/O.
    foreach ($connection in $connections) {

        try {
            if ($connection.Client) {
                $connection.Client.Close()
            }
        }
        catch {
        }

        try {
            if ($connection.Target) {
                $connection.Target.Close()
            }
        }
        catch {
        }
    }

    # Then wait briefly for each active worker and dispose its PowerShell object.
    foreach ($connection in $connections) {

        try {

            # Wait at most five seconds for a worker that has not yet finished.
            if (
                $connection.Handle -and
                -not $connection.Handle.IsCompleted
            ) {

                $connection.Handle.AsyncWaitHandle.WaitOne(
                    5000
                ) | Out-Null
            }
        }
        catch {
        }

        try {

            # Release the resources owned by the per-connection PowerShell object.
            if ($connection.Runspace) {
                $connection.Runspace.Dispose()
            }
        }
        catch {
        }
    }

    # Release resources owned by the cancellation-token source.
    try {
        $cts.Dispose()
    }
    catch {
    }

    # Record successful completion of the shutdown sequence.
    if ($enableFullLogging) {
        [System.IO.File]::AppendAllText(
            $logPath,
            (Get-Date).ToString() +
            " : Proxy stopped gracefully" +
            [System.Environment]::NewLine
        )
    }

    Write-Host "Proxy stopped gracefully."
}